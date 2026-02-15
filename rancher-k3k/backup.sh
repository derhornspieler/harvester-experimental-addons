#!/usr/bin/env bash
set -euo pipefail

# Backup Rancher running inside k3k
#
# Performs:
#   1. Exports k3k vcluster kubeconfig
#   2. Backs up Rancher deployment manifests (HelmCharts, secrets)
#   3. Backs up k3k cluster CR
#   4. Backs up host ingress resources
#   5. Copies deploy.sh configuration for replay
#   6. Saves k3k kubeconfig
#   7. Backs up cert-manager HelmChart
#   8. Triggers on-demand rancher-backup operator backup (if installed)
#
# Usage:
#   ./backup.sh                    # Backup to ./backups/<timestamp>/
#   ./backup.sh /path/to/dir       # Backup to specified directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3K_NS="rancher-k3k"
K3K_CLUSTER="rancher"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Cross-platform sed -i
sedi() {
    if sed --version &>/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# --- Preflight ---
if ! kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    err "k3k cluster '$K3K_CLUSTER' not found in namespace '$K3K_NS'"
    exit 1
fi

STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$STATUS" != "Ready" ]]; then
    err "k3k cluster is not Ready (current status: $STATUS)"
    exit 1
fi

# --- Backup directory ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${1:-${SCRIPT_DIR}/backups/${TIMESTAMP}}"
mkdir -p "$BACKUP_DIR"

log "Backing up to: $BACKUP_DIR"

# --- Extract k3k kubeconfig ---
KUBECONFIG_FILE=$(mktemp)
trap 'rm -f "$KUBECONFIG_FILE"' EXIT

kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
    sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
fi

K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"

if ! $K3K_CMD get nodes &>/dev/null; then
    err "Cannot connect to k3k cluster"
    exit 1
fi

# =============================================================================
# Step 1/8: Backup k3k cluster CR
# =============================================================================
log "Step 1/8: Backing up k3k cluster CR..."
kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o yaml > "$BACKUP_DIR/k3k-cluster.yaml"
log "  Saved k3k-cluster.yaml"

# =============================================================================
# Step 2/8: Backup HelmChart CRs inside k3k
# =============================================================================
log "Step 2/8: Backing up HelmChart CRs..."
$K3K_CMD get helmcharts -A -o yaml > "$BACKUP_DIR/helmcharts.yaml"
log "  Saved helmcharts.yaml"

# =============================================================================
# Step 3/8: Backup Rancher secrets (cattle-system)
# =============================================================================
log "Step 3/8: Backing up Rancher secrets..."
$K3K_CMD get secrets -n cattle-system -o yaml > "$BACKUP_DIR/cattle-system-secrets.yaml" 2>/dev/null || \
    warn "  Could not export cattle-system secrets"
log "  Saved cattle-system-secrets.yaml"

# =============================================================================
# Step 4/8: Backup host ingress resources
# =============================================================================
log "Step 4/8: Backing up host ingress resources..."
kubectl get ingress k3k-rancher-ingress -n "$K3K_NS" -o yaml > "$BACKUP_DIR/host-ingress.yaml" 2>/dev/null || \
    warn "  Host ingress not found"
kubectl get svc k3k-rancher-traefik -n "$K3K_NS" -o yaml > "$BACKUP_DIR/host-service.yaml" 2>/dev/null || \
    warn "  Host service not found"
kubectl get secret tls-rancher-ingress -n "$K3K_NS" -o yaml > "$BACKUP_DIR/host-tls-secret.yaml" 2>/dev/null || \
    warn "  Host TLS secret not found"
log "  Saved host ingress resources"

# =============================================================================
# Step 5/8: Backup deploy script files
# =============================================================================
log "Step 5/8: Backing up deploy configuration..."
cp "$SCRIPT_DIR/post-install/"*.yaml "$BACKUP_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/rancher-cluster.yaml" "$BACKUP_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/host-ingress.yaml" "$BACKUP_DIR/" 2>/dev/null || true
log "  Saved deployment manifests"

# =============================================================================
# Step 6/8: Save k3k kubeconfig
# =============================================================================
log "Step 6/8: Saving k3k kubeconfig..."
cp "$KUBECONFIG_FILE" "$BACKUP_DIR/k3k-kubeconfig.yaml"
log "  Saved k3k-kubeconfig.yaml"

# =============================================================================
# Step 7/8: Backup cert-manager resources
# =============================================================================
log "Step 7/8: Backing up cert-manager resources..."
$K3K_CMD get clusterissuers -o yaml > "$BACKUP_DIR/clusterissuers.yaml" 2>/dev/null || true
$K3K_CMD get certificates -A -o yaml > "$BACKUP_DIR/certificates.yaml" 2>/dev/null || true
log "  Saved cert-manager resources"

# =============================================================================
# Step 8/8: Trigger on-demand operator backup (if installed)
# =============================================================================
if $K3K_CMD get crd backups.resources.cattle.io &>/dev/null; then
    log "Step 8/8: Triggering on-demand operator backup..."
    ONDEMAND_NAME="manual-${TIMESTAMP}"

    # Read S3 config from the scheduled backup (if it exists)
    S3_ENDPOINT=$($K3K_CMD get backups.resources.cattle.io rancher-scheduled-backup \
        -o jsonpath='{.spec.storageLocation.s3.endpoint}' 2>/dev/null || echo "")
    S3_BUCKET=$($K3K_CMD get backups.resources.cattle.io rancher-scheduled-backup \
        -o jsonpath='{.spec.storageLocation.s3.bucketName}' 2>/dev/null || echo "")

    if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
        log "  Using S3 storage: ${S3_ENDPOINT}/${S3_BUCKET}"
        $K3K_CMD apply -f - <<EOF
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: $ONDEMAND_NAME
spec:
  resourceSetName: rancher-resource-set-full
  storageLocation:
    s3:
      credentialSecretName: minio-backup-creds
      credentialSecretNamespace: cattle-resources-system
      bucketName: ${S3_BUCKET}
      endpoint: ${S3_ENDPOINT}
      insecureTLSSkipVerify: true
EOF
    else
        log "  No S3 config found, using operator default storage"
        $K3K_CMD apply -f - <<EOF
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: $ONDEMAND_NAME
spec:
  resourceSetName: rancher-resource-set-full
EOF
    fi

    # Wait for backup to complete (5 min timeout)
    ATTEMPTS=0
    while true; do
        BACKUP_STATUS=$($K3K_CMD get backups.resources.cattle.io "$ONDEMAND_NAME" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$BACKUP_STATUS" == "True" ]]; then
            BACKUP_FILE=$($K3K_CMD get backups.resources.cattle.io "$ONDEMAND_NAME" \
                -o jsonpath='{.status.filename}' 2>/dev/null || echo "unknown")
            log "  Operator backup completed: $BACKUP_FILE"
            echo "$BACKUP_FILE" > "$BACKUP_DIR/operator-backup-filename.txt"
            break
        fi
        if [[ $ATTEMPTS -ge 60 ]]; then
            warn "  Operator backup did not complete within 5 minutes"
            warn "  Check: kubectl get backups.resources.cattle.io $ONDEMAND_NAME -o yaml"
            break
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 5
    done
else
    log "Step 8/8: rancher-backup operator not installed, skipping"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Backup completed!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo " Backup directory: $BACKUP_DIR"
echo ""
echo " Contents:"
ls -la "$BACKUP_DIR/"
echo ""
echo " To restore:"
echo "   $(dirname "$0")/restore.sh --from $BACKUP_DIR"
echo ""
