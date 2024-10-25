param (
    [bool]$USE_EXISTING_ZOOKEEPER = $false,
    [bool]$USE_EXISTING_HADOOP = $false,
    [bool]$INIT_LOCAL_HADOOP = $false
)

$USING_MINIKUBE = $false
$BASEDIR = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath ".")).Path
$DATAWAVE_STACK = Join-Path -Path $BASEDIR -ChildPath "datawave-stack"
$HELM_CHART = "oci://ghcr.io/nationalsecurityagency/datawave-helm-charts/charts/datawave-system"
$HELM_CHART_VERSION = "1.0.0"
$NAMESPACE = "default"

function Ready-HelmCharts {
    while ($true) {
        $chart_mode = Read-Host "Enter chart mode (local,remote) [remote]"
        $chart_mode = if ($chart_mode) { $chart_mode } else { "remote" }

        if ($chart_mode -in @("local", "remote") -or [string]::IsNullOrEmpty($chart_mode)) {
            Write-Host "Using Chart Mode: $chart_mode"
            break
        } else {
            Write-Host "Invalid input. Please use 'local', 'remote', or leave blank to default."
        }
    }

    if ($chart_mode -eq "remote") {
        $HELM_CHART = "oci://ghcr.io/nationalsecurityagency/datawave-helm-charts/charts/datawave-system"
        $HELM_CHART_VERSION = "1.0.0"
    } else {
        Write-Host "Chart mode is local. Proceed to package all dependencies for the umbrella chart and assemble them"
        Package-HelmDependencies $DATAWAVE_STACK
        $HELM_CHART = Join-Path -Path $DATAWAVE_STACK -ChildPath "datawave-system*.tgz"
    }
}

function Package-HelmDependencies([string]$base_dir) {
    $chart_file = Join-Path -Path $base_dir -ChildPath "Chart.yaml"
    $dependencies = yq eval ".dependencies[]" $chart_file

    if ($null -eq $dependencies) {
        return
    }

    $dependencies | ForEach-Object {
        $dep = $_

        $dep_path = yq eval ".dependencies[] | select(.name == `"$dep`") | .path" $chart_file
        if ($null -ne $dep_path -and -not [string]::IsNullOrEmpty($dep_path)) {
            Write-Host "Packaging dependency: $dep"
            Package-HelmDependencies (Join-Path -Path $base_dir -ChildPath $dep_path)

            helm package (Join-Path -Path $base_dir -ChildPath $dep_path)
            mkdir -p (Join-Path -Path $base_dir -ChildPath "charts")
            Move-Item -Path "*.tgz" -Destination (Join-Path -Path $base_dir -ChildPath "charts/")
        } else {
            Write-Host "Dependency $dep in $chart_file has no local path specified."
        }
    }
}

function Update-CoreDns {
    $corefile = switch -regex (,$USE_EXISTING_ZOOKEEPER,,$USE_EXISTING_HADOOP) {
        "FalseFalseFalse" { "coredns.corefile-default.template" }
        "TrueTrueFalse" { "coredns.corefile-both.template" }
        "TrueFalseFalse" { "coredns.corefile-zookeeper.template" }
        "FalseTrueFalse" { "coredns.corefile-hadoop.template" }
    }

    &"${BASEDIR}\updateCorefile.sh" $corefile
}

function Check-K8sCluster {
    Write-Host "Checking if Kubernetes is running..."
    if (!(kubectl cluster-info *>&1)) {
        Write-Host "No Kubernetes cluster found. Deploying Minikube..."
        Start-Minikube
    } else {
        $user_input = Read-Host "Active Kubeconfig found. Would you like to use this cluster (no means minikube should be deployed)? [yes]"
        if ($user_input -eq "no") {
            Write-Host "Starting Minikube cluster..."
            Start-Minikube
        } else {
            Write-Host "Minikube cluster not started. Using active Kubeconfig"
        }
    }
}

function Set-Namespace {
    $namespace = Read-Host "Set Namespace [default]"
    $NAMESPACE = if ($namespace) { $namespace } else { "default" }

    if (!(kubectl get namespace $NAMESPACE *>&1)) {
        Write-Host "Namespace '$NAMESPACE' does not exist. Creating namespace."
        kubectl create namespace $NAMESPACE
    } else {
        Write-Host "Namespace '$NAMESPACE' exists."
    }
}

function Start-Minikube {
    $USING_MINIKUBE = $true

    $user_input = Read-Host "Do you want to run Minikube purge first? (yes/no) [no]"
    if ($user_input -eq "yes") {
        Write-Host "Purging the minikube cluster"
        minikube delete --all --purge
    } else {
        Write-Host "Minikube cluster not purged."
    }

    minikube start --nodes 3 --cpus 4 --memory 15960 --disk-size 20480
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Minikube started successfully."
    } else {
        Write-Host "Failed to start Minikube. Exiting."
        exit 1
    }

    Write-Host "Configure minikube for Datawave Helm charts"
    minikube addons enable ingress
    minikube kubectl -- delete -A ValidatingWebhookConfiguration ingress-nginx-admission
    minikube kubectl -- patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--enable-ssl-passthrough"}]'
    Write-Host "Minikube configured successfully"
}

function Preload-DockerImage([string]$image) {
    Write-Host "Pulling $image"
    docker pull $image
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$image pulled successfully"
    } else {
        Write-Host "Failed to pull required image. Exiting."
        exit 1
    }

    minikube image load $image
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$image loaded into minikube successfully."
    } else {
        Write-Host "Failed to load $image into minikube. Exiting."
        exit 1
    }
}

function Configure-RepositoryCredentials {
    if (-Not (Test-Path "${BASEDIR}\ghcr-image-pull-secret.yaml")) {
        $username = Read-Host "Github Username"
        $pat = Read-Host "Github Access Token" -AsSecureString
        &"${BASEDIR}\create-image-pull-secrets.sh" $username (ConvertFrom-SecureString $pat -AsPlainText)
    }
    kubectl -n $NAMESPACE apply -f "${BASEDIR}\ghcr-image-pull-secret.yaml"
}

function Create-Secrets {
    $SECRET_NAME = "certificates-secret"

    if (!(kubectl -n $NAMESPACE get secret $SECRET_NAME *>&1)) {
        Write-Host "Secret '$SECRET_NAME' does not exist. Creating secret."
        kubectl -n $NAMESPACE create secret generic $SECRET_NAME --from-file=keystore.p12=(Join-Path -Path "${DATAWAVE_STACK}" -ChildPath "certificates\keystore.p12") --from-file=truststore.jks=(Join-Path -Path "${DATAWAVE_STACK}" -ChildPath "certificates\truststore.jks")
    } else {
        Write-Host "Secret '$SECRET_NAME' already exists."
    }
}

function Ghcr-Login {
    Write-Host "Logging in to GHCR for docker and helm"
    if (Test-Path "${BASEDIR}\ghcr-image-pull-secret.yaml") {
        $FILE_PATH = "${BASEDIR}\ghcr-image-pull-secret.yaml"

        $ENCODED_JSON = Select-String '.dockerconfigjson:' -Path $FILE_PATH | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }
        $DECODED_JSON = [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($ENCODED_JSON))

        $ENCODED_AUTH = ($DECODED_JSON | ConvertFrom-Json).auths.'ghcr.io'.auth
        $AUTH = [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($ENCODED_AUTH))

        $USERNAME, $PASSWORD = $AUTH -split ':'

        echo $PASSWORD | docker login ghcr.io --username $USERNAME --password-stdin
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Docker login successful."
        } else {
            Write-Host "Failed to login to docker. Check credentials. Exiting."
            exit 1
        }

        echo $PASSWORD | helm registry login ghcr.io --username $USERNAME --password-stdin
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Helm login successful."
        } else {
            Write-Host "Failed to login to helm. Check credentials. Exiting."
            exit 1
        }
    }
}

function Update-HostsFileForHadoop {
    $ip = minikube ip
    "$ip namenode.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
    "$ip resourcemanager.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
    "$ip historyserver.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
}

function Configure-EtcHosts {
    $ip = minikube ip
    [System.IO.File]::WriteAllLines("C:\Windows\System32\drivers\etc\hosts", `
        (Get-Content "C:\Windows\System32\drivers\etc\hosts" | `
        Where-Object { -not ($_ -match 'datawave\.org' -or $_ -match 'zookeeper' -or $_ -match 'hdfs' -or $_ -match 'yarn') }))

    "$ip accumulo.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
    "$ip web.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
    "$ip dictionary.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"

    if ($USE_EXISTING_ZOOKEEPER) {
        $EXTRA_HELM_ARGS += "--set charts.zookeeper.enabled=false"
        "$ip zookeeper" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
    }

    if ($USE_EXISTING_HADOOP) {
        $EXTRA_HELM_ARGS += "--set charts.hadoop.enabled=false"
        "$ip hdfs-nn" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
        "$ip hdfs-dn" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
        "$ip yarn-rn" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
        "$ip yarn-nm" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
        "$ip namenode.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
        "$ip resourcemanager.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
        "$ip historyserver.datawave.org" | Out-File -Append -FilePath "C:\Windows\System32\drivers\etc\hosts"
    } else {
        Update-HostsFileForHadoop
    }
}

function Helm-Install {
    $values_file = Read-Host "Enter path values file to use [$DATAWAVE_STACK\values.yaml]"
    Write-Host "Starting Helm Deployment"

    $values_file = if ($values_file) { $values_file } else { Join-Path -Path $DATAWAVE_STACK -ChildPath "values.yaml" }

    & helm install dwv $HELM_CHART -f $values_file --namespace $NAMESPACE $EXTRA_HELM_ARGS --wait
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Helm install successful."
    } else {
        Write-Host "Helm Install failed. Please investigate."
        exit 1
    }
}

# Main execution
Write-Host "Starting driver script for DataWave Cluster operations..."

Ready-HelmCharts
Check-K8sCluster
Set-Namespace

if (-not $USING_MINIKUBE) {
    Write-Host "Skipping image preload since minikube cluster was not started with this deployment."
} else {
    Preload-DockerImage "rabbitmq:3.11.4-alpine"
    Preload-DockerImage "mysql:8.0.32"
    Preload-DockerImage "busybox:1.28"

    Configure-EtcHosts
    Update-CoreDns
}

Configure-RepositoryCredentials
Ghcr-Login
Create-Secrets
Helm-Install

Write-Host "Driver Script completed successfully. See 'kubectl get po' for information"
