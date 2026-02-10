# rancher-k3k

Deploy Rancher management server using [k3k](https://github.com/rancher/k3k) (Kubernetes in Kubernetes) on Harvester.

> **Warning**: This addon is experimental and not for production use.

## Quick Start

```bash
./deploy.sh
```

The script prompts for hostname and password, then handles everything:
1. Installs k3k controller
2. Creates the virtual cluster (10Gi storage)
3. Deploys cert-manager + Rancher inside it
4. Copies the TLS certificate to the host cluster
5. Creates the nginx ingress for external access

## Architecture

```
External Traffic
  → rancher.example.com (Harvester VIP)
    → nginx ingress (host cluster, k3k-rancher namespace)
      → k3k-rancher-traefik service → k3k server pod :443
        → Traefik (inside k3k virtual cluster)
          → Rancher (cattle-system namespace)
```

```
┌──────────────────────────────────────────────────────┐
│  Harvester Host Cluster                              │
│  ┌────────────────────────────────────────────────┐  │
│  │  k3k-system namespace                          │  │
│  │  └── k3k-controller                            │  │
│  ├────────────────────────────────────────────────┤  │
│  │  k3k-rancher namespace                         │  │
│  │  ├── k3k-rancher-server-0 (K3s virtual cluster)│  │
│  │  ├── k3k-rancher-traefik (svc → pod :443)      │  │
│  │  ├── k3k-rancher-ingress (nginx, with TLS)     │  │
│  │  └── tls-rancher-ingress (copied from k3k)     │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  Inside k3k virtual cluster:                         │
│    ├── cert-manager (3 pods)                         │
│    ├── Rancher v2.13.0 (fleet disabled)              │
│    └── Traefik ingress controller                    │
└──────────────────────────────────────────────────────┘
```

## TLS Certificate Flow

Harvester's nginx ingress does **not** have `--enable-ssl-passthrough`. The deploy
script works around this by:

1. Rancher generates a self-signed TLS cert (via dynamiclistener) with the correct SAN
2. The script copies this cert from inside the k3k cluster to the host cluster
3. The nginx ingress is configured to use this cert for TLS termination
4. Backend traffic to k3k Traefik uses `backend-protocol: HTTPS`

Without this, the cattle-cluster-agent gets: `x509: certificate is not valid for any names`

## Manual Installation

If you prefer not to use the script:

### Step 1: Install k3k Controller

```bash
helm repo add k3k https://rancher.github.io/k3k
helm install k3k k3k/k3k --namespace k3k-system --create-namespace --devel
kubectl wait --for=condition=available deploy/k3k -n k3k-system --timeout=120s
```

### Step 2: Create Virtual Cluster

```bash
kubectl apply -f rancher-cluster.yaml
# Wait for Ready status
kubectl get clusters.k3k.io rancher -n k3k-rancher -w
```

### Step 3: Extract and Fix Kubeconfig

```bash
# Extract kubeconfig (key is kubeconfig.yaml, not kubeconfig)
kubectl get secret k3k-rancher-kubeconfig -n k3k-rancher \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > k3k-kubeconfig.yaml

# The kubeconfig points to a ClusterIP — replace with NodePort
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc k3k-rancher-service -n k3k-rancher \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')

# Edit k3k-kubeconfig.yaml: change server to https://<NODE_IP>:<NODE_PORT>
```

### Step 4: Deploy cert-manager + Rancher

```bash
export KUBECONFIG=k3k-kubeconfig.yaml
kubectl --insecure-skip-tls-verify apply -f post-install/01-cert-manager.yaml

# Wait for cert-manager, then edit 02-rancher.yaml (set hostname + password)
kubectl --insecure-skip-tls-verify apply -f post-install/02-rancher.yaml
```

### Step 5: Copy TLS Certificate and Create Ingress

```bash
# Wait for Rancher to generate the TLS cert
kubectl --insecure-skip-tls-verify -n cattle-system get secret tls-rancher-ingress

# Extract and copy to host cluster
TLS_CRT=$(kubectl --insecure-skip-tls-verify -n cattle-system \
    get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$(kubectl --insecure-skip-tls-verify -n cattle-system \
    get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

unset KUBECONFIG
kubectl -n k3k-rancher create secret tls tls-rancher-ingress \
    --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY")

# Apply ingress (replace __HOSTNAME__ with your hostname)
sed 's|__HOSTNAME__|rancher.example.com|g' host-ingress.yaml | kubectl apply -f -
```

## File Structure

```
rancher-k3k/
├── deploy.sh                # Automated deployment script
├── destroy.sh               # Cleanup script
├── lib.sh                   # Shared functions (sedi, auth injection)
├── test-private-repos.sh    # Tests for private repo support
├── rancher-cluster.yaml     # k3k Cluster CR (host cluster)
├── host-ingress.yaml        # Service + Ingress template (host cluster)
├── post-install/            # Manifests for inside the k3k cluster
│   ├── 01-cert-manager.yaml
│   └── 02-rancher.yaml
└── README.md
```

## Private Repositories

`deploy.sh` supports air-gapped and private environments where Helm charts and
container images come from internal registries (Harbor, Artifactory, Nexus, etc.).

### Helm Repository Authentication

When prompted, enter the username and password for your private Helm chart repo.
A single credential pair is used for all three repos (cert-manager, Rancher, k3k).
The password is read with hidden input.

The script propagates auth in two ways:
- **Host cluster**: `helm repo add` receives `--username`/`--password` flags
- **k3k cluster**: A `kubernetes.io/basic-auth` Secret (`helm-repo-auth`) is
  created in `kube-system`. The HelmChart CRs reference it via `spec.authSecret`.

### Private CA Certificate

If your repos or registries use TLS certificates signed by an internal CA,
provide the path to the PEM-encoded CA bundle when prompted.

The CA is propagated to:
- **Host cluster**: `helm repo add` and `helm install` receive `--ca-file`
- **k3k cluster (Rancher)**: A Secret (`tls-ca`) in `cattle-system` for
  Rancher's `privateCA` setting
- **k3k cluster (HelmChart CRs)**: A ConfigMap (`helm-repo-ca`) in
  `kube-system` referenced via `spec.repoCAConfigMap`

### Private Container Registry

Enter the registry URL (e.g. `registry.example.com:5000`) when prompted.
This sets Rancher's `systemDefaultRegistry` so all images are pulled from
your mirror.

### Testing

Run the included test script to validate template processing:

```bash
# Tier 1: template validation (no cluster required)
./test-private-repos.sh

# Tier 2: local HTTPS server with auth (requires openssl + python3)
./test-private-repos.sh --full
```

## Configuration

### rancher-cluster.yaml

| Field | Description | Default |
|-------|-------------|---------|
| `spec.mode` | "shared" or "virtual" | virtual |
| `spec.servers` | Control plane nodes | 1 |
| `spec.agents` | Worker nodes | 0 |
| `spec.persistence.storageRequestSize` | PVC size (must fit K3s + images) | 10Gi |
| `spec.persistence.storageClassName` | Storage class | harvester-longhorn |

### post-install/02-rancher.yaml

| Field | Description | Required |
|-------|-------------|----------|
| `hostname` | Rancher URL (must resolve to Harvester VIP) | Yes |
| `bootstrapPassword` | Initial admin password | Yes |
| `features` | Feature flags (`fleet=false` for N-S boundary) | No |

## Cleanup

```bash
# Remove host ingress and TLS secret
kubectl delete ingress k3k-rancher-ingress -n k3k-rancher
kubectl delete svc k3k-rancher-traefik -n k3k-rancher
kubectl delete secret tls-rancher-ingress -n k3k-rancher

# Delete the virtual cluster
kubectl delete clusters.k3k.io rancher -n k3k-rancher

# Uninstall k3k controller
helm uninstall k3k -n k3k-system

# Clean up namespaces
kubectl delete ns k3k-rancher k3k-system
```

## Troubleshooting

### Cluster not starting
```bash
kubectl logs -n k3k-system deployment/k3k
kubectl describe clusters.k3k.io rancher -n k3k-rancher
```

### Rancher image pull fails (no space)
The default 10Gi PVC should be sufficient. If not, delete the cluster,
increase `storageRequestSize` in rancher-cluster.yaml, and redeploy.

### x509 certificate error on cluster import
The TLS certificate was not copied from the k3k cluster to the host cluster.
Re-run the TLS copy step (Step 5 in manual installation, or re-run deploy.sh).

### cattle-cluster-agent can't reach Rancher
Verify DNS resolution and connectivity from within the host cluster:
```bash
kubectl run test --image=curlimages/curl --rm -it --restart=Never -- \
    curl -sk https://<hostname>/ping
```
