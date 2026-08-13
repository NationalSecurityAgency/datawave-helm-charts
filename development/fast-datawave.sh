#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CHART_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
DATAWAVE_SOURCE="${DATAWAVE_SOURCE:-${CHART_ROOT}/../datawave}"
NAMESPACE="${NAMESPACE:-default}"
SKIP_BUILD=false
MODULE=""
COMMAND=""
KUBECTL=(kubectl)
MAVEN_COMMAND="${MAVEN_COMMAND:-mvn}"
TEMP_DIR=""
WEB_ROOT_INCREMENTAL=false

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Build and load local DataWave code into an artifact-overlay-enabled deployment.

Usage:
  fast-datawave.sh [options] web
  fast-datawave.sh [options] ingest
  fast-datawave.sh [options] all
  fast-datawave.sh [options] status

Options:
  --datawave PATH    DataWave source checkout (default: sibling of chart repo)
  -n, --namespace NS Kubernetes namespace (default: default)
  --context NAME     Kubernetes context
  --module MODULE    First build and install only this changed Maven module and
                     its prerequisites, then assemble the selected application
  --skip-build       Reuse the most recently built local EAR or ingest archive
  -h, --help         Show this help

Examples:
  ./development/fast-datawave.sh web
  ./development/fast-datawave.sh --module warehouse/ingest-json ingest
  ./development/fast-datawave.sh --skip-build web
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

while (($#)); do
    case "$1" in
        web|ingest|all|status)
            [[ -z "${COMMAND}" ]] || fail "Only one command may be specified"
            COMMAND="$1"
            shift
            ;;
        --datawave)
            (($# >= 2)) || fail "--datawave requires a path"
            DATAWAVE_SOURCE="$2"
            shift 2
            ;;
        -n|--namespace)
            (($# >= 2)) || fail "$1 requires a namespace"
            NAMESPACE="$2"
            shift 2
            ;;
        --context)
            (($# >= 2)) || fail "--context requires a name"
            KUBECTL+=(--context "$2")
            shift 2
            ;;
        --module)
            (($# >= 2)) || fail "--module requires a Maven module path or artifactId"
            MODULE="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "${COMMAND}" ]] || { usage; exit 2; }

kube() {
    "${KUBECTL[@]}" -n "${NAMESPACE}" "$@"
}

find_running_pod() {
    local selector="$1"
    local pod
    pod="$(kube get pods -l "${selector}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${pod}" ]] || fail "No running pod found for selector ${selector} in namespace ${NAMESPACE}"
    printf '%s\n' "${pod}"
}

require_overlay() {
    local pod="$1"
    local volume
    volume="$(kube get pod "${pod}" -o jsonpath='{.spec.volumes[?(@.name=="development-artifact-overlay")].name}')"
    [[ "${volume}" == "development-artifact-overlay" ]] || fail \
        "Pod ${pod} does not have the development artifact overlay. Enable values-fast-development.yaml and redeploy first."
}

maven_common=(-Dmaven.test.skip=true -DskipTests -DskipITs -DskipMicroservices -Dspotbugs.skip=true -Dcheckstyle.skip=true)

require_java_11() {
    local java_version java_major
    java_version="$("${MAVEN_COMMAND}" -version | sed -n 's/^Java version: \([^,]*\).*/\1/p' | head -n1)"
    java_major="${java_version%%.*}"
    [[ "${java_major}" == 11 ]] || fail \
        "DataWave web/ingest assembly requires JDK 11; Maven is using Java ${java_version:-unknown}. Set JAVA_HOME to a JDK 11 installation."
}

build_changed_module() {
    local module_selector
    [[ -n "${MODULE}" ]] || return 0
    module_selector="${MODULE}"
    if [[ "${module_selector}" != */* && "${module_selector}" != :* ]]; then
        module_selector=":${module_selector}"
    fi
    log "Building changed module ${MODULE} and installing it in the local Maven repository"
    (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" -pl "${module_selector}" -am install "${maven_common[@]}")
}

build_web() {
    if [[ "${MODULE}" == "web-services/web-root" || "${MODULE}" == ":datawave-ws-web-root" || "${MODULE}" == "datawave-ws-web-root" ]]; then
        ${SKIP_BUILD} || build_changed_module
        WEB_ROOT_INCREMENTAL=true
        log "The changed web-root WAR will be inserted into the running baseline EAR"
        return 0
    fi
    ${SKIP_BUILD} && return 0
    build_changed_module
    log "Assembling the DataWave web EAR (no container build)"
    if [[ -n "${MODULE}" ]]; then
        (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" -Pdeploy-ws -pl :datawave-ws-deploy-application package "${maven_common[@]}")
    else
        (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" -Pdeploy-ws -pl :datawave-ws-deploy-application -am package "${maven_common[@]}")
    fi
}

sync_web_root() {
    local pod="$1"
    local container="$2"
    local local_war remote_dir baseline_ear remote_ear remote_upload ear_entry remote_war
    local_war="${DATAWAVE_SOURCE}/web-services/web-root/target/datawave-ws-web-root.war"
    [[ -f "${local_war}" ]] || fail "The web-root WAR was not created: ${local_war}"
    remote_dir=/opt/jboss/wildfly/standalone/deployments
    baseline_ear="$(kube exec "${pod}" -c "${container}" -- /bin/bash -ec \
        "ls -1 '${remote_dir}'/*.ear | head -n1")"
    [[ -n "${baseline_ear}" ]] || fail "No baseline EAR is deployed in ${pod}"
    ear_entry="$(kube exec "${pod}" -c "${container}" -- /bin/bash -ec \
        "jar tf '${baseline_ear}' | grep 'datawave-ws-web-root.*\\.war$' | head -n1")"
    [[ -n "${ear_entry}" && "${ear_entry}" != */* ]] || fail \
        "Could not identify the web-root WAR inside ${baseline_ear}"
    remote_ear="${remote_dir}/datawave-ws-deploy-application-fast-dev.ear"
    remote_upload="${remote_dir}/.fast-dev.ear.uploading"
    remote_war="/tmp/${ear_entry}"

    log "Uploading $(basename "${local_war}") to ${pod}"
    kube cp "${local_war}" "${pod}:${remote_war}" -c "${container}"
    log "Replacing ${ear_entry} inside the running baseline EAR"
    kube exec "${pod}" -c "${container}" -- /bin/bash -ec \
        "cp '${baseline_ear}' '${remote_upload}'; cd /tmp; jar uf '${remote_upload}' '${ear_entry}'; rm -f '${remote_war}'; rm -f '${remote_dir}'/datawave-ws-deploy-application-*.ear '${remote_dir}'/datawave-ws-deploy-application-*.ear.*; mv '${remote_upload}' '${remote_ear}'"
    restart_web_container "${pod}" "${container}"
    wait_for_web_deployment "${pod}" "${container}" "${remote_ear}"
}

restart_web_container() {
    local pod="$1"
    local container="$2"
    local before after=""
    before="$(kube get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].restartCount}')"

    # A full EAR hot deployment temporarily holds both applications in this
    # memory-constrained development container. Starting a fresh JVM is faster
    # and avoids that transient heap spike; the pod-local overlay survives.
    log "Restarting the web container to load the staged EAR"
    kube exec "${pod}" -c "${container}" -- /bin/bash -c 'kill -TERM 1' \
        >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
        after="$(kube get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
        if [[ "${after}" =~ ^[0-9]+$ ]] && ((after > before)); then
            return 0
        fi
        sleep 1
    done
    fail "The web container did not restart after staging the EAR"
}

wait_for_web_deployment() {
    local pod="$1"
    local container="$2"
    local remote_ear="$3"
    local status=""
    log "Waiting for WildFly to deploy the EAR"
    for _ in $(seq 1 90); do
        if kube exec "${pod}" -c "${container}" -- test -f "${remote_ear}.failed" \
            >/dev/null 2>&1; then
            fail "WildFly rejected the EAR. Inspect ${remote_ear}.failed and the pod logs."
        fi
        if kube exec "${pod}" -c "${container}" -- test -f "${remote_ear}.deployed" \
            >/dev/null 2>&1; then
            status=deployed
            break
        fi
        sleep 2
    done
    [[ "${status}" == deployed ]] || fail "Timed out waiting for WildFly to deploy the EAR"

    status=""
    log "Waiting for the DataWave health endpoint"
    for _ in $(seq 1 90); do
        if kube exec "${pod}" -c "${container}" -- \
            curl -fsS http://localhost:8080/DataWave/Common/Health/health \
            >/dev/null 2>&1; then
            status=healthy
            break
        fi
        sleep 2
    done
    [[ "${status}" == healthy ]] || fail "The EAR deployed, but DataWave did not become healthy"
    log "Waiting for Kubernetes to mark the web pod ready"
    kube wait --for=condition=Ready "pod/${pod}" --timeout=180s >/dev/null
    log "Web code is running from the local artifact"
}

newest_web_ear() {
    find "${DATAWAVE_SOURCE}/web-services/deploy/application/target" -maxdepth 1 -type f \
        -name 'datawave-ws-deploy-application-*-dev.ear' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-
}

sync_web() {
    local pod container ear remote_dir remote_ear remote_upload
    pod="$(find_running_pod 'application=datawave-monolith')"
    require_overlay "${pod}"
    container="$(kube get pod "${pod}" -o jsonpath='{.spec.containers[0].name}')"
    if ${WEB_ROOT_INCREMENTAL}; then
        sync_web_root "${pod}" "${container}"
        return 0
    fi
    ear="$(newest_web_ear)"
    [[ -f "${ear}" ]] || fail "No dev EAR found. Run without --skip-build first."
    remote_dir=/opt/jboss/wildfly/standalone/deployments
    remote_ear="${remote_dir}/datawave-ws-deploy-application-fast-dev.ear"
    remote_upload="${remote_dir}/.fast-dev.ear.uploading"

    log "Uploading $(basename "${ear}") to ${pod}"
    kube cp "${ear}" "${pod}:${remote_upload}" -c "${container}"
    kube exec "${pod}" -c "${container}" -- /bin/bash -ec \
        "rm -f '${remote_dir}'/datawave-ws-deploy-application-*.ear '${remote_dir}'/datawave-ws-deploy-application-*.ear.*; mv '${remote_upload}' '${remote_ear}'"

    restart_web_container "${pod}" "${container}"
    wait_for_web_deployment "${pod}" "${container}" "${remote_ear}"
}

build_ingest() {
    ${SKIP_BUILD} && return 0
    build_changed_module
    log "Assembling the DataWave ingest distribution (no RPM or container build)"
    if [[ -n "${MODULE}" ]]; then
        (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" -pl :assemble-datawave -Dtar package "${maven_common[@]}")
    else
        (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" -pl :assemble-datawave -am -Dtar package "${maven_common[@]}")
    fi
}

newest_ingest_archive() {
    find "${DATAWAVE_SOURCE}/warehouse/assemble/datawave/target" -maxdepth 1 -type f \
        -name 'datawave-dev-*-dist.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-
}

sync_ingest() {
    local pod archive staging_dir
    local -a artifact_dirs=()
    pod="$(find_running_pod 'app.kubernetes.io/component=ingest')"
    require_overlay "${pod}"
    archive="$(newest_ingest_archive)"
    [[ -f "${archive}" ]] || fail "No ingest distribution found. Run without --skip-build first."
    staging_dir="$(mktemp -d)"
    TEMP_DIR="${staging_dir}"
    tar -xzf "${archive}" --strip-components=1 -C "${staging_dir}"

    for candidate in lib accumulo-warehouse accumulo-metrics accumulo-geowave; do
        [[ -d "${staging_dir}/${candidate}" ]] && artifact_dirs+=("${candidate}")
    done
    ((${#artifact_dirs[@]})) || fail "The ingest archive contains no recognized library directories"

    log "Stopping ingest processes before replacing libraries"
    kube exec "${pod}" -c ingest -- /bin/bash -c \
        'cd /opt/datawave-ingest/current/bin/system && ./stop-all.sh' || true

    log "Uploading a coherent ingest library set to ${pod}"
    kube exec "${pod}" -c ingest -- /bin/bash -ec \
        'cd /opt/datawave-ingest/current; rm -rf lib accumulo-warehouse accumulo-metrics accumulo-geowave'
    tar -C "${staging_dir}" -cf - "${artifact_dirs[@]}" \
        | kube exec -i "${pod}" -c ingest -- tar -C /opt/datawave-ingest/current -xf -

    log "Refreshing the Accumulo VFS classpath and MapReduce job cache"
    kube exec "${pod}" -c ingest -- /bin/bash -ec '
        export HADOOP_HOME=/usr/local/hadoop
        export HADOOP_CONF_DIR=/usr/local/hadoop/conf
        vfs=hdfs://hdfs-nn:9000/datawave/accumulo-vfs-classpath
        hdfs dfs -rm -f "${vfs}/*.jar" || true
        for directory in accumulo-warehouse/lib accumulo-warehouse/lib/ext; do
            if compgen -G "/opt/datawave-ingest/current/${directory}/*.jar" >/dev/null; then
                hdfs dfs -put -f /opt/datawave-ingest/current/${directory}/*.jar "${vfs}"
            fi
        done
        cd /opt/datawave-ingest/current/bin/ingest
        ./load-job-cache.sh
        cd ../system
        ./start-all.sh
    '
    rm -rf -- "${staging_dir}"
    TEMP_DIR=""
    log "Ingest code is running from the local distribution"
}

show_status() {
    local pod
    echo "Namespace: ${NAMESPACE}"
    for selector in 'app.kubernetes.io/component=ingest' 'application=datawave-monolith'; do
        pod="$(kube get pods -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        if [[ -z "${pod}" ]]; then
            echo "${selector}: no pod"
        elif kube get pod "${pod}" -o jsonpath='{.spec.volumes[?(@.name=="development-artifact-overlay")].name}' | grep -q .; then
            echo "${selector}: ${pod} (artifact overlay enabled)"
        else
            echo "${selector}: ${pod} (artifact overlay disabled)"
        fi
    done
}

command -v kubectl >/dev/null || fail "kubectl is required"
if [[ "${COMMAND}" != status ]]; then
    [[ -d "${DATAWAVE_SOURCE}" ]] || fail "DataWave checkout not found: ${DATAWAVE_SOURCE}"
    command -v "${MAVEN_COMMAND}" >/dev/null || fail "Maven command not found: ${MAVEN_COMMAND}"
    ${SKIP_BUILD} || require_java_11
fi

case "${COMMAND}" in
    web)
        build_web
        sync_web
        ;;
    ingest)
        build_ingest
        sync_ingest
        ;;
    all)
        build_web
        sync_web
        build_ingest
        sync_ingest
        ;;
    status)
        show_status
        ;;
esac
