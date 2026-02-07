#!/usr/bin/env bash
set -euo pipefail

# Deploy Rancher on Harvester using k3k
# This script orchestrates the full deployment including TLS cert propagation.
# Re-running this script with updated versions will upgrade existing components.
#
# Supports:
#   - Custom PVC sizing (10Gi to 1000Gi+)
#   - Private Helm chart repos (cert-manager, Rancher)
#   - Private container registries
#   - Private CA certificates
#   - Custom storage classes
#   - In-place upgrades (re-run with new versions)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3K_NS="k3k-rancher"
K3K_CLUSTER="rancher"
KUBECONFIG_FILE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Kubeconfig is preserved for the user after successful deployment.
cleanup_on_error() {
    if [[ $? -ne 0 && -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
        rm -f "$KUBECONFIG_FILE"
    fi
}
trap cleanup_on_error EXIT

# Cross-platform sed -i
sedi() {
    if sed --version &>/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# =============================================================================
# Configuration
# =============================================================================
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN} Rancher on k3k - Deployment Configuration${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

# --- Required ---
read -rp "Rancher hostname (e.g. rancher.example.com): " HOSTNAME
if [[ -z "$HOSTNAME" ]]; then
    err "Hostname is required"
    exit 1
fi

read -rp "Bootstrap password (min 12 chars) [admin1234567]: " BOOTSTRAP_PW
BOOTSTRAP_PW="${BOOTSTRAP_PW:-admin1234567}"
if [[ ${#BOOTSTRAP_PW} -lt 12 ]]; then
    err "Password must be at least 12 characters"
    exit 1
fi

# --- Storage ---
echo ""
echo -e "${CYAN}Storage Configuration:${NC}"
echo "  10Gi   - Base Rancher (minimum)"
echo "  50Gi   - Rancher + basic monitoring"
echo "  200Gi  - Rancher + Prometheus + Grafana + Loki"
echo "  500Gi+ - Full observability stack with retention"
read -rp "PVC size [10Gi]: " PVC_SIZE
PVC_SIZE="${PVC_SIZE:-10Gi}"

read -rp "Storage class [harvester-longhorn]: " STORAGE_CLASS
STORAGE_CLASS="${STORAGE_CLASS:-harvester-longhorn}"

# --- Private repos (optional) ---
echo ""
echo -e "${CYAN}Helm Chart Repositories (press Enter for public defaults):${NC}"
read -rp "cert-manager chart repo [https://charts.jetstack.io]: " CERTMANAGER_REPO
CERTMANAGER_REPO="${CERTMANAGER_REPO:-https://charts.jetstack.io}"

read -rp "cert-manager version [v1.18.5]: " CERTMANAGER_VERSION
CERTMANAGER_VERSION="${CERTMANAGER_VERSION:-v1.18.5}"

read -rp "Rancher chart repo [https://releases.rancher.com/server-charts/latest]: " RANCHER_REPO
RANCHER_REPO="${RANCHER_REPO:-https://releases.rancher.com/server-charts/latest}"

read -rp "Rancher version [v2.13.2]: " RANCHER_VERSION
RANCHER_VERSION="${RANCHER_VERSION:-v2.13.2}"

read -rp "k3k chart repo [https://rancher.github.io/k3k]: " K3K_REPO
K3K_REPO="${K3K_REPO:-https://rancher.github.io/k3k}"

read -rp "k3k version [1.0.1]: " K3K_VERSION
K3K_VERSION="${K3K_VERSION:-1.0.1}"

# --- Private registry (optional) ---
echo ""
echo -e "${CYAN}Private Container Registry (press Enter to skip):${NC}"
echo "  Example: registry.example.com:5000"
read -rp "Private registry URL []: " PRIVATE_REGISTRY
PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-}"

# --- Private CA certificate (optional) ---
echo ""
echo -e "${CYAN}Private CA Certificate (press Enter to skip):${NC}"
echo "  Path to a PEM-encoded CA bundle for internal TLS."
echo "  Used when Helm repos or registries use private certificates."
read -rp "CA certificate path []: " PRIVATE_CA_PATH
PRIVATE_CA_PATH="${PRIVATE_CA_PATH:-}"

# --- TLS source ---
echo ""
echo -e "${CYAN}TLS Certificate Source:${NC}"
echo "  rancher      - Self-signed (default, no external dependency)"
echo "  letsEncrypt  - Let's Encrypt (requires public DNS)"
echo "  secret       - Provide your own TLS cert"
read -rp "TLS source [rancher]: " TLS_SOURCE
TLS_SOURCE="${TLS_SOURCE:-rancher}"

# Validate CA cert path if provided
if [[ -n "$PRIVATE_CA_PATH" && ! -f "$PRIVATE_CA_PATH" ]]; then
    err "CA certificate file not found: $PRIVATE_CA_PATH"
    exit 1
fi

# --- Confirm ---
echo ""
echo -e "${CYAN}Configuration Summary:${NC}"
echo "  Hostname:         $HOSTNAME"
echo "  Password:         ****"
echo "  PVC Size:         $PVC_SIZE"
echo "  Storage Class:    $STORAGE_CLASS"
echo "  cert-manager:     $CERTMANAGER_REPO ($CERTMANAGER_VERSION)"
echo "  Rancher:          $RANCHER_REPO ($RANCHER_VERSION)"
echo "  k3k:              $K3K_REPO ($K3K_VERSION)"
echo "  TLS Source:       $TLS_SOURCE"
[[ -n "$PRIVATE_REGISTRY" ]] && echo "  Registry:         $PRIVATE_REGISTRY"
[[ -n "$PRIVATE_CA_PATH" ]] && echo "  CA Cert:          $PRIVATE_CA_PATH"
echo ""
read -rp "Proceed? (yes/no) [yes]: " CONFIRM
CONFIRM="${CONFIRM:-yes}"
if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted."
    exit 0
fi

# =============================================================================
# Build extra Rancher values
# =============================================================================
EXTRA_RANCHER_VALUES=""

if [[ -n "$PRIVATE_REGISTRY" ]]; then
    EXTRA_RANCHER_VALUES="${EXTRA_RANCHER_VALUES}    systemDefaultRegistry: \"${PRIVATE_REGISTRY}\"\n"
fi

if [[ -n "$PRIVATE_CA_PATH" ]]; then
    EXTRA_RANCHER_VALUES="${EXTRA_RANCHER_VALUES}    privateCA: \"true\"\n"
fi

# Format for YAML indentation (under spec.set:)
if [[ -n "$EXTRA_RANCHER_VALUES" ]]; then
    EXTRA_RANCHER_VALUES=$(echo -e "$EXTRA_RANCHER_VALUES")
else
    EXTRA_RANCHER_VALUES=""
fi

# =============================================================================
# Step 1: Install/upgrade k3k controller via Helm
# =============================================================================
echo ""
log "Step 1/7: Installing k3k controller..."
helm repo add k3k "$K3K_REPO" 2>/dev/null || true
helm repo update k3k
if helm status k3k -n k3k-system &>/dev/null; then
    log "k3k already installed, upgrading to $K3K_VERSION..."
    helm upgrade k3k k3k/k3k -n k3k-system --version "$K3K_VERSION"
else
    helm install k3k k3k/k3k -n k3k-system --create-namespace --version "$K3K_VERSION"
fi
log "Waiting for k3k controller..."
ATTEMPTS=0
while ! kubectl get deploy k3k -n k3k-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 24 ]]; then
        err "Timed out waiting for k3k controller deployment"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
kubectl wait --for=condition=available deploy/k3k -n k3k-system --timeout=120s
log "k3k controller is ready"

# =============================================================================
# Step 2: Create k3k virtual cluster
# =============================================================================
log "Step 2/7: Creating k3k virtual cluster..."
if kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    log "k3k cluster already exists, skipping"
else
    sed -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
        -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
        "$SCRIPT_DIR/rancher-cluster.yaml" | kubectl apply -f -
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

# =============================================================================
# Step 3: Extract kubeconfig
# =============================================================================
log "Step 3/7: Extracting kubeconfig..."
KUBECONFIG_FILE=$(mktemp)

kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

# Replace ClusterIP with NodePort address
CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
    sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
    log "Kubeconfig updated: https://${NODE_IP}:${NODE_PORT}"
else
    warn "Could not determine NodePort. Using ClusterIP (only works from within the cluster)."
fi

K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"
if ! $K3K_CMD get nodes &>/dev/null; then
    err "Cannot connect to k3k cluster"
    exit 1
fi
log "Connected to k3k virtual cluster"

# =============================================================================
# Step 3.5 (optional): Install private CA into k3k cluster
# =============================================================================
if [[ -n "$PRIVATE_CA_PATH" ]]; then
    log "Installing private CA certificate into k3k cluster..."
    $K3K_CMD create namespace cattle-system --dry-run=client -o yaml | $K3K_CMD apply -f -
    $K3K_CMD -n cattle-system create secret generic tls-ca \
        --from-file=cacerts.pem="$PRIVATE_CA_PATH" \
        --dry-run=client -o yaml | $K3K_CMD apply -f -
    log "Private CA installed"
fi

# =============================================================================
# Step 4: Deploy cert-manager
# =============================================================================
log "Step 4/7: Deploying cert-manager..."

sed -e "s|__CERTMANAGER_REPO__|${CERTMANAGER_REPO}|g" \
    -e "s|__CERTMANAGER_VERSION__|${CERTMANAGER_VERSION}|g" \
    "$SCRIPT_DIR/post-install/01-cert-manager.yaml" | $K3K_CMD apply -f -

log "Waiting for cert-manager pods..."
sleep 10
$K3K_CMD wait --for=condition=available deploy/cert-manager -n cert-manager --timeout=300s
$K3K_CMD wait --for=condition=available deploy/cert-manager-webhook -n cert-manager --timeout=300s
log "cert-manager is ready"

# =============================================================================
# Step 5: Deploy Rancher
# =============================================================================
log "Step 5/7: Deploying Rancher..."

RANCHER_MANIFEST=$(mktemp)
sed -e "s|__HOSTNAME__|${HOSTNAME}|g" \
    -e "s|__BOOTSTRAP_PW__|${BOOTSTRAP_PW}|g" \
    -e "s|__RANCHER_REPO__|${RANCHER_REPO}|g" \
    -e "s|__RANCHER_VERSION__|${RANCHER_VERSION}|g" \
    -e "s|__TLS_SOURCE__|${TLS_SOURCE}|g" \
    "$SCRIPT_DIR/post-install/02-rancher.yaml" > "$RANCHER_MANIFEST"

# Inject extra values (private registry, private CA)
if [[ -n "$EXTRA_RANCHER_VALUES" ]]; then
    sedi "s|^__EXTRA_RANCHER_VALUES__$|${EXTRA_RANCHER_VALUES}|" "$RANCHER_MANIFEST"
else
    sedi "/__EXTRA_RANCHER_VALUES__/d" "$RANCHER_MANIFEST"
fi

$K3K_CMD apply -f "$RANCHER_MANIFEST"
rm -f "$RANCHER_MANIFEST"

log "Waiting for Rancher pod to be ready (this may take several minutes)..."
$K3K_CMD wait --for=condition=available deploy/rancher -n cattle-system --timeout=600s
log "Rancher is running"

# =============================================================================
# Step 6: Copy TLS certificate to host cluster
# =============================================================================
log "Step 6/7: Copying Rancher TLS certificate to host cluster..."

ATTEMPTS=0
while ! $K3K_CMD get secret tls-rancher-ingress -n cattle-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 30 ]]; then
        err "Timed out waiting for tls-rancher-ingress secret"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done

TLS_CRT=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

kubectl -n "$K3K_NS" create secret tls tls-rancher-ingress \
    --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
    --dry-run=client -o yaml | kubectl apply -f -

log "TLS certificate copied to host cluster"

# =============================================================================
# Step 7: Create host ingress
# =============================================================================
log "Step 7/7: Creating host cluster ingress..."

sed "s|__HOSTNAME__|${HOSTNAME}|g" "$SCRIPT_DIR/host-ingress.yaml" | kubectl apply -f -

log "Host ingress created"

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Rancher deployed successfully!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e " URL:           https://${HOSTNAME}"
echo -e " Password:      ${BOOTSTRAP_PW}"
echo -e " PVC Size:      ${PVC_SIZE}"
[[ -n "$PRIVATE_REGISTRY" ]] && echo -e " Registry:      ${PRIVATE_REGISTRY}"
echo ""
echo -e " k3k kubeconfig: ${KUBECONFIG_FILE}"
echo ""
echo " To access the k3k cluster:"
echo "   export KUBECONFIG=${KUBECONFIG_FILE}"
echo "   kubectl --insecure-skip-tls-verify get pods -A"
echo ""
echo " To destroy:"
echo "   $(dirname "$0")/destroy.sh"
echo ""
