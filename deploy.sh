#!/bin/bash
#
# Rancher Virtual Cluster Deployment Script
# Deploys Rancher management server using vCluster or k3k on Harvester
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_header() {
    echo -e "${BLUE}"
    echo "=============================================="
    echo "  Rancher Virtual Cluster Deployment"
    echo "=============================================="
    echo -e "${NC}"
}

print_menu() {
    echo -e "${YELLOW}Select deployment method:${NC}"
    echo ""
    echo "  1) vCluster Pro  - Loft's virtual cluster (production-ready)"
    echo "                     Single-step deployment with embedded manifests"
    echo ""
    echo "  2) k3k           - Rancher's Kubernetes-in-Kubernetes (development)"
    echo "                     Multi-step deployment, native Rancher integration"
    echo ""
    echo "  3) Exit"
    echo ""
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl is not installed${NC}"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
        echo "Make sure your kubeconfig is configured correctly"
        exit 1
    fi
}

prompt_config() {
    local var_name=$1
    local prompt=$2
    local default=$3

    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " value
        value="${value:-$default}"
    else
        read -p "$prompt: " value
    fi

    eval "$var_name='$value'"
}

deploy_vcluster() {
    echo -e "${GREEN}Deploying Rancher with vCluster Pro...${NC}"
    echo ""

    # Get configuration
    echo -e "${YELLOW}Configuration:${NC}"
    prompt_config HOSTNAME "Enter Rancher hostname (must resolve to Harvester VIP)" "rancher.example.com"
    prompt_config BOOTSTRAP_PASSWORD "Enter initial admin password" "admin"

    echo ""
    echo -e "${YELLOW}Updating rancher-vcluster.yaml with your configuration...${NC}"

    # Create a temporary file with updated values
    VCLUSTER_YAML="$SCRIPT_DIR/rancher-vcluster/rancher-vcluster.yaml"

    # Update hostname and password in the yaml
    sed -i.bak \
        -e "s|hostname: rancher.example.com|hostname: $HOSTNAME|g" \
        -e "s|bootstrapPassword: admin|bootstrapPassword: $BOOTSTRAP_PASSWORD|g" \
        "$VCLUSTER_YAML"

    echo -e "${YELLOW}Applying addon...${NC}"
    kubectl apply -f "$VCLUSTER_YAML"

    echo -e "${YELLOW}Enabling addon...${NC}"
    kubectl patch addon rancher-vcluster -n rancher-vcluster --type=merge -p '{"spec":{"enabled":true}}'

    echo ""
    echo -e "${GREEN}vCluster deployment initiated!${NC}"
    echo ""
    echo "Monitor progress with:"
    echo "  kubectl get addon rancher-vcluster -n rancher-vcluster"
    echo "  kubectl get pods -n rancher-vcluster"
    echo ""
    echo "Once ready, Rancher will be available at: https://$HOSTNAME"
}

deploy_k3k() {
    echo -e "${GREEN}Deploying Rancher with k3k...${NC}"
    echo ""

    # Get configuration
    echo -e "${YELLOW}Configuration:${NC}"
    prompt_config HOSTNAME "Enter Rancher hostname (must resolve to Harvester VIP)" "rancher.example.com"
    prompt_config BOOTSTRAP_PASSWORD "Enter initial admin password" "admin"

    K3K_DIR="$SCRIPT_DIR/rancher-k3k"

    # Step 1: Deploy k3k controller
    echo ""
    echo -e "${YELLOW}Step 1/4: Deploying k3k controller...${NC}"
    kubectl apply -f "$K3K_DIR/k3k-controller.yaml"
    kubectl patch addon k3k-controller -n k3k-system --type=merge -p '{"spec":{"enabled":true}}'

    echo "Waiting for k3k controller to be ready..."
    sleep 5
    kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=k3k -n k3k-system --timeout=120s 2>/dev/null || true

    # Step 2: Create virtual cluster
    echo ""
    echo -e "${YELLOW}Step 2/4: Creating virtual cluster...${NC}"
    kubectl apply -f "$K3K_DIR/rancher-cluster.yaml"

    echo "Waiting for virtual cluster to be ready (this may take a few minutes)..."
    sleep 10
    kubectl wait --for=condition=ready pod -l app=rancher-server -n k3k-rancher --timeout=300s 2>/dev/null || echo "Cluster still starting..."

    # Step 3: Get kubeconfig
    echo ""
    echo -e "${YELLOW}Step 3/4: Retrieving virtual cluster kubeconfig...${NC}"

    KUBECONFIG_FILE="/tmp/rancher-k3k-kubeconfig.yaml"

    # Wait for kubeconfig secret
    for i in {1..30}; do
        if kubectl get secret rancher-kubeconfig -n k3k-rancher &>/dev/null; then
            kubectl get secret rancher-kubeconfig -n k3k-rancher -o jsonpath='{.data.value}' | base64 -d > "$KUBECONFIG_FILE"
            echo "Kubeconfig saved to: $KUBECONFIG_FILE"
            break
        fi
        echo "Waiting for kubeconfig secret... ($i/30)"
        sleep 10
    done

    if [ ! -f "$KUBECONFIG_FILE" ]; then
        echo -e "${RED}Failed to retrieve kubeconfig. Manual intervention required.${NC}"
        echo "Once the cluster is ready, run:"
        echo "  kubectl get secret rancher-kubeconfig -n k3k-rancher -o jsonpath='{.data.value}' | base64 -d > kubeconfig.yaml"
        return 1
    fi

    # Step 4: Deploy Rancher into virtual cluster
    echo ""
    echo -e "${YELLOW}Step 4/4: Deploying Rancher into virtual cluster...${NC}"

    # Update post-install manifests with configuration
    RANCHER_YAML="$K3K_DIR/post-install/02-rancher.yaml"
    sed -i.bak \
        -e "s|hostname: rancher.example.com|hostname: $HOSTNAME|g" \
        -e "s|bootstrapPassword: admin|bootstrapPassword: $BOOTSTRAP_PASSWORD|g" \
        "$RANCHER_YAML"

    # Apply manifests to virtual cluster
    KUBECONFIG="$KUBECONFIG_FILE" kubectl apply -f "$K3K_DIR/post-install/01-cert-manager.yaml"
    echo "Waiting for cert-manager CRDs..."
    sleep 30
    KUBECONFIG="$KUBECONFIG_FILE" kubectl apply -f "$RANCHER_YAML"

    echo ""
    echo -e "${GREEN}k3k deployment initiated!${NC}"
    echo ""
    echo "Monitor progress with:"
    echo "  KUBECONFIG=$KUBECONFIG_FILE kubectl get pods -n cattle-system"
    echo ""
    echo "Once ready, Rancher will be available at: https://$HOSTNAME"
}

cleanup_menu() {
    echo -e "${YELLOW}Select what to clean up:${NC}"
    echo ""
    echo "  1) vCluster deployment"
    echo "  2) k3k deployment"
    echo "  3) Both"
    echo "  4) Cancel"
    echo ""
    read -p "Selection: " cleanup_choice

    case $cleanup_choice in
        1)
            echo "Removing vCluster deployment..."
            kubectl patch addon rancher-vcluster -n rancher-vcluster --type=merge -p '{"spec":{"enabled":false}}' 2>/dev/null || true
            kubectl delete -f "$SCRIPT_DIR/rancher-vcluster/rancher-vcluster.yaml" 2>/dev/null || true
            echo -e "${GREEN}vCluster deployment removed${NC}"
            ;;
        2)
            echo "Removing k3k deployment..."
            kubectl delete -f "$SCRIPT_DIR/rancher-k3k/rancher-cluster.yaml" 2>/dev/null || true
            kubectl patch addon k3k-controller -n k3k-system --type=merge -p '{"spec":{"enabled":false}}' 2>/dev/null || true
            kubectl delete -f "$SCRIPT_DIR/rancher-k3k/k3k-controller.yaml" 2>/dev/null || true
            echo -e "${GREEN}k3k deployment removed${NC}"
            ;;
        3)
            echo "Removing all deployments..."
            kubectl patch addon rancher-vcluster -n rancher-vcluster --type=merge -p '{"spec":{"enabled":false}}' 2>/dev/null || true
            kubectl delete -f "$SCRIPT_DIR/rancher-vcluster/rancher-vcluster.yaml" 2>/dev/null || true
            kubectl delete -f "$SCRIPT_DIR/rancher-k3k/rancher-cluster.yaml" 2>/dev/null || true
            kubectl patch addon k3k-controller -n k3k-system --type=merge -p '{"spec":{"enabled":false}}' 2>/dev/null || true
            kubectl delete -f "$SCRIPT_DIR/rancher-k3k/k3k-controller.yaml" 2>/dev/null || true
            echo -e "${GREEN}All deployments removed${NC}"
            ;;
        *)
            echo "Cancelled"
            ;;
    esac
}

# Main
print_header
check_kubectl

echo -e "Connected to cluster: ${GREEN}$(kubectl config current-context)${NC}"
echo ""

print_menu
read -p "Selection [1-3]: " choice

case $choice in
    1)
        deploy_vcluster
        ;;
    2)
        deploy_k3k
        ;;
    3)
        echo "Exiting."
        exit 0
        ;;
    cleanup|c)
        cleanup_menu
        ;;
    *)
        echo -e "${RED}Invalid selection${NC}"
        exit 1
        ;;
esac
