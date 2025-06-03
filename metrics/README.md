# DWV-Metrics Helm Chart

This Helm chart deploys Prometheus for metrics monitoring in a Kubernetes cluster. It provides a configurable way to set up Prometheus with various scraping targets and storage options.

## Overview

The DWV-Metrics chart includes:

- Prometheus server deployment
- ConfigMap with customizable scrape configurations
- Service to expose Prometheus
- Optional persistent storage via PVC
- RBAC resources for Kubernetes monitoring
- ServiceAccount for Prometheus

## Installation

### Prerequisites

- Kubernetes 1.16+
- Helm 3.0+

### Installing the Chart

```bash
# Add the repository (if applicable)
helm repo add datawave-helm-charts https://your-repo-url/charts/

# Update repositories
helm repo update

# Install the chart with the release name "metrics"
helm install metrics datawave-helm-charts/dwv-metrics -n monitoring --create-namespace

# Alternatively, install from local chart
helm install metrics ./dwv-metrics -n monitoring --create-namespace
```

### Uninstalling the Chart

```bash
helm uninstall metrics -n monitoring
```

## Configuration

The following table lists the configurable parameters of the DWV-Metrics chart and their default values.

| Parameter | Description | Default |
| --------- | ----------- | ------- |
| `namespace` | Namespace to deploy Prometheus | `default` |
| `createNamespace` | Whether to create the namespace | `false` |
| `rbac.create` | Whether to create RBAC resources | `true` |
| `serviceAccount.create` | Whether to create a ServiceAccount | `true` |
| `serviceAccount.name` | Name of the ServiceAccount | `""` (auto-generated) |
| `prometheus.name` | Name of the Prometheus instance | `prometheus` |
| `prometheus.image.repository` | Prometheus image repository | `prom/prometheus` |
| `prometheus.image.tag` | Prometheus image tag | `latest` |
| `prometheus.image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `prometheus.replicaCount` | Number of Prometheus replicas | `1` |
| `prometheus.service.type` | Service type | `ClusterIP` |
| `prometheus.service.port` | Service port | `9090` |
| `prometheus.service.nodePort` | NodePort when service type is NodePort | `null` |
| `prometheus.resources.requests.memory` | Memory request | `256Mi` |
| `prometheus.resources.requests.cpu` | CPU request | `100m` |
| `prometheus.resources.limits.memory` | Memory limit | `512Mi` |
| `prometheus.resources.limits.cpu` | CPU limit | `200m` |
| `prometheus.storage.size` | Storage size | `10Gi` |
| `prometheus.storage.persistentVolume.enabled` | Enable persistent storage | `false` |
| `prometheus.storage.persistentVolume.storageClass` | Storage class | `""` |
| `prometheus.storage.persistentVolume.accessModes` | Access modes | `["ReadWriteOnce"]` |
| `prometheus.scrape.interval` | Global scrape interval | `15s` |
| `prometheus.scrape.timeout` | Global scrape timeout | `10s` |
| `prometheus.scrape.kubernetes_nodes` | Whether to scrape Kubernetes nodes | `true` |
| `prometheus.scrape.targets` | Additional scrape targets | See below |

## Example Configurations

### Enabling Persistent Storage

```yaml
prometheus:
  storage:
    persistentVolume:
      enabled: true
      storageClass: "standard"  # Specify your cluster's storage class
```

### Configuring Resources

```yaml
prometheus:
  resources:
    requests:
      memory: 512Mi
      cpu: 200m
    limits:
      memory: 1Gi
      cpu: 500m
```

### Adding Custom Scrape Targets

```yaml
prometheus:
  scrape:
    targets:
      - name: custom-application
        metrics_path: "/metrics"
        services:
          - "my-app.default.svc.cluster.local:8080"
      - name: database-metrics
        interval: 30s
        services:
          - "database-service:9187"
```

### Using NodePort Service

```yaml
prometheus:
  service:
    type: NodePort
    nodePort: 30090
```

## Accessing Prometheus

After installing the chart, you can access Prometheus using one of the following methods:

### Port Forwarding

```bash
kubectl port-forward -n <namespace> svc/<release-name>-prometheus 9090:9090
```

Then access Prometheus in your browser at http://localhost:9090/

### ClusterIP Service

If you're inside the cluster network or using a VPN, you can access Prometheus directly at:
```
http://<release-name>-prometheus.<namespace>.svc.cluster.local:9090
```

### NodePort or LoadBalancer Service

If you configured the service as NodePort or LoadBalancer:
```bash
# For NodePort
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
export NODE_PORT=$(kubectl get svc -n <namespace> <release-name>-prometheus -o jsonpath='{.spec.ports[0].nodePort}')
echo http://$NODE_IP:$NODE_PORT

# For LoadBalancer
export SERVICE_IP=$(kubectl get svc -n <namespace> <release-name>-prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo http://$SERVICE_IP:9090
```

