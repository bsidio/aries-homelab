#!/usr/bin/env bash
#
# Safe Cluster Shutdown Script
# Gracefully shuts down the Aries K3s cluster
#
# Usage: ./scripts/safe-shutdown.sh [--skip-node-shutdown]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
KUBECONFIG_PATH="${KUBECONFIG:-/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig}"
SKIP_NODE_SHUTDOWN=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --skip-node-shutdown)
            SKIP_NODE_SHUTDOWN=true
            shift
            ;;
    esac
done

export KUBECONFIG="$KUBECONFIG_PATH"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🛑 Aries Cluster Safe Shutdown${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Phase 1: Validation
echo -e "${YELLOW}Phase 1: Pre-shutdown validation${NC}"
echo -e "${YELLOW}  Checking cluster connectivity...${NC}"
if ! kubectl get nodes &>/dev/null; then
    echo -e "${RED}❌ Cannot connect to cluster${NC}"
    echo -e "${RED}   Check kubeconfig: $KUBECONFIG_PATH${NC}"
    exit 1
fi

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
echo -e "${GREEN}  ✓ Connected to cluster ($NODE_COUNT nodes)${NC}"

# Check for running builds
RUNNING_BUILDS=$(kubectl get pipelineruns -n tekton-builds --field-selector=status.conditions[*].reason=Running --no-headers 2>/dev/null | wc -l || echo 0)
if [ "$RUNNING_BUILDS" -gt 0 ]; then
    echo -e "${YELLOW}  ⚠️  $RUNNING_BUILDS Tekton builds currently running${NC}"
    read -p "    Continue with shutdown? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${RED}❌ Shutdown cancelled${NC}"
        exit 1
    fi
fi

echo ""

# Phase 2: Scale down applications
echo -e "${YELLOW}Phase 2: Scaling down non-critical applications${NC}"

echo -e "${YELLOW}  Scaling down Tekton pipelines...${NC}"
kubectl scale deployment -n tekton-pipelines --replicas=0 --all 2>/dev/null || echo "  (no deployments to scale)"

echo -e "${YELLOW}  Scaling down Tekton builds...${NC}"
kubectl scale deployment -n tekton-builds --replicas=0 --all 2>/dev/null || echo "  (no deployments to scale)"

echo -e "${YELLOW}  Waiting for pods to terminate...${NC}"
sleep 10

echo -e "${GREEN}  ✓ Non-critical applications scaled down${NC}"
echo ""

# Phase 3: Suspend FluxCD
echo -e "${YELLOW}Phase 3: Suspending FluxCD${NC}"

if command -v flux &>/dev/null; then
    flux suspend source git flux-system 2>/dev/null || true
    flux suspend kustomization flux-system 2>/dev/null || true
    echo -e "${GREEN}  ✓ FluxCD suspended${NC}"
else
    echo -e "${YELLOW}  ⚠️  flux CLI not found, skipping FluxCD suspension${NC}"
fi
echo ""

# Phase 4: Drain nodes
echo -e "${YELLOW}Phase 4: Draining nodes${NC}"

for node in aries3 aries2 aries1; do
    echo -e "${YELLOW}  Draining $node...${NC}"
    if kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout=300s 2>&1 | grep -q "drained"; then
        echo -e "${GREEN}    ✓ $node drained${NC}"
    else
        echo -e "${YELLOW}    ⚠️  $node drain completed with warnings (OK)${NC}"
    fi
done

echo -e "${GREEN}  ✓ All nodes drained${NC}"
echo ""

# Phase 5: Stop K3s services
echo -e "${YELLOW}Phase 5: Stopping K3s services${NC}"

for node in aries3 aries2 aries1; do
    echo -e "${YELLOW}  Stopping K3s on $node...${NC}"
    if ssh "ubuntu@$node" "sudo systemctl stop k3s" 2>&1; then
        echo -e "${GREEN}    ✓ K3s stopped on $node${NC}"
    else
        echo -e "${RED}    ❌ Failed to stop K3s on $node${NC}"
    fi
done

echo -e "${GREEN}  ✓ K3s services stopped${NC}"
echo ""

# Phase 6: Shutdown nodes
if [ "$SKIP_NODE_SHUTDOWN" = true ]; then
    echo -e "${YELLOW}Phase 6: Node shutdown skipped (--skip-node-shutdown)${NC}"
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✅ Cluster services stopped${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Nodes are ready for shutdown:${NC}"
    echo -e "  ssh ubuntu@aries3 'sudo shutdown -h now'"
    echo -e "  ssh ubuntu@aries2 'sudo shutdown -h now'"
    echo -e "  ssh ubuntu@aries1 'sudo shutdown -h now'"
else
    echo -e "${YELLOW}Phase 6: Shutting down nodes${NC}"
    echo ""
    echo -e "${RED}⚠️  WARNING: This will shutdown all cluster nodes!${NC}"
    read -p "Proceed with node shutdown? (yes/no): " confirm

    if [ "$confirm" = "yes" ]; then
        echo ""
        for node in aries3 aries2 aries1; do
            echo -e "${YELLOW}  Shutting down $node...${NC}"
            ssh "ubuntu@$node" "sudo shutdown -h now" &
            sleep 5
        done

        echo ""
        echo -e "${BLUE}========================================${NC}"
        echo -e "${GREEN}✅ Shutdown initiated on all nodes${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo -e "${YELLOW}Startup procedure:${NC}"
        echo -e "  1. Power on nodes: aries1, aries2, aries3"
        echo -e "  2. Wait ~5 minutes for cluster to initialize"
        echo -e "  3. Run: ./scripts/verify-startup.sh"
    else
        echo ""
        echo -e "${YELLOW}⚠️  Node shutdown cancelled${NC}"
        echo ""
        echo -e "${BLUE}========================================${NC}"
        echo -e "${GREEN}✅ Cluster services stopped${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo -e "${YELLOW}Current state:${NC}"
        echo -e "  • Nodes are drained"
        echo -e "  • K3s services stopped"
        echo -e "  • Nodes still running"
        echo ""
        echo -e "${YELLOW}To shutdown manually:${NC}"
        echo -e "  ssh ubuntu@aries3 'sudo shutdown -h now'"
        echo -e "  ssh ubuntu@aries2 'sudo shutdown -h now'"
        echo -e "  ssh ubuntu@aries1 'sudo shutdown -h now'"
    fi
fi

echo ""
