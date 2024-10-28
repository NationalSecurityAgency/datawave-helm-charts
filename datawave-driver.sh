#!/bin/bash
USE_EXISTING_ZOOKEEPER=${USE_EXISTING_ZOOKEEPER:-false}
USE_EXISTING_HADOOP=${USE_EXISTING_HADOOP:-false}
INIT_LOCAL_HADOOP=${INIT_LOCAL_HADOOP:-false}
USING_MINIKUBE=false
BASEDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit; pwd -P )"
DATAWAVE_STACK="${BASEDIR}"/datawave-stack
HELM_CHART=oci://ghcr.io/nationalsecurityagency/datawave-helm-charts/charts/datawave-system
HELM_CHART_VERSION=1.0.0
NAMESPACE=default

function ready_helm_charts() {
  while true; do
    read -p "Enter chart mode (local,remote) [remote]: " chart_mode
    chart_mode=${chart_mode:-remote}
    # Check if input is one of the accepted values
    if [[ -z "$chart_mode" || "$chart_mode" == "" || "$chart_mode" == "local" || "$chart_mode" == "remote" ]]; then
        echo "Using Chart Mode: ${chart_mode:-remote}"
        break
    else
        echo "Invalid input. Please use 'local', 'remote', or leave blank to default."
    fi
  done


  if [ "$chart_mode" == "remote" ]; then
    HELM_CHART=oci://ghcr.io/nationalsecurityagency/datawave-helm-charts/charts/datawave-system
    HELM_CHART_VERSION=1.0.0
  else
    echo "Chart mode is local. Proceed to package all dependencies for the umbrella chart and assemble them"
    package_helm_dependencies "${DATAWAVE_STACK}"
    HELM_CHART="${DATAWAVE_STACK}"/datawave-system*.tgz
  fi
}

package_helm_dependencies() {
    local base_dir="$1"
    local chart_file="$base_dir"/Chart.yaml

    local dependencies=$(yq eval '.dependencies[]' "$chart_file")
    if [ -z "$dependencies" ]; then
        return
    fi

    for dep in $(yq eval '.dependencies[].name' "$chart_file"); do
        local dep_path=$(yq eval ".dependencies[] | select(.name == \"$dep\") | .path" "$chart_file")

        if [ -n "$dep_path" ]; then
            echo "Packaging dependency: $dep"
            package_helm_dependencies "$base_dir/$dep_path"
            
            # Package the dependency and copy it to the charts directory
            helm package "$base_dir/$dep_path"
            mkdir -p "$base_dir/charts"
            mv *.tgz "$base_dir/charts/"
        else
            echo "Dependency $dep in $chart_file has no local path specified."
        fi
    done
}

function update_core_dns() {
  if ${USE_EXISTING_ZOOKEEPER} && ${USE_EXISTING_HADOOP}; then
    "${BASEDIR}"/updateCorefile.sh coredns.corefile-both.template
  elif ${USE_EXISTING_ZOOKEEPER}; then
    "${BASEDIR}"/updateCorefile.sh coredns.corefile-zookeeper.template
  elif ${USE_EXISTING_HADOOP}; then
    "${BASEDIR}"/updateCorefile.sh coredns.corefile-hadoop.template
  else
    "${BASEDIR}"/updateCorefile.sh coredns.corefile-default.template
  fi
}

# Function to check if a Kubernetes cluster is running
function check_k8s_cluster() {
  echo "Checking if Kubernetes is running..."
  kubectl cluster-info &> /dev/null
  if [ $? -ne 0 ]; then
    echo "No Kubernetes cluster found. Deploying Minikube..."
    start_minikube
  else
    echo "Active Kubeconfig found. Would you like to use this cluster (no means minikube should be deployed)? [yes] :"
    read user_input

    if [ "$user_input" = "no" ]; then
      echo "Starting Minikube cluster..."
      start_minikube
    else
      echo "Minikube cluster not started. Using active Kubeconfig"
fi
  fi
}

function set_namespace() {
  echo "Set Namespace [default] :"
  read namespace
  NAMESPACE=${namespace:-default}

  # Check if the namespace exists
  kubectl get namespace $NAMESPACE &> /dev/null

  if [ $? -ne 0 ]; then
    echo "Namespace '$NAMESPACE' does not exist. Creating namespace."
    kubectl create namespace $NAMESPACE
  else
    echo "Namespace '$NAMESPACE' exists."
  fi
}

# Function to start Minikube
function start_minikube() {

  USING_MINIKUBE=true

  echo "Do you want run Minikube purge first? (yes/no) [no]: "
  read user_input
  
  if [ "$user_input" = "yes" ]; then
      echo "Purging the minikube cluster"
      minikube delete --all --purge
  else
      echo "Minikube cluster not purged."
  fi
  minikube start --nodes 3 --cpus 4 --memory 15960 --disk-size 20480 
  if [ $? -eq 0 ]; then
    echo "Minikube started successfully."
  else
    echo "Failed to start Minikube. Exiting."
    exit 1
  fi

  echo "Configure minikube for Datawave Helm charts"
  minikube addons enable ingress
  minikube kubectl -- delete -A ValidatingWebhookConfiguration ingress-nginx-admission
  minikube kubectl -- patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--enable-ssl-passthrough"}]'
  echo "Minikube configured successfully"
}

# Function to perform Helm operations
function preload_docker_image() {
  image=$1
  echo "Pulling $image"
  docker pull $image
  if [ $? -eq 0 ]; then
    echo "$image pulled successfuly"
  else
    echo "Failed to pull required image. Exiting."
    exit 1
  fi

  minikube image load $image 
  if [ $? -eq 0 ]; then
    echo "$image loaded into minikube successfully."
  else
    echo "Failed to load $image into minikube. Exiting."
    exit 1
  fi
  
}

function configure_repository_credentials(){
  if [ ! -e "${BASEDIR}"/ghcr-image-pull-secret.yaml ]; then
    echo "Github Username: "
    read username

    echo "Github Access Token: "
    read -s pat
  
    "${BASEDIR}"/create-image-pull-secrets.sh $username $pat
 
  fi
  kubectl -n $NAMESPACE apply -f "${BASEDIR}"/ghcr-image-pull-secret.yaml
}

function create_secrets(){
  SECRET_NAME=certificates-secret

  kubectl  -n $NAMESPACE get secret $SECRET_NAME &> /dev/null
  if [ $? -ne 0 ]; then
    echo "Secret '$SECRET_NAME' does not exist. Creating secret."
    kubectl  -n $NAMESPACE create secret generic $SECRET_NAME --from-file=keystore.p12="${DATAWAVE_STACK}"/certificates/keystore.p12 --from-file=truststore.jks="${DATAWAVE_STACK}"/certificates/truststore.jks
  else
    echo "Secret '$SECRET_NAME' already exists."
  fi
}



function ghcr_login() {
  echo "Logging in to GHCR for docker and helm"
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
    if [ $? -eq 0 ]; then
      echo "Docker login successful."
    else
      echo "Failed to login to docker. Check credendials. Exiting."
      exit 1
    fi
    echo $PASSWORD | helm registry login ghcr.io --username $USERNAME --password-stdin
    if [ $? -eq 0 ]; then
      echo "Helm login successful."
    else
      echo "Failed to login to helm. Check credendials. Exiting."
      exit 1
    fi
  fi
}

function update_hosts_file_for_hadoop() {
  echo "$(minikube ip) namenode.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip) resourcemanager.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip) historyserver.datawave.org" | sudo tee -a /etc/hosts
}

function configure_etc_hosts(){
  sudo sed -i "/^$/d" /etc/hosts
  sudo sed -i "/.*datawave\.org.*/d" /etc/hosts
  sudo sed -i "/.*zookeeper.*/d" /etc/hosts
  sudo sed -i "/.*hdfs.*/d" /etc/hosts
  sudo sed -i "/.*yarn.*/d" /etc/hosts
  echo "$(minikube ip) accumulo.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip) web.datawave.org" | sudo tee -a /etc/hosts
  echo "$(minikube ip) dictionary.datawave.org" | sudo tee -a /etc/hosts
  
  if ${USE_EXISTING_ZOOKEEPER}; then
    EXTRA_HELM_ARGS="${EXTRA_HELM_ARGS} --set charts.zookeeper.enabled=false"
    echo "$(minikube ip | cut -f1,2,3 -d .).1 zookeeper" | sudo tee -a /etc/hosts
  fi

  if ${USE_EXISTING_HADOOP}; then
    EXTRA_HELM_ARGS="${EXTRA_HELM_ARGS} --set charts.hadoop.enabled=false"
    echo "$(minikube ip | cut -f1,2,3 -d .).1 hdfs-nn" | sudo tee -a /etc/hosts
    echo "$(minikube ip | cut -f1,2,3 -d .).1 hdfs-dn" | sudo tee -a /etc/hosts
    echo "$(minikube ip | cut -f1,2,3 -d .).1 yarn-rn" | sudo tee -a /etc/hosts
    echo "$(minikube ip | cut -f1,2,3 -d .).1 yarn-nm" | sudo tee -a /etc/hosts
    echo "$(minikube ip | cut -f1,2,3 -d .).1 namenode.datawave.org" | sudo tee -a /etc/hosts
    echo "$(minikube ip | cut -f1,2,3 -d .).1 resourcemanager.datawave.org" | sudo tee -a /etc/hosts
    echo "$(minikube ip | cut -f1,2,3 -d .).1 historyserver.datawave.org" | sudo tee -a /etc/hosts
  else
    update_hosts_file_for_hadoop
  fi

}

function helm_install() {
  echo "Enter path values file to use [${DATAWAVE_STACK}/values.yaml]: "
  read values_file

  echo "Starting Helm Deployment"

  # shellcheck disable=SC2086
  helm -n $NAMESPACE install dwv "${DATAWAVE_STACK}"/datawave-system-*.tgz -f ${values_file:-$DATAWAVE_STACK/values.yaml} ${EXTRA_HELM_ARGS} --wait
  if [ $? -eq 0 ]; then
    echo "Helm install successful."
  else
    echo "Helm Install failed. Please investigate."
    exit 1
  fi
}


# Main execution
echo "Starting driver script for DataWave Cluster operations..."

ready_helm_charts
check_k8s_cluster
set_namespace
if [ "$USING_MINIKUBE" = "false" ]; then
    echo "Skipping image preload since minikube cluster was not started with this deployment."
else
    preload_docker_image rabbitmq:3.11.4-alpine
    preload_docker_image mysql:8.0.32
    preload_docker_image busybox:1.28

    configure_etc_hosts
    update_core_dns
fi

configure_repository_credentials
ghcr_login
create_secrets

helm_install



echo "Driver Script completed successfully. See kubectl get po for information"
