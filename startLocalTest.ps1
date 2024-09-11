Write-Output "Pulling images down..."
docker pull rabbitmq:3.11.4-alpine
docker pull busybox:1.28
docker pull ghcr.io/nationalsecurityagency/datawave/ingest-kubernetes:6.9.0-SNAPSHOT
Write-Output "Setting up minikube..."
minikube delete --all --purge
minikube start --cpus 8 --memory 12000 --disk-size 20480
Write-Output "Loading rabbitmq into minikube..."
minikube image load rabbitmq:3.11.4-alpine
Write-Output "Loading busybox into minikube..."
minikube image load busybox:1.28
Write-Output "Loading ingest-kubernetes into minikube..."
minikube image load ghcr.io/nationalsecurityagency/datawave/ingest-kubernetes:6.9.0-SNAPSHOT
Write-Output "Enabling ingress in minikube..."
minikube addons enable ingress
minikube kubectl -- delete -A ValidatingWebhookConfiguration ingress-nginx-admission
minikube kubectl -- patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p="[{'op': 'add', 'path': '/spec/template/spec/containers/0/args/-', 'value':'--enable-ssl-passthrough'}]"

Write-Output "Setting up GHCR secret..."
if (Test-Path .\ghcr-image-pull-secret.yaml) {
    Write-Output "apply secret!!"
    minikube kubectl -- apply -f ./ghcr-image-pull-secret.yaml
}

Write-Output "Clearing out old tgz files..."
mkdir .\datawave-stack\charts -Force
foreach($zip_item in (Get-ChildItem -Recurse -Include *.tgz)) {
    Remove-Item $zip_item.FullName
}

Write-Output "Packaging helm charts..."
# Create the individual tar balls and copy them to datawave-stack
foreach($folder in ("hadoop", "accumulo", "zookeeper", "ingest", "web")) {
    Write-Output $folder
    Set-Location $folder
    helm lint .
    helm package .
    Copy-Item *.tgz ../datawave-stack/charts/
    Set-Location ..
}

Write-Output "Packaging and deploying datawave-stack..."
# Deploy datawave-stack
Set-Location datawave-stack
helm lint .
helm package .
helm install dwv datawave-system-3.40.0.tgz -f "values-testing.yaml"
Set-Location ..