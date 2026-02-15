#!/usr/bin/env bash
set -euo pipefail

# Restore Rancher running inside k3k from a backup
#
# This script restores a k3k Rancher deployment from a backup created by backup.sh.
# It redeploys the k3k cluster, Rancher, and optionally triggers an operator restore.
#
# Usage:
#   ./restore.sh --from ./backups/20260214-120000/
#   ./restore.sh --from ./backups/20260214-120000/ --operator-restore <backup-filename.tar.gz>
#
# The --operator-restore flag triggers a Restore CR after the rancher-backup operator
# is running, which restores Rancher resources (users, clusters, settings) from an
# operator backup stored on MinIO S3 (172.16.3.249:9000).

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

# =============================================================================
# Argument parsing
# =============================================================================
BACKUP_DIR=""
OPERATOR_RESTORE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --operator-restore)
            OPERATOR_RESTORE_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --from <backup-dir> [--operator-restore <backup-filename.tar.gz>]"
            echo ""
            echo "Options:"
            echo "  --from <dir>                     Path to backup directory (required)"
            echo "  --operator-restore <filename>     Trigger operator restore from NFS backup file"
            echo ""
            echo "The backup directory should be created by backup.sh."
            echo "The operator-restore filename is the .tar.gz file on MinIO S3."
            exit 0
            ;;
        *)
            err "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$BACKUP_DIR" ]]; then
    err "Missing --from argument"
    echo "Usage: $0 --from <backup-dir> [--operator-restore <backup-filename.tar.gz>]"
    exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
    err "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# =============================================================================
# Preflight checks
# =============================================================================
log "Restoring from: $BACKUP_DIR"
echo ""
echo -e "${YELLOW}This will restore Rancher from the backup.${NC}"
echo "  Backup directory: $BACKUP_DIR"
[[ -n "$OPERATOR_RESTORE_FILE" ]] && echo "  Operator restore: $OPERATOR_RESTORE_FILE"
echo ""
echo "  Contents:"
ls "$BACKUP_DIR/"
echo ""
read -rp "Proceed? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted."
    exit 0
fi

# =============================================================================
# Step 1: Verify k3k cluster exists (or wait for deploy.sh to create it)
# =============================================================================
log "Step 1: Checking k3k cluster..."
if ! kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    err "k3k cluster '$K3K_CLUSTER' not found in namespace '$K3K_NS'"
    err ""
    err "The k3k cluster must exist before restoring. Run deploy.sh first:"
    err "  ./deploy.sh"
    err ""
    err "Then re-run this restore script to apply the operator restore."
    exit 1
fi

STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$STATUS" != "Ready" ]]; then
    err "k3k cluster is not Ready (current status: $STATUS)"
    exit 1
fi

# =============================================================================
# Step 2: Extract kubeconfig
# =============================================================================
log "Step 2: Extracting k3k kubeconfig..."
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
log "Connected to k3k cluster"

# =============================================================================
# Step 3: Restore host ingress resources (if missing)
# =============================================================================
log "Step 3: Checking host ingress resources..."

if ! kubectl get ingress k3k-rancher-ingress -n "$K3K_NS" &>/dev/null; then
    if [[ -f "$BACKUP_DIR/host-ingress.yaml" ]]; then
        log "  Restoring host ingress..."
        kubectl apply -f "$BACKUP_DIR/host-ingress.yaml"
    else
        warn "  Host ingress backup not found"
    fi
else
    log "  Host ingress already exists"
fi

if ! kubectl get svc k3k-rancher-traefik -n "$K3K_NS" &>/dev/null; then
    if [[ -f "$BACKUP_DIR/host-service.yaml" ]]; then
        log "  Restoring host service..."
        kubectl apply -f "$BACKUP_DIR/host-service.yaml"
    else
        warn "  Host service backup not found"
    fi
else
    log "  Host service already exists"
fi

if ! kubectl get secret tls-rancher-ingress -n "$K3K_NS" &>/dev/null; then
    if [[ -f "$BACKUP_DIR/host-tls-secret.yaml" ]]; then
        log "  Restoring host TLS secret..."
        kubectl apply -f "$BACKUP_DIR/host-tls-secret.yaml"
    else
        warn "  Host TLS secret backup not found, copying from k3k cluster..."
        TLS_CRT=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || echo "")
        TLS_KEY=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d || echo "")
        if [[ -n "$TLS_CRT" && -n "$TLS_KEY" ]]; then
            kubectl -n "$K3K_NS" create secret tls tls-rancher-ingress \
                --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
                --dry-run=client -o yaml | kubectl apply -f -
            log "  TLS secret copied from k3k cluster"
        else
            warn "  Could not copy TLS secret from k3k cluster"
        fi
    fi
else
    log "  Host TLS secret already exists"
fi

# =============================================================================
# Step 4: Verify Rancher is running
# =============================================================================
log "Step 4: Verifying Rancher is running..."
if $K3K_CMD get deploy/rancher -n cattle-system &>/dev/null; then
    $K3K_CMD wait --for=condition=available deploy/rancher -n cattle-system --timeout=300s
    log "Rancher is running"
else
    err "Rancher deployment not found inside k3k cluster"
    err "Run deploy.sh first to bootstrap Rancher, then re-run this script with --operator-restore"
    exit 1
fi

# =============================================================================
# Step 5: Trigger operator restore (if requested)
# =============================================================================
if [[ -n "$OPERATOR_RESTORE_FILE" ]]; then
    log "Step 5: Triggering operator restore..."

    # Verify rancher-backup operator is installed
    if ! $K3K_CMD get crd restores.resources.cattle.io &>/dev/null; then
        err "rancher-backup operator CRDs not found"
        err "Deploy the rancher-backup operator first (deploy.sh with backup enabled)"
        exit 1
    fi

    if ! $K3K_CMD get deploy/rancher-backup -n cattle-resources-system &>/dev/null; then
        err "rancher-backup operator deployment not found"
        exit 1
    fi
    $K3K_CMD wait --for=condition=available deploy/rancher-backup -n cattle-resources-system --timeout=120s

    # Verify S3 credentials secret exists
    if ! $K3K_CMD get secret minio-backup-creds -n cattle-resources-system &>/dev/null; then
        err "S3 credentials secret 'minio-backup-creds' not found in cattle-resources-system"
        err "Create it first with: kubectl create secret generic minio-backup-creds ..."
        exit 1
    fi

    # Create Restore CR with S3 storage location
    RESTORE_NAME="restore-$(date +%Y%m%d-%H%M%S)"
    log "  Creating Restore CR: $RESTORE_NAME"
    log "  Restoring from: $OPERATOR_RESTORE_FILE"

    $K3K_CMD apply -f - <<EOF
apiVersion: resources.cattle.io/v1
kind: Restore
metadata:
  name: $RESTORE_NAME
spec:
  backupFilename: $OPERATOR_RESTORE_FILE
  storageLocation:
    s3:
      credentialSecretName: minio-backup-creds
      credentialSecretNamespace: cattle-resources-system
      bucketName: rancher-backups
      endpoint: 172.16.3.249:9000
      insecureTLSSkipVerify: true
EOF

    # Wait for restore to complete (10 min timeout)
    log "  Waiting for restore to complete..."
    ATTEMPTS=0
    while true; do
        RESTORE_STATUS=$($K3K_CMD get restores.resources.cattle.io "$RESTORE_NAME" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$RESTORE_STATUS" == "True" ]]; then
            log "  Restore completed successfully!"
            break
        fi

        # Check for errors
        RESTORE_MSG=$($K3K_CMD get restores.resources.cattle.io "$RESTORE_NAME" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        if [[ "$RESTORE_MSG" == *"error"* || "$RESTORE_MSG" == *"Error"* ]]; then
            err "  Restore failed: $RESTORE_MSG"
            exit 1
        fi

        if [[ $ATTEMPTS -ge 120 ]]; then
            err "  Restore did not complete within 10 minutes"
            err "  Check: $K3K_CMD get restores.resources.cattle.io $RESTORE_NAME -o yaml"
            exit 1
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 5
    done

    # Rancher pods will restart automatically after restore
    log "  Waiting for Rancher to restart after restore..."
    sleep 10
    $K3K_CMD wait --for=condition=available deploy/rancher -n cattle-system --timeout=300s
    log "  Rancher is running with restored data"
else
    log "Step 5: No operator restore requested, skipping"
fi

# =============================================================================
# Done
# =============================================================================
HOSTNAME=$($K3K_CMD get ingress -n cattle-system -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "unknown")

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Restore completed!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo " URL: https://${HOSTNAME}"
echo ""
if [[ -n "$OPERATOR_RESTORE_FILE" ]]; then
    echo " Operator restore: $OPERATOR_RESTORE_FILE"
    echo " All Rancher resources (users, clusters, settings) have been restored."
else
    echo " Infrastructure restored. To restore Rancher data, re-run with:"
    echo "   $0 --from $BACKUP_DIR --operator-restore <backup-filename.tar.gz>"
fi
echo ""
