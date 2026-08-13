#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CHART_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
DATAWAVE_SOURCE="${DATAWAVE_SOURCE:-${CHART_ROOT}/../datawave}"
NAMESPACE="${NAMESPACE:-datawave-fast-dev}"
SOURCE_FILE="${DATAWAVE_SOURCE}/warehouse/ingest-json/src/main/java/datawave/ingest/json/config/helper/JsonDataTypeHelper.java"
BACKUP_FILE="${SOURCE_FILE}.fast-ingest-demo-backup"
FAST_DATAWAVE_COMMAND="${FAST_DATAWAVE_COMMAND:-${SCRIPT_DIR}/fast-datawave.sh}"
MARKER=FAST_INGEST_ITERATION_DEMO
MODE="${1:-demo}"

usage() {
    cat <<'EOF'
Show a complete DataWave ingest edit/build/reload loop.

Usage:
  demo-fast-ingest-iteration.sh          Run the interactive demonstration
  demo-fast-ingest-iteration.sh reset    Restore the pre-demo source file

Environment:
  DATAWAVE_SOURCE  DataWave checkout (default: sibling of chart repository)
  NAMESPACE        Kubernetes namespace (default: datawave-fast-dev)
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

find_ingest_pod() {
    kubectl -n "${NAMESPACE}" get pods \
        -l app.kubernetes.io/component=ingest \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

deployed_marker() {
    local pod="$1"
    kubectl -n "${NAMESPACE}" exec "${pod}" -c ingest -- /bin/bash -ec '
        work=/tmp/fast-ingest-demo-check
        jar_file=$(find -L /opt/datawave-ingest/current/lib -type f -name "datawave-ingest-json-*.jar" | head -n1)
        rm -rf "${work}"
        mkdir -p "${work}"
        cd "${work}"
        jar xf "${jar_file}" datawave/ingest/json/config/helper/JsonDataTypeHelper.class
        strings datawave/ingest/json/config/helper/JsonDataTypeHelper.class \
            | grep -o "FAST_INGEST_ITERATION_DEMO_[0-9][^[:space:]]*" \
            | head -n1 || true
        rm -rf "${work}"
    '
}

reset_demo() {
    [[ -f "${BACKUP_FILE}" ]] || fail "No demo backup exists at ${BACKUP_FILE}"
    mv -- "${BACKUP_FILE}" "${SOURCE_FILE}"
    echo "Restored ${SOURCE_FILE}"
    echo "Run the focused ingest command to redeploy the restored code."
}

case "${MODE}" in
    demo) ;;
    reset)
        reset_demo
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        fail "Unknown command: ${MODE}"
        ;;
esac

[[ -f "${SOURCE_FILE}" ]] || fail "DataWave ingest source not found: ${SOURCE_FILE}"
[[ ! -e "${BACKUP_FILE}" ]] || fail \
    "A previous demo backup exists. Run '$0 reset' before starting another demo."
[[ -x "${FAST_DATAWAVE_COMMAND}" ]] || fail "Fast reload helper is not executable: ${FAST_DATAWAVE_COMMAND}"
grep -q "${MARKER}" "${SOURCE_FILE}" && fail "The ingest demo marker already exists in ${SOURCE_FILE}"

pod="$(find_ingest_pod)"
[[ -n "${pod}" ]] || fail "No running ingest pod found in namespace ${NAMESPACE}"
before_marker="$(deployed_marker "${pod}")"
[[ -z "${before_marker}" ]] || fail "The running ingest JAR already contains the demo marker"

cat <<EOF

Fast DataWave ingest iteration demonstration

1. Baseline verified in pod ${pod}:

   The deployed datawave-ingest-json JAR does not contain ${MARKER}.

2. The demo will change this DataWave Java source:

   ${SOURCE_FILE}

   It will add a timestamped build marker, then build and reload only the
   datawave-ingest-json JAR and refresh the Hadoop job cache.

EOF
read -r -p "Press Enter to make and deploy the ingest change... "

cp -p -- "${SOURCE_FILE}" "${BACKUP_FILE}"
demo_time="$(date '+%Y-%m-%d_%H:%M:%S_%Z')"
marker_value="${MARKER}_${demo_time}"
temporary_file="$(mktemp "${SOURCE_FILE}.XXXXXX")"
cleanup() {
    [[ ! -e "${temporary_file}" ]] || rm -f -- "${temporary_file}"
}
trap cleanup EXIT
trap 'echo "Demo stopped after changing the source. Run $0 reset to restore it." >&2' ERR

awk -v marker_value="${marker_value}" '
    /public class JsonDataTypeHelper extends CSVHelper \{/ && !inserted {
        print
        print ""
        print "    public static final String FAST_INGEST_ITERATION_DEMO = \"" marker_value "\";"
        inserted=1
        next
    }
    { print }
    END { if (!inserted) exit 2 }
' "${SOURCE_FILE}" > "${temporary_file}" || fail "Could not find JsonDataTypeHelper class declaration"
chmod --reference="${SOURCE_FILE}" "${temporary_file}"
mv -- "${temporary_file}" "${SOURCE_FILE}"

cat <<EOF

3. Added this Java constant:

   ${marker_value}

4. Building the changed module and reloading ingest...

EOF

"${FAST_DATAWAVE_COMMAND}" \
    --datawave "${DATAWAVE_SOURCE}" \
    --namespace "${NAMESPACE}" \
    --module warehouse/ingest-json \
    ingest

deployed_value="$(deployed_marker "${pod}")"
[[ "${deployed_value}" == "${marker_value}" ]] || fail \
    "The deployed JAR marker did not match: expected ${marker_value}, got ${deployed_value:-none}"

cat <<EOF

5. Verified the changed class in the running ingest pod:

   ${deployed_value}

Fast ingest iteration demonstration complete.

The source change remains for inspection. Restore it later with:

   $0 reset

Then redeploy the restored JAR with:

   ${SCRIPT_DIR}/fast-datawave.sh --namespace ${NAMESPACE} --module warehouse/ingest-json ingest

EOF
read -r -p "Press Enter after reviewing the successful verification... "
