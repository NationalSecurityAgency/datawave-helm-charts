Write-Output "Pulling images down..."
docker pull rabbitmq:3.11.4-alpine
docker pull busybox:1.28
Write-Output "Setting up minikube..."
minikube delete --all --purge
minikube start --cpus 8 --memory 12000 --disk-size 20480
Write-Output "Loading rabbitmq into minikube..."
minikube image load rabbitmq:3.11.4-alpine
Write-Output "Loading busybox into minikube..."
minikube image load busybox:1.28
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
# mkdir .\datawave-stack\charts -Force
foreach($zip_item in (Get-ChildItem -Recurse -Include *.tgz)) {
    Remove-Item $zip_item.FullName
}

Set-Location datawave-monolith-umbrella
helm dependency update
helm package .

Write-Output "Packaging and deploying datawave-stack..."
# Deploy datawave-stack
Set-Location ../datawave-stack
helm dependency update
helm lint .
helm package .
kubectl create secret generic certificates-secret --from-file=keystore.p12=certificates/keystore.p12 --from-file=truststore.jks=certificates/truststore.jks
$PACKAGE = Resolve-Path "./datawave-system-*.tgz" | Select-Object -ExpandProperty Path
helm install dwv $PACKAGE -f "values-testing.yaml"
Set-Location ..