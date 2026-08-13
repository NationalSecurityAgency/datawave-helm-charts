#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

NAMESPACE="${DATAWAVE_NAMESPACE:-default}"
SERVER_SECRET="${DATAWAVE_SERVER_CERT_SECRET:-certificates-secret}"
USER_SECRET="${DATAWAVE_USER_CERT_SECRET:-datawave-user-certificates}"
SERVER_KEYSTORE="${DATAWAVE_SERVER_KEYSTORE:-${REPO_DIR}/datawave-stack/certificates/keystore.p12}"
SERVER_TRUSTSTORE="${DATAWAVE_SERVER_TRUSTSTORE:-${REPO_DIR}/datawave-stack/certificates/truststore.jks}"
KEYSTORE_PASSWORD="${DATAWAVE_KEYSTORE_PASSWORD:-changeme}"
TRUSTSTORE_PASSWORD="${DATAWAVE_TRUSTSTORE_PASSWORD:-changeme}"
USER_CERT="${DATAWAVE_USER_CERT:-${REPO_DIR}/python_deployment_tests/resources/test.crt.pem}"
USER_KEY="${DATAWAVE_USER_KEY:-${REPO_DIR}/python_deployment_tests/resources/test.key.pem}"
RESTART=true

usage() {
  cat <<'USAGE'
Usage: development/apply-certificates.sh [options]

Create/update the two certificate secrets used by the local DataWave stack.
Server stores are mounted by every TLS-enabled service. The user certificate
is kept in a separate secret and is used by the smoke-test client.

Options:
  -n, --namespace NAME          Kubernetes namespace (default: default)
      --server-keystore PATH   PKCS12 server identity store
      --server-truststore PATH JKS server trust store
      --keystore-password PASS Server keystore password
      --truststore-password PASS Server truststore password
      --user-cert PATH         PEM client certificate
      --user-key PATH          PEM client private key
      --server-secret NAME     Server secret name
      --user-secret NAME       User secret name
      --no-restart             Do not restart workloads using server secret
  -h, --help                   Show this help

Every option also has a DATAWAVE_* environment equivalent; see the defaults at
the top of this script. Certificate material is never added to Helm values.
USAGE
}

while (($#)); do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --server-keystore) SERVER_KEYSTORE="$2"; shift 2 ;;
    --server-truststore) SERVER_TRUSTSTORE="$2"; shift 2 ;;
    --keystore-password) KEYSTORE_PASSWORD="$2"; shift 2 ;;
    --truststore-password) TRUSTSTORE_PASSWORD="$2"; shift 2 ;;
    --user-cert) USER_CERT="$2"; shift 2 ;;
    --user-key) USER_KEY="$2"; shift 2 ;;
    --server-secret) SERVER_SECRET="$2"; shift 2 ;;
    --user-secret) USER_SECRET="$2"; shift 2 ;;
    --no-restart) RESTART=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in kubectl jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command not found: ${command_name}" >&2
    exit 1
  }
done

for certificate_file in "${SERVER_KEYSTORE}" "${SERVER_TRUSTSTORE}" "${USER_CERT}" "${USER_KEY}"; do
  [[ -r "${certificate_file}" ]] || {
    echo "Certificate file is not readable: ${certificate_file}" >&2
    exit 1
  }
done

kubectl get namespace "${NAMESPACE}" >/dev/null

kubectl -n "${NAMESPACE}" create secret generic "${SERVER_SECRET}" \
  --from-file=keystore.p12="${SERVER_KEYSTORE}" \
  --from-file=truststore.jks="${SERVER_TRUSTSTORE}" \
  --from-literal=keystore-password="${KEYSTORE_PASSWORD}" \
  --from-literal=truststore-password="${TRUSTSTORE_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic "${USER_SECRET}" \
  --from-file=tls.crt="${USER_CERT}" \
  --from-file=tls.key="${USER_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ "${RESTART}" == true ]]; then
  for workload_type in deployment statefulset daemonset; do
    mapfile -t workloads < <(
      kubectl -n "${NAMESPACE}" get "${workload_type}" -o json | jq -r --arg secret "${SERVER_SECRET}" \
        '.items[] | select(any(.spec.template.spec.volumes[]?; .secret.secretName == $secret)) | .metadata.name'
    )
    for workload_name in "${workloads[@]}"; do
      kubectl -n "${NAMESPACE}" rollout restart "${workload_type}/${workload_name}"
    done
    for workload_name in "${workloads[@]}"; do
      kubectl -n "${NAMESPACE}" rollout status "${workload_type}/${workload_name}" --timeout=10m
    done
  done
fi

echo "Server certificate secret '${SERVER_SECRET}' and user certificate secret '${USER_SECRET}' are current in namespace '${NAMESPACE}'."
