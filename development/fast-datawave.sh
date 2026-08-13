#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CHART_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
DATAWAVE_SOURCE="${DATAWAVE_SOURCE:-${CHART_ROOT}/../datawave}"
NAMESPACE="${NAMESPACE:-default}"
SKIP_BUILD=false
MODULE=""
COMMAND=""
RELEASE="${RELEASE:-dwv}"
KUBECTL=(kubectl)
MAVEN_COMMAND="${MAVEN_COMMAND:-mvn}"
TEMP_DIR=""
WEB_ROOT_INCREMENTAL=false
INGEST_JAR_INCREMENTAL=false
INGEST_ARTIFACT_ID=""
VALUES_FILES=()
CONFIG_VALUES_FILE=""

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
  fast-datawave.sh [options] web-config
  fast-datawave.sh [options] ingest-config
  fast-datawave.sh [options] config
  fast-datawave.sh [options] status

Options:
  --datawave PATH    DataWave source checkout (default: sibling of chart repo)
  -n, --namespace NS Kubernetes namespace (default: default)
  --context NAME     Kubernetes context
  --release NAME     Helm release containing DataWave (default: dwv)
  -f, --values FILE  Additional root-stack values to render for a config reload;
                     may be repeated. The release's explicit values are used first.
  --module MODULE    First build and install only this changed Maven module and
                     its prerequisites, then assemble the selected application
  --skip-build       Reuse the most recently built local EAR or ingest archive
  -h, --help         Show this help

Examples:
  ./development/fast-datawave.sh web
  ./development/fast-datawave.sh --module warehouse/ingest-json ingest
  ./development/fast-datawave.sh -n datawave-fast-dev web-config
  ./development/fast-datawave.sh -n datawave-fast-dev -f my-values.yaml ingest-config
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
        web|ingest|all|web-config|ingest-config|config|status)
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
        --release)
            (($# >= 2)) || fail "--release requires a name"
            RELEASE="$2"
            shift 2
            ;;
        -f|--values)
            (($# >= 2)) || fail "$1 requires a file"
            VALUES_FILES+=("$2")
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

require_config_reload() {
    local pod="$1"
    local init_container
    init_container="$(kube get pod "${pod}" -o jsonpath='{.spec.initContainers[*].name}')"
    [[ " ${init_container} " == *" initialize-config-reload "* ]] || fail \
        "Pod ${pod} does not have the development config-reload layer. Enable values-fast-development.yaml and redeploy first."
}

prepare_config_values() {
    local component="$1"
    local root_values child_values
    [[ -n "${TEMP_DIR}" ]] || TEMP_DIR="$(mktemp -d)"
    root_values="${TEMP_DIR}/root-values.yaml"
    child_values="${TEMP_DIR}/${component}-values.yaml"
    helm get values "${RELEASE}" -n "${NAMESPACE}" -o yaml > "${TEMP_DIR}/release-values.yaml"
    local values_file
    for values_file in "${VALUES_FILES[@]}"; do
        [[ -f "${values_file}" ]] || fail "Values file not found: ${values_file}"
    done
    if ((${#VALUES_FILES[@]})); then
        yq ea '. as $item ireduce ({}; . * $item)' \
            "${TEMP_DIR}/release-values.yaml" "${VALUES_FILES[@]}" > "${root_values}"
    else
        cp "${TEMP_DIR}/release-values.yaml" "${root_values}"
    fi
    case "${component}" in
        web)
            yq eval '. as $root | (($root."datawave-monolith-umbrella"."dwv-web" // {}) * {"global": ($root.global // {})})' \
                "${root_values}" > "${child_values}"
            ;;
        ingest)
            yq eval '. as $root | (($root."dwv-ingest" // {}) * {"global": ($root.global // {})})' \
                "${root_values}" > "${child_values}"
            ;;
    esac
    CONFIG_VALUES_FILE="${child_values}"
}

copy_config_key() {
    local pod="$1" config_map="$2" key="$3" target="$4"
    [[ "${key}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Unsafe ConfigMap key: ${key}"
    kube exec "${pod}" -c "${5}" -- /bin/bash -ec \
        "mkdir -p '$(dirname "${target}")'; [[ -e '${target}' ]] || touch '${target}'; [[ -w '${target}' ]] || chmod u+w '${target}'"
    kube get configmap "${config_map}" -o json \
        | yq eval ".data[\"${key}\"]" - \
        | kube exec -i "${pod}" -c "${5}" -- /bin/bash -ec "cat > '${target}'"
    local expected actual
    expected="$(kube get configmap "${config_map}" -o json | yq eval ".data[\"${key}\"]" - | sha256sum | cut -d' ' -f1)"
    actual="$(kube exec "${pod}" -c "${5}" -- sha256sum "${target}" | cut -d' ' -f1)"
    [[ "${expected}" == "${actual}" ]] || fail "Runtime verification failed for ${target}"
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

reload_web_config() {
    local pod container values manifest remote_ear
    pod="$(find_running_pod 'application=datawave-monolith')"
    require_config_reload "${pod}"
    container="$(kube get pod "${pod}" -o jsonpath='{.spec.containers[0].name}')"
    prepare_config_values web
    values="${CONFIG_VALUES_FILE}"
    manifest="${TEMP_DIR}/web-config.yaml"

    log "Rendering the local web runtime ConfigMap"
    helm template dwv-web "${CHART_ROOT}/datawave-monolith" -f "${values}" \
        --show-only templates/datawave-runtime-config-map.yaml > "${manifest}"
    kube apply -f "${manifest}" >/dev/null
    copy_config_key "${pod}" dwv-web-web-runtime-config runtime-config.cli \
        /opt/jboss/wildfly/runtime-config.cli "${container}"
    remote_ear="$(kube exec "${pod}" -c "${container}" -- /bin/bash -ec \
        'ls -1 /opt/jboss/wildfly/standalone/deployments/*.ear | head -n1')"
    restart_web_container "${pod}" "${container}"
    wait_for_web_deployment "${pod}" "${container}" "${remote_ear}"
    log "Web runtime configuration matches the rendered ConfigMap"
}

build_ingest() {
    case "${MODULE}" in
        warehouse/ingest-json|:datawave-ingest-json|datawave-ingest-json)
            ${SKIP_BUILD} || build_ingest_json
            INGEST_JAR_INCREMENTAL=true
            INGEST_ARTIFACT_ID=datawave-ingest-json
            log "The changed ${INGEST_ARTIFACT_ID} JAR will replace the running baseline JAR"
            return 0
            ;;
    esac
    ${SKIP_BUILD} && return 0
    build_changed_module
    log "Assembling the DataWave ingest distribution (no RPM or container build)"
    if [[ -n "${MODULE}" ]]; then
        (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" -pl :assemble-datawave -Dtar package "${maven_common[@]}")
    else
        (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" -pl :assemble-datawave -am -Dtar package "${maven_common[@]}")
    fi
}

build_ingest_json() {
    log "Building only the changed datawave-ingest-json JAR"
    if (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" \
        -pl warehouse/ingest-json clean package \
        -Dmaven.build.cache.enabled=false "${maven_common[@]}"); then
        return 0
    fi

    log "Bootstrapping missing ingest-json reactor dependencies (one-time setup)"
    (cd "${DATAWAVE_SOURCE}" && "${MAVEN_COMMAND}" \
        -pl warehouse/ingest-json -am install \
        -DskipTests -DskipITs -DskipMicroservices \
        -Dspotbugs.skip=true -Dcheckstyle.skip=true)
}

sync_ingest_jar() {
    local pod="$1"
    local local_jar remote_staging remote_paths
    local_jar="$(find "${DATAWAVE_SOURCE}/warehouse/ingest-json/target" -maxdepth 1 -type f \
        -name "${INGEST_ARTIFACT_ID}-*.jar" ! -name '*-tests.jar' ! -name 'original-*' \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
    [[ -f "${local_jar}" ]] || fail "The ${INGEST_ARTIFACT_ID} JAR was not created"
    remote_staging="/tmp/${INGEST_ARTIFACT_ID}-fast-dev.jar"
    remote_paths="$(kube exec "${pod}" -c ingest -- /bin/bash -ec \
        "find -L /opt/datawave-ingest/current -type f -name '${INGEST_ARTIFACT_ID}-*.jar' -print")"
    [[ -n "${remote_paths}" ]] || fail "No deployed ${INGEST_ARTIFACT_ID} JAR found in ${pod}"
    kube exec "${pod}" -c ingest -- /bin/bash -ec \
        "chmod u+w /opt/datawave-ingest/current/lib; find -L /opt/datawave-ingest/current -type f -name '${INGEST_ARTIFACT_ID}-*.jar' -exec chmod u+w {} +"

    log "Stopping ingest processes before replacing ${INGEST_ARTIFACT_ID}"
    kube exec "${pod}" -c ingest -- /bin/bash -c \
        'cd /opt/datawave-ingest/current/bin/system && ./stop-all.sh' || true
    log "Uploading $(basename "${local_jar}") to ${pod}"
    kube cp "${local_jar}" "${pod}:${remote_staging}" -c ingest
    while IFS= read -r remote_path; do
        [[ -n "${remote_path}" ]] || continue
        kube exec "${pod}" -c ingest -- cp "${remote_staging}" "${remote_path}"
    done <<< "${remote_paths}"
    kube exec "${pod}" -c ingest -- rm -f "${remote_staging}"

    refresh_ingest_runtime "${pod}"
    log "${INGEST_ARTIFACT_ID} is running from the local JAR"
}

refresh_ingest_runtime() {
    local pod="$1"
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
        FORCE=true ./load-job-cache.sh
        cd ../system
        ./start-all.sh -allforce
    '
    wait_for_ingest_processes "${pod}"
}

wait_for_ingest_processes() {
    local pod="$1"
    log "Waiting for bulk and live ingest services"
    for _ in $(seq 1 60); do
        if kube exec "${pod}" -c ingest -- /bin/bash -ec \
            'pgrep -f "[b]ulk-ingest-server.sh" >/dev/null && pgrep -f "[l]ive-ingest-server.sh" >/dev/null' \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    fail "Ingest libraries were refreshed, but bulk and live ingest did not restart"
}

copy_config_map_directory() {
    local pod="$1" config_map="$2" target_dir="$3"
    local key
    while IFS= read -r key; do
        [[ -n "${key}" ]] || continue
        copy_config_key "${pod}" "${config_map}" "${key}" "${target_dir}/${key}" ingest
    done < <(kube get configmap "${config_map}" -o json | yq eval '.data | keys | .[]' -)
}

reload_ingest_config() {
    local pod values manifest
    pod="$(find_running_pod 'app.kubernetes.io/component=ingest')"
    require_overlay "${pod}"
    require_config_reload "${pod}"
    prepare_config_values ingest
    values="${CONFIG_VALUES_FILE}"
    manifest="${TEMP_DIR}/ingest-config.yaml"

    log "Rendering the local ingest configuration ConfigMaps"
    helm template dwv-ingest "${CHART_ROOT}/ingest" -f "${values}" \
        --show-only templates/datatype-configs-configmap.yaml \
        --show-only templates/flag-maker-configmap.yaml \
        --show-only templates/ingest-config-configmap.yaml \
        --show-only templates/ingest-env-configmap.yaml \
        --show-only templates/xml-config-configmap.yaml > "${manifest}"
    kube apply -f "${manifest}" >/dev/null

    log "Stopping ingest processes before replacing runtime configuration"
    kube exec "${pod}" -c ingest -- /bin/bash -c \
        'cd /opt/datawave-ingest/current/bin/system && ./stop-all.sh' || true
    copy_config_map_directory "${pod}" dwv-ingest-flag-maker-configmap \
        /opt/datawave-ingest/current/config
    copy_config_map_directory "${pod}" dwv-ingest-ingest-config-configmap \
        /opt/datawave-ingest/current/config
    copy_config_map_directory "${pod}" dwv-ingest-data-types-configmap \
        /opt/datawave-ingest/current/config
    copy_config_map_directory "${pod}" datawave-general-ingest-config \
        /opt/datawave-ingest/current/config
    copy_config_key "${pod}" dwv-ingest-ingest-env-configmap ingest-env.sh \
        /opt/datawave-ingest/current/bin/ingest/ingest-env.sh ingest

    refresh_ingest_runtime "${pod}"
    log "Ingest runtime configuration matches the rendered ConfigMaps"
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
    if ${INGEST_JAR_INCREMENTAL}; then
        sync_ingest_jar "${pod}"
        return 0
    fi
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

    refresh_ingest_runtime "${pod}"
    rm -rf -- "${staging_dir}"
    TEMP_DIR=""
    log "Ingest code is running from the local distribution"
}

show_status() {
    local pod overlay config_reload
    echo "Namespace: ${NAMESPACE}"
    for selector in 'app.kubernetes.io/component=ingest' 'application=datawave-monolith'; do
        pod="$(kube get pods -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        if [[ -z "${pod}" ]]; then
            echo "${selector}: no pod"
        else
            overlay=disabled
            config_reload=disabled
            kube get pod "${pod}" -o jsonpath='{.spec.volumes[?(@.name=="development-artifact-overlay")].name}' \
                | grep -q . && overlay=enabled
            kube get pod "${pod}" -o jsonpath='{.spec.initContainers[*].name}' \
                | grep -qw initialize-config-reload && config_reload=enabled
            echo "${selector}: ${pod} (artifact overlay ${overlay}, config reload ${config_reload})"
        fi
    done
}

command -v kubectl >/dev/null || fail "kubectl is required"
if [[ "${COMMAND}" == *-config || "${COMMAND}" == config ]]; then
    command -v helm >/dev/null || fail "helm is required for configuration reloads"
    command -v yq >/dev/null || fail "yq is required for configuration reloads"
fi
if [[ "${COMMAND}" == web || "${COMMAND}" == ingest || "${COMMAND}" == all ]]; then
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
    web-config)
        reload_web_config
        ;;
    ingest-config)
        reload_ingest_config
        ;;
    config)
        reload_web_config
        reload_ingest_config
        ;;
    status)
        show_status
        ;;
esac
