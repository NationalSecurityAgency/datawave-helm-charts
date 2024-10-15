param($values_yaml='values.yaml')
$EXTRA_HELM_ARGS=${EXTRA_HELM_ARGS:""}
$BASEDIR="$(Get-Location)"
$DATAWAVE_STACK="$BASEDIR/datawave-stack"
$VALUES_FILE="$DATAWAVE_STACK/$values_yaml"

function start_minikube {
    docker pull rabbitmq:3.11.4-alpine
    docker pull busybox:1.28
    minikube delete --all --purge
    minikube start --nodes 3 --cpus 4 --memory 15690 --disk-size 20480
    minikube image load rabbitmq:3.11.4-alpine
    minikube image load busybox:1.28
    minikube addons enable ingress
    minikube kubectl -- delete -A ValidatingWebhookConfiguration ingress-nginx-admission
    minikube kubectl -- patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p="[{'op': 'add', 'path': '/spec/template/spec/containers/0/args/-', 'value':'--enable-ssl-passthrough'}]"

    if (Test-Path .\ghcr-image-pull-secret.yaml) {
        Write-Output "apply secret!!"
        minikube kubectl -- apply -f ./ghcr-image-pull-secret.yaml
    }

    minikube kubectl -- create secret generic certificates-secret --from-file=keystore.p12="${DATAWAVE_STACK}"/certificates/keystore.p12 --from-file=truststore.jks="${DATAWAVE_STACK}"/certificates/truststore.jks
}

function initialize_hosts_file {
    $HOST_FILE="C:\Windows\System32\drivers\etc\hosts"
    $hosts_content=$(Get-Content $HOST_FILE)
    $hosts_content=$(Write-Output $hosts_content | Where-Object {$_ -notmatch '.*datawave\.org.*'})
    $hosts_content=$(Write-Output $hosts_content |Where-Object {$_ -notmatch '.*zookeeper.*'})
    $hosts_content=$(Write-Output $hosts_content | Where-Object {$_ -notmatch '.*hdfs.*'})
    $hosts_content=$(Write-Output $hosts_content | Where-Object {$_ -notmatch '.*yarn.*'})
    Set-Content $HOST_FILE -Value $hosts_content

    Add-Content -Value "$(minikube ip) accumulo.datawave.org" -Path $HOST_FILE
    Add-Content -Value "$(minikube ip) web.datawave.org" -Path $HOST_FILE
    Add-Content -Value "$(minikube ip) dictionary.datawave.org" -Path $HOST_FILE
}

function helm_package {
    Write-Output "Clearing out old tgz files..."
    foreach($zip_item in (Get-ChildItem -Recurse -Include *.tgz)) {
        Remove-Item $zip_item.FullName
    }

    Set-Location "$BASEDIR/common-service-library"
    helm package .

    Set-Location "$BASEDIR"

    foreach($folder in ("audit", "authorization", "cache", "configuration", "dictionary", "datawave-monolith", 
                        "hadoop", "ingest", "mysql", "rabbitmq", "zookeeper")) {
        Set-Location "$BASEDIR/$folder"
        helm dependency update
        helm package .
    }

    Set-Location "$BASEDIR/datawave-monolith-umbrella"
    helm dependency update
    helm package .

    Set-Location "$BASEDIR/datawave-stack"
    helm dependency update
    helm package .

    Set-Location $BASEDIR
}

function helm_install {
    $PACKAGE = Resolve-Path "$DATAWAVE_STACK/datawave-system-*.tgz" | Select-Object -ExpandProperty Path
    helm upgrade --install dwv $PACKAGE -f $VALUES_FILE $EXTRA_HELM_ARGS
}

Write-Output "Package Helm Charts"
helm_package
Write-Output "Purge and restart Minikube"
start_minikube
Write-Output "Initialize Hosts file"
initialize_hosts_file
Write-Output "Running Helm Install"
helm_install
Write-Output "Deployment to MinuKube Complete!"