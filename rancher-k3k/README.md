# rancher-k3k

Deploy Rancher management server using [k3k](https://github.com/rancher/k3k) (Kubernetes in Kubernetes) on Harvester.

> **Warning**: This addon is experimental and not for production use.

## Overview

k3k is Rancher's alternative to vCluster for running virtual Kubernetes clusters. Unlike vCluster, k3k:

- Is developed by Rancher (native integration)
- Offers "shared" and "virtual" modes
- Uses K3s as the embedded distribution
- Does **not** support embedded manifest deployment (must deploy Rancher manually after cluster creation)

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Harvester Host Cluster                             │
│  ┌───────────────────────────────────────────────┐  │
│  │  k3k-system namespace                         │  │
│  │  └── k3k-controller (watches Cluster CRs)     │  │
│  └───────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────┐  │
│  │  k3k-rancher namespace                        │  │
│  │  ├── rancher-server-0 (K3s control plane)     │  │
│  │  └── Rancher + cert-manager (inside vcluster) │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

- Harvester cluster with storage class configured
- kubectl access to the Harvester cluster
- k3kcli (optional, for kubeconfig retrieval)

## Installation

### Step 1: Deploy k3k Controller

```bash
# Apply the k3k controller addon
kubectl apply -f k3k-controller.yaml

# Enable the addon
kubectl patch addon k3k-controller -n k3k-system --type=merge -p '{"spec":{"enabled":true}}'

# Wait for controller to be ready
kubectl wait --for=condition=available deployment/k3k -n k3k-system --timeout=120s
```

### Step 2: Create the Virtual Cluster

```bash
# Apply the k3k cluster CR
kubectl apply -f rancher-cluster.yaml

# Wait for the cluster to be ready (server pod running)
kubectl wait --for=condition=ready pod -l app=rancher-server -n k3k-rancher --timeout=300s
```

### Step 3: Get Kubeconfig for the Virtual Cluster

**Option A: Using k3kcli**
```bash
# Install k3kcli from https://github.com/rancher/k3k/releases
k3kcli kubeconfig get -n k3k-rancher rancher > rancher-kubeconfig.yaml
```

**Option B: Manual extraction**
```bash
# Get the kubeconfig secret
kubectl get secret rancher-kubeconfig -n k3k-rancher -o jsonpath='{.data.value}' | base64 -d > rancher-kubeconfig.yaml
```

### Step 4: Deploy Rancher into the Virtual Cluster

```bash
# Edit post-install/02-rancher.yaml first:
# - Set hostname to your Rancher URL
# - Set bootstrapPassword

# Apply manifests to the virtual cluster
export KUBECONFIG=rancher-kubeconfig.yaml
kubectl apply -f post-install/01-cert-manager.yaml
kubectl apply -f post-install/02-rancher.yaml

# Wait for Rancher to be ready
kubectl wait --for=condition=available deployment/rancher -n cattle-system --timeout=600s
```

## Configuration

### k3k Cluster Options

Edit `rancher-cluster.yaml` to customize:

| Field | Description | Default |
|-------|-------------|---------|
| `spec.mode` | "shared" or "virtual" | shared |
| `spec.servers` | Number of control plane nodes | 1 |
| `spec.agents` | Number of worker nodes (virtual mode only) | 0 |
| `spec.persistence.type` | Storage type: dynamic, static, ephemeral | dynamic |
| `spec.expose.ingress.enabled` | Expose API via ingress | true |

### Rancher Options

Edit `post-install/02-rancher.yaml`:

| Field | Description | Required |
|-------|-------------|----------|
| `hostname` | Rancher URL (must resolve to Harvester VIP) | Yes |
| `bootstrapPassword` | Initial admin password | Yes |
| `version` | Rancher version | No (defaults to v2.13.0) |

## Comparison: k3k vs vCluster

| Feature | k3k | vCluster |
|---------|-----|----------|
| Developer | Rancher | Loft Labs |
| Maturity | Development | Production |
| Embedded manifests | No | Yes (manifestsTemplate) |
| Cluster modes | Shared + Virtual | Virtual only |
| Helm schema | Flexible | Strict (0.20+) |
| Rancher integration | Native | Extension |

## Cleanup

```bash
# Delete the virtual cluster
kubectl delete -f rancher-cluster.yaml

# Disable and delete the controller addon
kubectl patch addon k3k-controller -n k3k-system --type=merge -p '{"spec":{"enabled":false}}'
kubectl delete -f k3k-controller.yaml
```

## Troubleshooting

### Cluster not starting
```bash
# Check controller logs
kubectl logs -n k3k-system deployment/k3k

# Check cluster status
kubectl describe cluster rancher -n k3k-rancher
```

### Cannot access virtual cluster API
```bash
# Check if server pod is running
kubectl get pods -n k3k-rancher

# Check ingress configuration
kubectl get ingress -n k3k-rancher
```

## References

- [k3k GitHub](https://github.com/rancher/k3k)
- [k3k Documentation](https://rancher.github.io/k3k/)
- [Rancher Installation Guide](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster)
