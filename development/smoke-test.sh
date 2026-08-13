#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

NAMESPACE="${DATAWAVE_NAMESPACE:-default}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-300}"
LOCAL_PORT="${SMOKE_LOCAL_PORT:-18443}"
USER_SECRET="${DATAWAVE_USER_CERT_SECRET:-datawave-user-certificates}"
USER_CERT="${DATAWAVE_USER_CERT:-}"
USER_KEY="${DATAWAVE_USER_KEY:-}"
PROXY_SUBJECT="${SMOKE_PROXY_SUBJECT:-CN=Test A. User, OU=Example Developers, O=Example Corp, C=US}"
PROXY_ISSUER="${SMOKE_PROXY_ISSUER:-CN=EXAMPLE CORP CA, O=Example Corp, C=US}"
ACCUMULO_USER="${SMOKE_ACCUMULO_USER:-root}"
ACCUMULO_PASSWORD="${SMOKE_ACCUMULO_PASSWORD:-ThisP@ssw0rd1sBANANAS}"
AUDIT_TABLE="${SMOKE_AUDIT_TABLE:-QueryAuditTable}"
QUERY_AUTHS="${SMOKE_AUTHS:-PRIVATE,PUBLIC}"

usage() {
  cat <<'USAGE'
Usage: development/smoke-test.sh [options]

Ingest a unique myjson event, query it through the DataWave monolith, submit an
audit for the exact query, and verify that audit in Accumulo.

Options:
  -n, --namespace NAME   Kubernetes namespace (default: default)
      --timeout SECONDS  Overall ingest/query timeout (default: 300)
      --user-cert PATH   PEM client certificate (default: user secret tls.crt)
      --user-key PATH    PEM client key (default: user secret tls.key)
      --local-port PORT  Local monolith port-forward port (default: 18443)
  -h, --help             Show this help

The stack must be installed with datawave-stack/values-smoke-testing.yaml.
DATAWAVE_*/SMOKE_* environment variables can override all test identities,
credentials, timeouts, the audit table, and proxied user DNs.
USAGE
}

while (($#)); do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
    --user-cert) USER_CERT="$2"; shift 2 ;;
    --user-key) USER_KEY="$2"; shift 2 ;;
    --local-port) LOCAL_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in kubectl curl jq base64; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command not found: ${command_name}" >&2
    exit 1
  }
done

[[ "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] || { echo "Timeout must be a positive integer." >&2; exit 2; }
kubectl get namespace "${NAMESPACE}" >/dev/null

TEMP_DIR="$(mktemp -d)"
PORT_FORWARD_PID=""
cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT INT TERM

if [[ -z "${USER_CERT}" && -z "${USER_KEY}" ]]; then
  USER_CERT="${TEMP_DIR}/user.crt"
  USER_KEY="${TEMP_DIR}/user.key"
  kubectl -n "${NAMESPACE}" get secret "${USER_SECRET}" -o jsonpath='{.data.tls\.crt}' | base64 --decode >"${USER_CERT}"
  kubectl -n "${NAMESPACE}" get secret "${USER_SECRET}" -o jsonpath='{.data.tls\.key}' | base64 --decode >"${USER_KEY}"
elif [[ -z "${USER_CERT}" || -z "${USER_KEY}" ]]; then
  echo "Set both the user certificate and user key, or neither." >&2
  exit 2
fi
[[ -r "${USER_CERT}" && -r "${USER_KEY}" ]] || { echo "User certificate or key is not readable." >&2; exit 1; }

find_pod() {
  local pattern="$1"
  kubectl -n "${NAMESPACE}" get pods -o json | jq -r --arg pattern "${pattern}" \
    '.items[] | select(.metadata.name | test($pattern)) | select(.status.phase == "Running") | .metadata.name' | head -n 1
}

HDFS_POD="$(find_pod 'hadoop-hdfs-nn')"
YARN_POD="$(find_pod 'hadoop-yarn-rm')"
ACCUMULO_POD="$(find_pod '^accumulo-manager-')"
[[ -n "${HDFS_POD}" ]] || { echo "Running HDFS name-node pod not found." >&2; exit 1; }
[[ -n "${YARN_POD}" ]] || { echo "Running YARN resource-manager pod not found." >&2; exit 1; }
[[ -n "${ACCUMULO_POD}" ]] || { echo "Running Accumulo manager pod not found." >&2; exit 1; }

YARN_APPLICATIONS_BEFORE="${TEMP_DIR}/yarn-applications-before"
kubectl -n "${NAMESPACE}" exec "${YARN_POD}" -- \
  yarn application -list -appStates ALL 2>/dev/null | \
  awk '$1 ~ /^application_[0-9]+_[0-9]+$/ {print $1}' >"${YARN_APPLICATIONS_BEFORE}"

SMOKE_TOKEN="dw-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SMOKE_ID="$(( $(date +%s) % 1000000000 ))"
DATA_FILE="${TEMP_DIR}/${SMOKE_TOKEN}.json"
QUERY="NAME == '${SMOKE_TOKEN}'"

sed \
  -e "s/__SMOKE_ID__/${SMOKE_ID}/g" \
  -e "s/__SMOKE_TOKEN__/${SMOKE_TOKEN}/g" \
  "${SCRIPT_DIR}/smoke-event.json.template" >"${DATA_FILE}"

echo "[1/4] Ingesting ${SMOKE_TOKEN} through the myjson live ingest path..."
kubectl -n "${NAMESPACE}" cp "${DATA_FILE}" "${HDFS_POD}:/tmp/${SMOKE_TOKEN}.json"
kubectl -n "${NAMESPACE}" exec "${HDFS_POD}" -- \
  hdfs dfs -put "/tmp/${SMOKE_TOKEN}.json" "hdfs://hdfs-nn:9000/data/myjson/${SMOKE_TOKEN}.json"

echo "[2/4] Waiting for ingest and refreshing the metadata cache..."
kubectl -n "${NAMESPACE}" port-forward service/web-datawave "${LOCAL_PORT}:8443" >"${TEMP_DIR}/port-forward.log" 2>&1 &
PORT_FORWARD_PID=$!

CURL_ARGS=(--silent --show-error --insecure --connect-timeout 5 --max-time 30 --cert "${USER_CERT}" --key "${USER_KEY}" -H 'Accept: application/json')
if [[ -n "${PROXY_SUBJECT}" ]]; then
  CURL_ARGS+=(-H "X-ProxiedEntitiesChain: <${PROXY_SUBJECT}>" -H "X-ProxiedIssuersChain: <${PROXY_ISSUER}>")
fi

deadline=$((SECONDS + TIMEOUT_SECONDS))
until curl "${CURL_ARGS[@]}" "https://127.0.0.1:${LOCAL_PORT}/DataWave/Common/Health/health" >/dev/null 2>&1; do
  ((SECONDS < deadline)) || { echo "Monolith port-forward did not become ready." >&2; exit 1; }
  sleep 2
done

ingest_succeeded=false
while ((SECONDS < deadline)); do
  new_application_record="$({ kubectl -n "${NAMESPACE}" exec "${YARN_POD}" -- \
      yarn application -list -appStates ALL 2>/dev/null || true; } | \
    awk '$1 ~ /^application_[0-9]+_[0-9]+$/ {print $1, $6, $7}' | \
    while read -r application_id application_state final_state; do
      if ! grep -Fxq "${application_id}" "${YARN_APPLICATIONS_BEFORE}"; then
        echo "${application_id} ${application_state} ${final_state}"
      fi
    done | tail -n 1)"
  if [[ -n "${new_application_record}" ]]; then
    read -r ingest_application_id application_state final_state <<<"${new_application_record}"
    if [[ "${application_state}" == "FINISHED" && "${final_state}" == "SUCCEEDED" ]]; then
      ingest_succeeded=true
      break
    fi
    if [[ "${application_state}" =~ ^(FAILED|KILLED)$ || "${final_state}" =~ ^(FAILED|KILLED)$ ]]; then
      echo "The smoke-test YARN application ${ingest_application_id} failed (${application_state}/${final_state})." >&2
      kubectl -n "${NAMESPACE}" exec "${YARN_POD}" -- \
        yarn application -status "${ingest_application_id}" >&2 || true
      exit 1
    fi
  fi
  sleep 5
done
[[ "${ingest_succeeded}" == true ]] || { echo "The smoke-test ingest did not finish within ${TIMEOUT_SECONDS} seconds." >&2; exit 1; }

# myjson is normally already known, but reload twice to make the test reliable
# on an otherwise empty cluster and to match DataWave's cache propagation flow.
for ignored in 1 2; do
  curl "${CURL_ARGS[@]}" --max-time 5 \
    "https://127.0.0.1:${LOCAL_PORT}/DataWave/Common/AccumuloTableCache/reload/datawave.metadata" >/dev/null || true
  sleep 3
done

QUERY_RESPONSE="${TEMP_DIR}/query.json"
query_succeeded=false
while ((SECONDS < deadline)); do
  http_code="$(curl "${CURL_ARGS[@]}" -o "${QUERY_RESPONSE}" -w '%{http_code}' -X POST \
    "https://127.0.0.1:${LOCAL_PORT}/DataWave/Query/EventQuery/createAndNext" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "queryName=${SMOKE_TOKEN}" \
    --data-urlencode "auths=${QUERY_AUTHS}" \
    --data-urlencode 'begin=20000101 000000.000' \
    --data-urlencode 'end=21000101 000000.000' \
    --data-urlencode 'pagesize=10' \
    --data-urlencode 'columnVisibility=PUBLIC' || true)"
  if [[ "${http_code}" == 200 ]] && jq -e --arg token "${SMOKE_TOKEN}" '.. | strings | select(contains($token))' "${QUERY_RESPONSE}" >/dev/null; then
    query_succeeded=true
    break
  fi
  sleep 10
done
if [[ "${query_succeeded}" != true ]]; then
  echo "The ingested event was not queryable within ${TIMEOUT_SECONDS} seconds." >&2
  jq . "${QUERY_RESPONSE}" >&2 2>/dev/null || cat "${QUERY_RESPONSE}" >&2
  exit 1
fi
echo "[3/4] Query returned the exact ingested marker ${SMOKE_TOKEN}."

AUDIT_ID="audit-${SMOKE_TOKEN}"
audit_code="$(curl "${CURL_ARGS[@]}" -o "${TEMP_DIR}/audit.json" -w '%{http_code}' -X POST \
  "https://127.0.0.1:${LOCAL_PORT}/DataWave/Common/Auditor/audit" \
  --data-urlencode "auditUserDN=${PROXY_SUBJECT}" \
  --data-urlencode "query=${QUERY}" \
  --data-urlencode "auths=${QUERY_AUTHS}" \
  --data-urlencode 'auditType=ACTIVE' \
  --data-urlencode 'auditColumnVisibility=PUBLIC' \
  --data-urlencode 'logicClass=EventQuery' \
  --data-urlencode "auditId=${AUDIT_ID}")"
if [[ "${audit_code}" != 200 ]]; then
  echo "DataWave rejected the smoke-test audit (HTTP ${audit_code})." >&2
  cat "${TEMP_DIR}/audit.json" >&2
  exit 1
fi

echo "[4/4] Verifying the exact audit in Accumulo table ${AUDIT_TABLE}..."
audit_succeeded=false
for ignored in $(seq 1 12); do
  if kubectl -n "${NAMESPACE}" exec "${ACCUMULO_POD}" -- \
      /opt/accumulo/bin/accumulo shell -u "${ACCUMULO_USER}" -p "${ACCUMULO_PASSWORD}" \
      -e "scan -t ${AUDIT_TABLE}" 2>/dev/null | grep -F "${SMOKE_TOKEN}" >/dev/null; then
    audit_succeeded=true
    break
  fi
  sleep 5
done
[[ "${audit_succeeded}" == true ]] || { echo "The audit was not found in ${AUDIT_TABLE}." >&2; exit 1; }

echo "PASS: ingest, query, and audit succeeded for ${SMOKE_TOKEN}."
