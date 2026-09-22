#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-datawave}"
K8S_CLUSTER_NAME="${K8S_CLUSTER_NAME:-mysql-cluster}"
MYSQL_SECRET_NAME="${MYSQL_SECRET_NAME:-mysql-secret}"
SEED_POD="${SEED_POD:-${K8S_CLUSTER_NAME}-0}"
ADMINAPI_CLUSTER_NAME="${ADMINAPI_CLUSTER_NAME:-${K8S_CLUSTER_NAME//-/_}}"
ASSUME_YES=false

usage() {
    cat <<EOF
Recover an Oracle MySQL InnoDB Cluster after a complete Minikube outage.

Usage: $0 [--yes]

Environment overrides:
  NAMESPACE                 Kubernetes namespace (default: datawave)
  K8S_CLUSTER_NAME          InnoDBCluster resource name (default: mysql-cluster)
  MYSQL_SECRET_NAME         Root credential Secret (default: mysql-secret)
  SEED_POD                  MySQL pod used for recovery (default: mysql-cluster-0)
  ADMINAPI_CLUSTER_NAME     MySQL AdminAPI name (default: mysql_cluster)

Options:
  --yes                     Recover without an interactive confirmation
  -h, --help                Show this help
EOF
}

while (($#)); do
    case "$1" in
        --yes)
            ASSUME_YES=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

for command in kubectl base64; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

cluster_status="$(
    kubectl -n "$NAMESPACE" get innodbcluster "$K8S_CLUSTER_NAME" \
        -o jsonpath='{.status.cluster.status}'
)"
online_instances="$(
    kubectl -n "$NAMESPACE" get innodbcluster "$K8S_CLUSTER_NAME" \
        -o jsonpath='{.status.cluster.onlineInstances}'
)"
expected_instances="$(
    kubectl -n "$NAMESPACE" get innodbcluster "$K8S_CLUSTER_NAME" \
        -o jsonpath='{.spec.instances}'
)"

if [[ "$cluster_status" == "ONLINE" ]]; then
    echo "InnoDB Cluster $NAMESPACE/$K8S_CLUSTER_NAME is already ONLINE ($online_instances/$expected_instances members)."
    exit 0
fi

if [[ -n "$online_instances" && "$online_instances" != "0" ]]; then
    echo "Cluster has $online_instances/$expected_instances ONLINE members; refusing complete-outage recovery." >&2
    exit 1
fi

mapfile -t mysql_pods < <(
    kubectl -n "$NAMESPACE" get pods \
        -l "mysql.oracle.com/cluster=$K8S_CLUSTER_NAME,component=mysqld" \
        -o name | sort
)

if ((${#mysql_pods[@]} == 0)); then
    echo "No MySQL pods found for $NAMESPACE/$K8S_CLUSTER_NAME." >&2
    exit 1
fi

if ((${#mysql_pods[@]} != expected_instances)); then
    echo "Found ${#mysql_pods[@]}/$expected_instances expected MySQL pods; refusing recovery." >&2
    exit 1
fi

for pod in "${mysql_pods[@]}"; do
    ready="$(
        kubectl -n "$NAMESPACE" get "$pod" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="mysql")].ready}'
    )"
    if [[ "$ready" != "true" ]]; then
        echo "MySQL container is not ready in $pod; refusing recovery." >&2
        exit 1
    fi
done

mysql_user="$(
    kubectl -n "$NAMESPACE" get secret "$MYSQL_SECRET_NAME" \
        -o jsonpath='{.data.rootUser}' | base64 --decode
)"
mysql_password="$(
    kubectl -n "$NAMESPACE" get secret "$MYSQL_SECRET_NAME" \
        -o jsonpath='{.data.rootPassword}' | base64 --decode
)"
trap 'unset mysql_password mysql_user' EXIT

run_recovery() {
    local options="$1"
    printf '%s\n' "$mysql_password" |
        kubectl -n "$NAMESPACE" exec -i "$SEED_POD" -c mysql -- \
            mysqlsh --js --passwords-from-stdin \
            --uri "${mysql_user}@localhost:3306" \
            --ssl-mode=REQUIRED \
            -e "dba.rebootClusterFromCompleteOutage(\"${ADMINAPI_CLUSTER_NAME}\"${options})"
}

echo "Cluster status is ${cluster_status:-unknown}; validating complete-outage recovery."
run_recovery ', {dryRun:true}'

if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "Recover MySQL InnoDB Cluster $NAMESPACE/$K8S_CLUSTER_NAME? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Recovery cancelled."
            exit 0
            ;;
    esac
fi

run_recovery ''

echo "Waiting for all MySQL members to become ONLINE."
for _ in {1..60}; do
    online="$(
        kubectl -n "$NAMESPACE" get innodbcluster "$K8S_CLUSTER_NAME" \
            -o jsonpath='{.status.cluster.onlineInstances}'
    )"
    expected="$(
        kubectl -n "$NAMESPACE" get innodbcluster "$K8S_CLUSTER_NAME" \
            -o jsonpath='{.spec.instances}'
    )"
    status="$(
        kubectl -n "$NAMESPACE" get innodbcluster "$K8S_CLUSTER_NAME" \
            -o jsonpath='{.status.cluster.status}'
    )"
    if [[ "$status" == "ONLINE" && "$online" == "$expected" ]]; then
        echo "InnoDB Cluster is ONLINE ($online/$expected members)."
        break
    fi
    sleep 2
done

if [[ "${status:-}" != "ONLINE" || "${online:-}" != "${expected:-}" ]]; then
    echo "Timed out waiting for all MySQL members to become ONLINE." >&2
    exit 1
fi

mapfile -t router_pods < <(
    kubectl -n "$NAMESPACE" get pods \
        -l "mysql.oracle.com/cluster=$K8S_CLUSTER_NAME,component=mysqlrouter" \
        -o name
)

for pod in "${router_pods[@]}"; do
    ready="$(
        kubectl -n "$NAMESPACE" get "$pod" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="router")].ready}'
    )"
    if [[ "$ready" != "true" ]]; then
        echo "Recreating unhealthy stateless Router pod $pod."
        kubectl -n "$NAMESPACE" delete "$pod"
    fi
done

if ((${#router_pods[@]} > 0)); then
    kubectl -n "$NAMESPACE" wait \
        --for=condition=Ready pod \
        -l "mysql.oracle.com/cluster=$K8S_CLUSTER_NAME,component=mysqlrouter" \
        --timeout=120s
fi

kubectl -n "$NAMESPACE" get innodbcluster "$K8S_CLUSTER_NAME" -o wide
