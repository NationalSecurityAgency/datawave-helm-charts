#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CHART_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
DATAWAVE_SOURCE="${DATAWAVE_SOURCE:-${CHART_ROOT}/../datawave}"
NAMESPACE="${NAMESPACE:-datawave-fast-dev}"
WEB_URL="${WEB_URL:-https://web.datawave.org/}"
SOURCE_FILE="${DATAWAVE_SOURCE}/web-services/web-root/src/main/webapp/index.html"
BACKUP_FILE="${SOURCE_FILE}.fast-web-demo-backup"
FAST_DATAWAVE_COMMAND="${FAST_DATAWAVE_COMMAND:-${SCRIPT_DIR}/fast-datawave.sh}"
MAVEN_COMMAND="${MAVEN_COMMAND:-mvn}"
MARKER='id="fast-web-iteration-demo"'
MODE="${1:-demo}"

usage() {
    cat <<'EOF'
Show a complete DataWave web edit/build/reload loop.

Usage:
  demo-fast-web-iteration.sh          Run the interactive demonstration
  demo-fast-web-iteration.sh reset    Restore the pre-demo source file

Environment:
  DATAWAVE_SOURCE  DataWave checkout (default: sibling of the chart repository)
  NAMESPACE        Kubernetes namespace (default: datawave-fast-dev)
  WEB_URL          Page shown to the user (default: https://web.datawave.org/)
  MAVEN_COMMAND    Maven executable used by fast-datawave.sh (default: mvn)
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

reset_demo() {
    [[ -f "${BACKUP_FILE}" ]] || fail "No demo backup exists at ${BACKUP_FILE}"
    mv -- "${BACKUP_FILE}" "${SOURCE_FILE}"
    echo "Restored ${SOURCE_FILE}"
    echo "Run the demo again to build and deploy the restored page."
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

[[ -f "${SOURCE_FILE}" ]] || fail "DataWave web page not found: ${SOURCE_FILE}"
[[ ! -e "${BACKUP_FILE}" ]] || fail \
    "A previous demo backup exists. Run '$0 reset' before starting another demo."
[[ -x "${FAST_DATAWAVE_COMMAND}" ]] || fail "Fast reload helper is not executable: ${FAST_DATAWAVE_COMMAND}"

if [[ "${FAST_DATAWAVE_COMMAND}" == "${SCRIPT_DIR}/fast-datawave.sh" ]]; then
    command -v "${MAVEN_COMMAND}" >/dev/null || fail "Maven command not found: ${MAVEN_COMMAND}"
    java_version="$("${MAVEN_COMMAND}" -version | sed -n 's/^Java version: \([^,]*\).*/\1/p' | head -n1)"
    [[ "${java_version%%.*}" == 11 ]] || fail \
        "The DataWave build requires JDK 11; Maven is using Java ${java_version:-unknown}. Set JAVA_HOME to JDK 11."
fi

if grep -q "${MARKER}" "${SOURCE_FILE}"; then
    fail "The demo banner already exists in ${SOURCE_FILE}; remove it or restore the demo backup first."
fi

cat <<EOF

Fast DataWave web iteration demonstration

1. Open this page now:

   ${WEB_URL}

   Accept the local development certificate warning if your browser displays it.
   The page currently says: "This is DataWave."

EOF
read -r -p "Press Enter after you have opened the original page... "

cp -p -- "${SOURCE_FILE}" "${BACKUP_FILE}"
demo_time="$(date '+%Y-%m-%d %H:%M:%S %Z')"
banner="        <p id=\"fast-web-iteration-demo\" style=\"padding: 1rem; background: #dff6dd; border: 2px solid #237804; font-family: sans-serif;\"><strong>Fast iteration works!</strong> Reloaded from local DataWave source at ${demo_time}.</p>"

temporary_file="$(mktemp "${SOURCE_FILE}.XXXXXX")"
cleanup() {
    [[ ! -e "${temporary_file}" ]] || rm -f -- "${temporary_file}"
}
trap cleanup EXIT
trap 'echo "Demo stopped after changing the source. Run $0 reset to restore it." >&2' ERR

awk -v banner="${banner}" '
    /<\/body>/ && !inserted { print banner; inserted=1 }
    { print }
    END { if (!inserted) exit 2 }
' "${SOURCE_FILE}" > "${temporary_file}" || fail "Could not find </body> in ${SOURCE_FILE}"
chmod --reference="${SOURCE_FILE}" "${temporary_file}"
mv -- "${temporary_file}" "${SOURCE_FILE}"

cat <<EOF

2. Changed DataWave source:

   ${SOURCE_FILE}

   Added a timestamped green "Fast iteration works!" banner.

3. Building the changed web-root module and reloading the web container...

EOF

"${FAST_DATAWAVE_COMMAND}" \
    --datawave "${DATAWAVE_SOURCE}" \
    --namespace "${NAMESPACE}" \
    --module web-services/web-root \
    web

cat <<EOF

4. Reload this page in your browser now:

   ${WEB_URL}

   The green banner should display this build time: ${demo_time}
   Use a hard refresh if the browser retained the old page.

EOF
read -r -p "Press Enter after you see the new banner... "

cat <<EOF

Fast web iteration demonstration complete.

The source change remains in your DataWave working tree for inspection.
Restore it later with:

   $0 reset

After resetting, run the normal fast web command once more to redeploy the
original page:

   ${SCRIPT_DIR}/fast-datawave.sh --namespace ${NAMESPACE} --module web-services/web-root web

EOF
