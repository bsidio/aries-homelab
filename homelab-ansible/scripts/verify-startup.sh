#!/usr/bin/env bash
#
# Startup Verification Script
# Verifies cluster health after startup and resumes operations
#
# Usage: ./scripts/verify-startup.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
KUBECONFIG_PATH="${KUBECONFIG:-/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig}"
export KUBECONFIG="$KUBECONFIG_PATH"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}✅ Aries Cluster Startup Verification${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Phase 1: Wait for cluster
echo -e "${YELLOW}Phase 1: Waiting for cluster API${NC}"
RETRIES=0
MAX_RETRIES=60

while ! kubectl get nodes &>/dev/null; do
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -ge $MAX_RETRIES ]; then
        echo -e "${RED}❌ Cluster API not responding after $MAX_RETRIES attempts${NC}"
        echo -e "${RED}   Check nodes are powered on and K3s is running${NC}"
        exit 1
    fi
    echo -e "  Waiting for API server... (attempt $RETRIES/$MAX_RETRIES)"
    sleep 5
done

echo -e "${GREEN}  ✓ API server responding${NC}"
echo ""

# Phase 2: Check node status
echo -e "${YELLOW}Phase 2: Checking node status${NC}"

echo -e "  Waiting for nodes to be Ready..."
if kubectl wait --for=condition=Ready node --all --timeout=300s 2>&1 | grep -q "condition met"; then
    echo -e "${GREEN}  ✓ All nodes are Ready${NC}"
else
    echo -e "${YELLOW}  ⚠️  Some nodes may not be Ready yet${NC}"
fi

echo ""
kubectl get nodes
echo ""

# Phase 3: Uncordon nodes
echo -e "${YELLOW}Phase 3: Uncordoning nodes${NC}"

for node in aries1 aries2 aries3; do
    if kubectl uncordon "$node" 2>&1 | grep -q "uncordoned"; then
        echo -e "${GREEN}  ✓ $node uncordoned${NC}"
    else
        echo -e "${YELLOW}  ⚠️  $node already scheduling enabled${NC}"
    fi
done

echo ""

# Phase 4: Resume FluxCD
echo -e "${YELLOW}Phase 4: Resuming FluxCD${NC}"

if command -v flux &>/dev/null; then
    flux resume source git flux-system 2>/dev/null || true
    flux resume kustomization flux-system 2>/dev/null || true

    echo -e "${YELLOW}  Triggering reconciliation...${NC}"
    flux reconcile source git flux-system 2>&1 | grep -i "reconciliation"
    flux reconcile kustomization flux-system --with-source 2>&1 | grep -i "reconciliation"

    echo -e "${GREEN}  ✓ FluxCD resumed and reconciling${NC}"
else
    echo -e "${YELLOW}  ⚠️  flux CLI not found, skipping FluxCD operations${NC}"
fi
echo ""

# Phase 5: Wait for critical applications
echo -e "${YELLOW}Phase 5: Waiting for critical applications${NC}"

echo -e "${YELLOW}  Waiting for Traefik...${NC}"
if kubectl wait --for=condition=ready pod -n traefik-system -l app.kubernetes.io/name=traefik --timeout=300s 2>&1 | grep -q "condition met"; then
    echo -e "${GREEN}    ✓ Traefik ready${NC}"
else
    echo -e "${YELLOW}    ⚠️  Traefik may still be starting${NC}"
fi

echo -e "${YELLOW}  Waiting for Longhorn...${NC}"
if kubectl wait --for=condition=ready pod -n longhorn-system -l app=longhorn-manager --timeout=300s 2>&1 | grep -q "condition met"; then
    echo -e "${GREEN}    ✓ Longhorn ready${NC}"
else
    echo -e "${YELLOW}    ⚠️  Longhorn may still be starting${NC}"
fi

echo -e "${YELLOW}  Waiting for cert-manager...${NC}"
if kubectl wait --for=condition=ready pod -n cert-manager -l app=cert-manager --timeout=300s 2>&1 | grep -q "condition met"; then
    echo -e "${GREEN}    ✓ cert-manager ready${NC}"
else
    echo -e "${YELLOW}    ⚠️  cert-manager may still be starting${NC}"
fi

echo ""

# Phase 6: Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✅ Startup Verification Complete${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${BLUE}Cluster Status:${NC}"
kubectl get nodes
echo ""

echo -e "${BLUE}Critical Services:${NC}"
echo ""
echo -e "${YELLOW}Traefik (Ingress Controller):${NC}"
kubectl get pods -n traefik-system 2>/dev/null || echo "  Not deployed yet"

echo ""
echo -e "${YELLOW}Longhorn (Storage):${NC}"
kubectl get pods -n longhorn-system -l app=longhorn-manager 2>/dev/null || echo "  Not deployed yet"

echo ""
echo -e "${YELLOW}Monitoring:${NC}"
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus 2>/dev/null || echo "  Not deployed yet"

echo ""
echo -e "${YELLOW}Tekton:${NC}"
kubectl get pods -n tekton-pipelines -l app.kubernetes.io/part-of=tekton-pipelines 2>/dev/null || echo "  Not deployed yet"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Next Steps:${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "1. Check application access:"
echo -e "   ${YELLOW}https://sidapi.com${NC}"
echo -e "   ${YELLOW}https://builds.sidapi.com${NC}"
echo -e "   ${YELLOW}https://harbor.sidapi.com${NC}"
echo ""
echo -e "2. Verify Grafana monitoring:"
echo -e "   ${YELLOW}kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80${NC}"
echo -e "   ${YELLOW}http://localhost:3000${NC}"
echo ""
echo -e "3. Check Longhorn storage:"
echo -e "   ${YELLOW}kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80${NC}"
echo -e "   ${YELLOW}http://localhost:8080${NC}"
echo ""
echo -e "4. Monitor FluxCD:"
echo -e "   ${YELLOW}flux get all${NC}"
echo ""

# Check for issues
ISSUES=0

NOT_READY=$(kubectl get nodes --no-headers | grep -v " Ready" | wc -l)
if [ "$NOT_READY" -gt 0 ]; then
    echo -e "${RED}⚠️  WARNING: $NOT_READY node(s) not Ready${NC}"
    ISSUES=$((ISSUES + 1))
fi

PENDING_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
if [ "$PENDING_PODS" -gt 0 ]; then
    echo -e "${YELLOW}⚠️  INFO: $PENDING_PODS pod(s) still Pending (may be normal during startup)${NC}"
fi

FAILED_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
if [ "$FAILED_PODS" -gt 0 ]; then
    echo -e "${RED}⚠️  WARNING: $FAILED_PODS pod(s) in Failed state${NC}"
    ISSUES=$((ISSUES + 1))
fi

if [ $ISSUES -eq 0 ]; then
    echo -e "${GREEN}✅ No critical issues detected${NC}"
else
    echo -e "${RED}⚠️  $ISSUES potential issue(s) detected${NC}"
    echo -e "${YELLOW}   Review the warnings above and check pod/node status${NC}"
fi

echo ""
