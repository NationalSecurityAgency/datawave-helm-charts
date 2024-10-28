#!/usr/bin/env bash

## Support for this script is discontinued. See datawave-driver.sh



VALUES_FILE=${1:-values.yaml}
USE_LOCAL_ZOOKEEPER=${USE_LOCAL_ZOOKEEPER:-false}
USE_LOCAL_HADOOP=${USE_LOCAL_HADOOP:-false}
INIT_LOCAL_HADOOP=${INIT_LOCAL_HADOOP:-false}
EXTRA_HELM_ARGS=${EXTRA_HELM_ARGS:""}
BASEDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit; pwd -P )"
DATAWAVE_STACK="${BASEDIR}/datawave-stack"

function start_minikube() {
  # Cache images and reset minikube. Then Setup minikube ingress.
  docker pull rabbitmq:3.11.4-alpine && \
  docker pull mysql:8.0.32 && \
  docker pull busybox:1.28 && \
  minikube delete --all --purge && \
  minikube start --nodes 3 --cpus 4 --memory 15960 --disk-size 20480 && \
  minikube image load rabbitmq:3.11.4-alpine  && \
  minikube image load busybox:1.28 && \
  minikube image load mysql:8.0.32 && \
  minikube addons enable ingress && \
  minikube kubectl -- delete -A ValidatingWebhookConfiguration ingress-nginx-admission && \
  minikube kubectl -- patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--enable-ssl-passthrough"}]' && \

  # update default storage provisioner, set csi-hostpath-sc as the default storage driver
  echo "Enabling volumesnapshots and csi-hostpath-driver"
  minikube addons enable volumesnapshots
  minikube addons enable csi-hostpath-driver
  minikube addons disable storage-provisioner
  minikube addons disable default-storageclass
  minikube kubectl -- patch storageclass csi-hostpath-sc -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  #Apply GHCR credentials
  if test -f "${BASEDIR}"/ghcr-image-pull-secret.yaml; then
    minikube kubectl -- apply -f "${BASEDIR}"/ghcr-image-pull-secret.yaml
  fi

  minikube kubectl -- create secret generic certificates-secret --from-file=keystore.p12="${DATAWAVE_STACK}"/certificates/keystore.p12 --from-file=truststore.jks="${DATAWAVE_STACK}"/certificates/truststore.jks
}

function ghcr_login() {
  if test -f "${BASEDIR}"/ghcr-image-pull-secret.yaml; then
    # File path
    FILE_PATH="./ghcr-image-pull-secret.yaml"

    # Extract the base64-encoded .dockerconfigjson value
    ENCODED_JSON=$(grep '.dockerconfigjson:' $FILE_PATH | awk '{print $2}')

    # Decode the JSON value
    DECODED_JSON=$(echo $ENCODED_JSON | base64 --decode)

    # Extract the base64-encoded auth value for ghcr.io
    ENCODED_AUTH=$(echo $DECODED_JSON | jq -r '.auths["ghcr.io"].auth')

    # Decode the auth value to get username:password
    AUTH=$(echo $ENCODED_AUTH | base64 --decode)

    # Split the username and password
    USERNAME=$(echo $AUTH | cut -d ':' -f 1)
    PASSWORD=$(echo $AUTH | cut -d ':' -f 2)
  
    echo $PASSWORD | docker login ghcr.io --username $USERNAME --password-stdin
    echo $PASSWORD | helm registry login ghcr.io --username $USERNAME --password-stdin
  fi
}

function initialize_hosts_file() {
  sudo sed -i "/^$/d" /etc/hosts
  sudo sed -i "/.*datawave\.org.*/d" /etc/hosts
  sudo sed -i "/.*zookeeper.*/d" /etc/hosts
  sudo sed -i "/.*hdfs.*/d" /etc/hosts
  sudo sed -i "/.*yarn.*/d" /etc/hosts
  echo "$(minikube ip) accumulo.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip) web.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip) dictionary.datawave.org" | sudo tee -a /etc/hosts
}

function updateCoreDns() {
  if ${USE_LOCAL_ZOOKEEPER} && ${USE_LOCAL_HADOOP}; then
    "${BASEDIR}"/updateCorefile.sh coredns.corefile-both.template
  elif ${USE_LOCAL_ZOOKEEPER}; then
    "${BASEDIR}"/updateCorefile.sh coredns.corefile-zookeeper.template
  elif ${USE_LOCAL_HADOOP}; then
    "${BASEDIR}"/updateCorefile.sh coredns.corefile-hadoop.template
  else
    "${BASEDIR}"/updateCorefile.sh coredns.corefile-default.template
  fi
}

function update_hosts_file_for_hadoop() {
  echo "$(minikube ip) namenode.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip) resourcemanager.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip) historyserver.datawave.org" | sudo tee -a /etc/hosts
}

function start_zk() {
  "${BASEDIR}"/startZookeeper.sh
  echo "$(minikube ip | cut -f1,2,3 -d .).1 zookeeper" | sudo tee -a /etc/hosts
}

function start_hadoop() {
  "${BASEDIR}"/startHadoop.sh
  echo "$(minikube ip | cut -f1,2,3 -d .).1 hdfs-nn" | sudo tee -a /etc/hosts
  echo "$(minikube ip | cut -f1,2,3 -d .).1 hdfs-dn" | sudo tee -a /etc/hosts
  echo "$(minikube ip | cut -f1,2,3 -d .).1 yarn-rn" | sudo tee -a /etc/hosts
  echo "$(minikube ip | cut -f1,2,3 -d .).1 yarn-nm" | sudo tee -a /etc/hosts

  echo "$(minikube ip | cut -f1,2,3 -d .).1 namenode.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip | cut -f1,2,3 -d .).1 resourcemanager.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip | cut -f1,2,3 -d .).1 historyserver.datawave.org" | sudo tee -a /etc/hosts
}

function helm_package() {
  find . -name "*.tgz" -delete
  cd "${BASEDIR}"/common-service-library || exit
  helm package .
  cd "${BASEDIR}" || exit
  for chart in audit authorization cache configuration dictionary datawave-monolith hadoop ingest mysql rabbitmq zookeeper; do
    cd "${BASEDIR}"/$chart || exit
    helm dependency update
    helm package .
  done
  cd "${BASEDIR}"/datawave-monolith-umbrella || exit
  helm dependency update
  helm package .
  cd "${BASEDIR}"/datawave-stack || exit
  helm dependency update
  helm package .
  cd "${BASEDIR}" || exit
}
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
  helm install dwv "${DATAWAVE_STACK}"/datawave-system-*.tgz -f "${DATAWAVE_STACK}"/${VALUES_FILE} ${EXTRA_HELM_ARGS}
}

echo "Login to Docker and Helm Charts GHCR repo"
ghcr_login
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
