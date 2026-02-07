#!/usr/bin/env bash
set -euo pipefail

# Deploy Rancher on Harvester using k3k
# This script orchestrates the full deployment including TLS cert propagation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3K_NS="k3k-rancher"
K3K_CLUSTER="rancher"
KUBECONFIG_FILE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

cleanup() {
    if [[ -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
        rm -f "$KUBECONFIG_FILE"
    fi
}
trap cleanup EXIT

# --- Prompt for configuration ---
read -rp "Rancher hostname (e.g. rancher.example.com): " HOSTNAME
read -rp "Bootstrap password [admin]: " BOOTSTRAP_PW
BOOTSTRAP_PW="${BOOTSTRAP_PW:-admin}"

if [[ -z "$HOSTNAME" ]]; then
    err "Hostname is required"
    exit 1
fi

# --- Step 1: Install k3k controller ---
log "Step 1: Installing k3k controller..."
if kubectl get deploy k3k -n k3k-system &>/dev/null; then
    log "k3k controller already installed, skipping"
else
    helm repo add k3k https://rancher.github.io/k3k 2>/dev/null || true
    helm repo update k3k
    helm install k3k k3k/k3k --namespace k3k-system --create-namespace --devel
    log "Waiting for k3k controller..."
    kubectl wait --for=condition=available deploy/k3k -n k3k-system --timeout=120s
fi

# --- Step 2: Create k3k virtual cluster ---
log "Step 2: Creating k3k virtual cluster..."
if kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    log "k3k cluster already exists, skipping"
else
    kubectl apply -f "$SCRIPT_DIR/rancher-cluster.yaml"
fi

log "Waiting for k3k cluster to be ready..."
while true; do
    STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Ready" ]]; then
        break
    fi
    echo -n "."
    sleep 5
done
echo ""
log "k3k cluster is Ready"

# --- Step 3: Extract kubeconfig ---
log "Step 3: Extracting kubeconfig..."
KUBECONFIG_FILE=$(mktemp)

# Get the kubeconfig from the secret
kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

# Replace ClusterIP with NodePort address
CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
    # macOS/BSD sed requires -i '' while GNU sed uses -i alone
    if sed --version &>/dev/null; then
        sed -i "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
    else
        sed -i '' "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
    fi
    log "Kubeconfig updated: https://${NODE_IP}:${NODE_PORT}"
else
    warn "Could not determine NodePort. Using ClusterIP (only works from within the cluster)."
fi

# Test connectivity
K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"
if ! $K3K_CMD get nodes &>/dev/null; then
    err "Cannot connect to k3k cluster"
    exit 1
fi
log "Connected to k3k virtual cluster"

# --- Step 4: Deploy cert-manager ---
log "Step 4: Deploying cert-manager..."
$K3K_CMD apply -f "$SCRIPT_DIR/post-install/01-cert-manager.yaml"

log "Waiting for cert-manager pods..."
sleep 10
$K3K_CMD wait --for=condition=available deploy/cert-manager -n cert-manager --timeout=300s
$K3K_CMD wait --for=condition=available deploy/cert-manager-webhook -n cert-manager --timeout=300s
log "cert-manager is ready"

# --- Step 5: Deploy Rancher ---
log "Step 5: Deploying Rancher..."

# Generate configured Rancher manifest
RANCHER_MANIFEST=$(mktemp)
sed -e "s|hostname: rancher.example.com|hostname: ${HOSTNAME}|" \
    -e "s|bootstrapPassword: admin|bootstrapPassword: ${BOOTSTRAP_PW}|" \
    "$SCRIPT_DIR/post-install/02-rancher.yaml" > "$RANCHER_MANIFEST"

$K3K_CMD apply -f "$RANCHER_MANIFEST"
rm -f "$RANCHER_MANIFEST"

log "Waiting for Rancher pod to be ready (this may take several minutes)..."
$K3K_CMD wait --for=condition=available deploy/rancher -n cattle-system --timeout=600s
log "Rancher is running"

# --- Step 6: Copy TLS certificate to host cluster ---
log "Step 6: Copying Rancher TLS certificate to host cluster..."

# Wait for the TLS secret to be created by Rancher
ATTEMPTS=0
while ! $K3K_CMD get secret tls-rancher-ingress -n cattle-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 30 ]]; then
        err "Timed out waiting for tls-rancher-ingress secret"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done

# Extract cert and key from k3k cluster
TLS_CRT=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

# Create TLS secret on host cluster
kubectl -n "$K3K_NS" create secret tls tls-rancher-ingress \
    --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
    --dry-run=client -o yaml | kubectl apply -f -

log "TLS certificate copied to host cluster"

# --- Step 7: Create host ingress ---
log "Step 7: Creating host cluster ingress..."

sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/host-ingress.yaml" | kubectl apply -f -

log "Host ingress created"

# --- Done ---
echo ""
log "========================================="
log " Rancher deployed successfully!"
log "========================================="
log ""
log " URL:      https://${HOSTNAME}"
log " Password: ${BOOTSTRAP_PW}"
log ""
log " Kubeconfig (k3k): saved to ${KUBECONFIG_FILE}"
log ""
log " To access the k3k cluster:"
log "   export KUBECONFIG=${KUBECONFIG_FILE}"
log "   kubectl --insecure-skip-tls-verify get pods -A"
log ""
