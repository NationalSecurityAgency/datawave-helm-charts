
function start_minikube() {
  # Cache images and reset minikube. Then Setup minikube ingress.
  docker pull rabbitmq:3.11.4-alpine && \
  docker pull busybox:1.28 && \
  minikube delete --all --purge && \
  minikube start --nodes 3 --cpus 4 --memory 15960 --disk-size 20480 && \
  minikube image load rabbitmq:3.11.4-alpine  && \
  minikube image load busybox:1.28 && \
  minikube image load mysql:8.0.32 && \
  minikube addons enable ingress && \
  minikube kubectl -- delete -A ValidatingWebhookConfiguration ingress-nginx-admission && \
  minikube kubectl -- patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--enable-ssl-passthrough"}]' && \

  #Apply GHCR credentials
  if test -f "${BASEDIR}"/ghcr-image-pull-secret.yaml; then
    minikube kubectl -- apply -f "${BASEDIR}"/ghcr-image-pull-secret.yaml
  fi

  minikube kubectl -- create secret generic certificates-secret --from-file=keystore.p12="${DATAWAVE_STACK}"/certificates/keystore.p12 --from-file=truststore.jks="${DATAWAVE_STACK}"/certificates/truststore.jks
}

function docker_login() {
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
