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
    prompt_config BOOTSTRAP_PASSWORD "Enter initial admin password" ""

    if [ -z "$BOOTSTRAP_PASSWORD" ]; then
        echo -e "${RED}Error: Bootstrap password is required${NC}"
        exit 1
    fi

    echo ""
    echo -e "${YELLOW}Updating rancher-vcluster.yaml with your configuration...${NC}"

    # Create a temporary file with updated values
    VCLUSTER_YAML="$SCRIPT_DIR/rancher-vcluster/rancher-vcluster.yaml"

    # Update hostname and password in the yaml
    sed -i.bak \
        -e "s|hostname: \"\"|hostname: \"$HOSTNAME\"|g" \
        -e "s|bootstrapPassword: \"\"|bootstrapPassword: \"$BOOTSTRAP_PASSWORD\"|g" \
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
    echo "Launching k3k deploy script..."
    exec "$SCRIPT_DIR/rancher-k3k/deploy.sh"
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
            exec "$SCRIPT_DIR/rancher-k3k/destroy.sh"
            ;;
        3)
            echo "Removing all deployments..."
            kubectl patch addon rancher-vcluster -n rancher-vcluster --type=merge -p '{"spec":{"enabled":false}}' 2>/dev/null || true
            kubectl delete -f "$SCRIPT_DIR/rancher-vcluster/rancher-vcluster.yaml" 2>/dev/null || true
            "$SCRIPT_DIR/rancher-k3k/destroy.sh"
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
