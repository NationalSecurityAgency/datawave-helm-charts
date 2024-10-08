#!/usr/bin/env bash

VALUES_FILE=${1:-values.yaml}
USE_LOCAL_ZOOKEEPER=${USE_LOCAL_ZOOKEEPER:-false}
USE_LOCAL_HADOOP=${USE_LOCAL_HADOOP:-false}
INIT_LOCAL_HADOOP=${INIT_LOCAL_HADOOP:-false}
EXTRA_HELM_ARGS=${EXTRA_HELM_ARGS:""}
BASEDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit; pwd -P )"
DATAWAVE_STACK="${BASEDIR}/datawave-stack"

. ./shared-functions.sh
function helm_install() {
  if ${USE_LOCAL_ZOOKEEPER}; then
    start_zk
    EXTRA_HELM_ARGS="${EXTRA_HELM_ARGS} --set charts.zookeeper.enabled=false"
  fi
  if ${USE_LOCAL_HADOOP}; then
    start_hadoop
    EXTRA_HELM_ARGS="${EXTRA_HELM_ARGS} --set charts.hadoop.enabled=false"
  else
    update_hosts_file_for_hadoop
  fi

  # shellcheck disable=SC2086
  helm install dwv "${DATAWAVE_STACK}"/datawave-qms*.tgz -f "${DATAWAVE_STACK}"/${VALUES_FILE} ${EXTRA_HELM_ARGS}
}


function helm_package() {
  find . -name "*.tgz" -delete
  cd "${BASEDIR}"/common-service-library || exit
  helm package .
  cd "${BASEDIR}" || exit
  for chart in executor query query-metrics kafka kafdrop modification mr-query audit authorization cache configuration dictionary hadoop ingest mysql rabbitmq zookeeper; do
    cd "${BASEDIR}"/$chart || exit
    helm dependency update
    helm package .
  done
  cd "${BASEDIR}"/datawave-qms-umbrella || exit
  helm dependency update
  helm package .
  cd "${BASEDIR}"/datawave-qms-stack || exit
  helm dependency update
  helm package .
  cd "${BASEDIR}" || exit
}

echo "Login to Helm Charts repo using docker"
docker_login
echo "Package helm charts"
helm_package
echo "Purge and restart Minikube"
start_minikube
echo "Initialize Hosts file"
initialize_hosts_file
echo "Update COREDNS"
updateCoreDns
echo "Running Helm Install"
helm_install
echo "Deploy to MiniKube complete!"

#Currently Disabled. See DataWave repo on how to get this json file.
#kubectl cp tv-show-raw-data-stock.json dwv-dwv-hadoop-hdfs-nn-0:/tmp && \
#kubectl exec -it dwv-dwv-hadoop-hdfs-nn-0 -- hdfs dfs -put /tmp/tv-show-raw-data-stock.json /data/myjson
