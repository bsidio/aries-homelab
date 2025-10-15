# Safe Shutdown and Startup Procedures

Complete procedures for safely shutting down and starting up the Aries K3s cluster.

## Table of Contents

1. [Planned Shutdown](#planned-shutdown)
2. [Startup Procedure](#startup-procedure)
3. [Emergency Shutdown](#emergency-shutdown)
4. [Post-Startup Verification](#post-startup-verification)
5. [Troubleshooting](#troubleshooting)

---

## Planned Shutdown

**Total Time**: ~15-20 minutes

Use this procedure for planned maintenance, power outages, or moving equipment.

### Prerequisites

```bash
# Set kubeconfig
export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig

# Verify cluster access
kubectl get nodes
```

### Phase 1: Pre-Shutdown Validation (2 minutes)

```bash
# 1. Check cluster health
kubectl get nodes
kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded

# 2. Identify critical workloads
kubectl get pods -A -l 'app in (prometheus,grafana,longhorn,traefik)'

# 3. Check for in-progress operations
kubectl get pipelineruns -n tekton-builds --field-selector=status.conditions[].reason=Running

# 4. Verify no pending backups
kubectl -n longhorn-system get backups --field-selector=status.state=InProgress
```

**⚠️ WARNING**: If any critical operations are running (builds, backups), wait for completion or abort them.

### Phase 2: Application Graceful Shutdown (5 minutes)

```bash
# 1. Scale down non-critical workloads
echo "Scaling down Tekton pipelines..."
kubectl scale deployment -n tekton-pipelines --replicas=0 --all

echo "Scaling down Tekton EventListener..."
kubectl scale deployment -n tekton-builds --replicas=0 --all

# 2. Wait for pods to terminate gracefully
kubectl wait --for=delete pod -n tekton-pipelines --all --timeout=120s
kubectl wait --for=delete pod -n tekton-builds -l 'app.kubernetes.io/part-of!=tekton' --timeout=120s

# 3. Scale down monitoring (to flush metrics)
echo "Flushing Prometheus metrics..."
kubectl annotate pod -n monitoring -l app.kubernetes.io/name=prometheus prometheus.io/flush=true
sleep 10

# 4. Allow Longhorn to sync
echo "Waiting for Longhorn to sync..."
sleep 30
```

### Phase 3: Suspend FluxCD (1 minute)

```bash
# Suspend FluxCD to prevent reconciliation during shutdown
flux suspend source git flux-system
flux suspend kustomization flux-system

# Verify suspension
flux get all
```

### Phase 4: Drain Nodes (5 minutes)

Drain nodes one at a time to allow workload migration:

```bash
# Drain aries3 first (non-master during rolling operations)
echo "Draining aries3..."
kubectl drain aries3 --ignore-daemonsets --delete-emptydir-data --timeout=300s --force

# Drain aries2
echo "Draining aries2..."
kubectl drain aries2 --ignore-daemonsets --delete-emptydir-data --timeout=300s --force

# Drain aries1 (last)
echo "Draining aries1..."
kubectl drain aries1 --ignore-daemonsets --delete-emptydir-data --timeout=300s --force
```

**Note**: If drain fails with "cannot delete pods not managed by ReplicationController":
```bash
# Force drain
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force --grace-period=30
```

### Phase 5: Stop K3s Services (3 minutes)

Stop K3s on all nodes in reverse order:

```bash
# Stop K3s on aries3
ssh ubuntu@aries3 "sudo systemctl stop k3s"

# Stop K3s on aries2
ssh ubuntu@aries2 "sudo systemctl stop k3s"

# Stop K3s on aries1 (last control plane node)
ssh ubuntu@aries1 "sudo systemctl stop k3s"
```

**Verify services stopped**:
```bash
ssh ubuntu@aries1 "sudo systemctl status k3s | grep 'Active:'"
ssh ubuntu@aries2 "sudo systemctl status k3s | grep 'Active:'"
ssh ubuntu@aries3 "sudo systemctl status k3s | grep 'Active:'"
```

Expected output: `Active: inactive (dead)`

### Phase 6: Shutdown Nodes (2 minutes)

Shut down nodes in order:

```bash
# Shutdown order: aries3 → aries2 → aries1
ssh ubuntu@aries3 "sudo shutdown -h now"
sleep 5

ssh ubuntu@aries2 "sudo shutdown -h now"
sleep 5

ssh ubuntu@aries1 "sudo shutdown -h now"
```

**Verify shutdown**:
```bash
# Nodes should be unreachable
ping -c 3 aries1.local
ping -c 3 aries2.local
ping -c 3 aries3.local
```

Expected: `100% packet loss`

---

## Startup Procedure

**Total Time**: ~10-15 minutes

### Phase 1: Power On Nodes (5 minutes)

**Physical Power On:**
1. Power on aries1 (wait 2 minutes for boot)
2. Power on aries2 (wait 2 minutes for boot)
3. Power on aries3 (wait 2 minutes for boot)

**Verify nodes are accessible**:
```bash
# Wait for SSH to become available (~2 minutes per node)
ssh ubuntu@aries1.local "uptime"
ssh ubuntu@aries2.local "uptime"
ssh ubuntu@aries3.local "uptime"
```

### Phase 2: Start K3s Services (3 minutes)

K3s should start automatically, but verify:

```bash
# Check K3s service status
ssh ubuntu@aries1 "sudo systemctl status k3s | grep 'Active:'"
ssh ubuntu@aries2 "sudo systemctl status k3s | grep 'Active:'"
ssh ubuntu@aries3 "sudo systemctl status k3s | grep 'Active:'"
```

**If K3s is not running**, start manually:
```bash
ssh ubuntu@aries1 "sudo systemctl start k3s"
ssh ubuntu@aries2 "sudo systemctl start k3s"
ssh ubuntu@aries3 "sudo systemctl start k3s"
```

**Wait for K3s to initialize** (~2 minutes):
```bash
# Monitor K3s logs
ssh ubuntu@aries1 "sudo journalctl -u k3s -f"
# Press Ctrl+C when you see "Cluster-Health-Check Passed"
```

### Phase 3: Verify Cluster Health (2 minutes)

```bash
export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig

# 1. Check node status (may show NotReady briefly)
kubectl get nodes
# Wait for all nodes to show "Ready"

# 2. Wait for nodes to be ready
kubectl wait --for=condition=Ready node --all --timeout=300s

# 3. Check system pods
kubectl get pods -n kube-system
kubectl get pods -n flux-system

# 4. Verify etcd cluster health
ssh ubuntu@aries1 "sudo k3s etcd-snapshot ls"
```

**Expected**: All nodes showing `Ready`, system pods running

### Phase 4: Uncordon Nodes (1 minute)

```bash
# Uncordon nodes to allow pod scheduling
kubectl uncordon aries1
kubectl uncordon aries2
kubectl uncordon aries3

# Verify
kubectl get nodes
```

All nodes should show `Ready,SchedulingEnabled`

### Phase 5: Resume FluxCD (2 minutes)

```bash
# Resume FluxCD
flux resume source git flux-system
flux resume kustomization flux-system

# Force reconciliation
flux reconcile source git flux-system
flux reconcile kustomization flux-system --with-source

# Monitor reconciliation
watch flux get all
# Press Ctrl+C when all show "Applied"
```

### Phase 6: Verify Application Recovery (5 minutes)

```bash
# 1. Check pod status across all namespaces
kubectl get pods --all-namespaces

# 2. Wait for critical applications
kubectl wait --for=condition=ready pod -n traefik-system -l app.kubernetes.io/name=traefik --timeout=300s
kubectl wait --for=condition=ready pod -n cert-manager -l app=cert-manager --timeout=300s
kubectl wait --for=condition=ready pod -n longhorn-system -l app=longhorn-manager --timeout=300s

# 3. Check storage
kubectl get pvc --all-namespaces
# All PVCs should be "Bound"

# 4. Check Longhorn volumes
kubectl -n longhorn-system get volumes
# All volumes should be "Healthy"

# 5. Verify monitoring
kubectl get pods -n monitoring
kubectl get pods -n loki-stack

# 6. Check Tekton
kubectl get pods -n tekton-pipelines
kubectl get pods -n tekton-builds
```

---

## Emergency Shutdown

Use this procedure only in emergency situations (power failure imminent, hardware issues).

### Immediate Shutdown (30 seconds)

```bash
# Shutdown all nodes immediately (DO NOT USE FOR PLANNED MAINTENANCE)
ssh ubuntu@aries1 "sudo shutdown -h now" &
ssh ubuntu@aries2 "sudo shutdown -h now" &
ssh ubuntu@aries3 "sudo shutdown -h now" &
```

**⚠️ WARNING**: This may cause:
- Data loss for in-flight transactions
- Corrupted etcd state (unlikely but possible)
- Longhorn volume inconsistencies
- Need for manual recovery procedures

**After emergency shutdown**, follow the standard [Startup Procedure](#startup-procedure) but add:

```bash
# Check for etcd corruption
ssh ubuntu@aries1 "sudo k3s check-config"

# If etcd is corrupted, restore from snapshot
ssh ubuntu@aries1 "sudo k3s etcd-snapshot ls"
ssh ubuntu@aries1 "sudo k3s etcd-snapshot restore <snapshot-name>"
```

---

## Post-Startup Verification

Complete checklist after startup:

### Infrastructure Layer

```bash
# ✅ Nodes Ready
kubectl get nodes
# Expected: All nodes "Ready"

# ✅ System Pods Running
kubectl get pods -n kube-system
# Expected: All pods "Running"

# ✅ FluxCD Operational
flux check
flux get all
# Expected: All "Applied" or "True"
```

### Storage Layer

```bash
# ✅ Longhorn Healthy
kubectl get pods -n longhorn-system
# Expected: All pods "Running"

kubectl -n longhorn-system get volumes
# Expected: All volumes "Healthy"

# ✅ PVCs Bound
kubectl get pvc --all-namespaces
# Expected: All "Bound"
```

### Network Layer

```bash
# ✅ Traefik Ready
kubectl get pods -n traefik-system
kubectl get svc -n traefik-system traefik
# Expected: LoadBalancer IP 10.0.0.201

# ✅ External-DNS Running
kubectl get pods -n external-dns
# Expected: Pod "Running"

# ✅ Cert-Manager Ready
kubectl get pods -n cert-manager
kubectl get certificates --all-namespaces
# Expected: All certificates "Ready=True"
```

### Application Layer

```bash
# ✅ Harbor (if deployed)
kubectl get pods -n harbor-system
curl -k https://harbor.sidapi.com

# ✅ Monitoring Stack
kubectl get pods -n monitoring
curl -k https://monitoring.sidapi.com

# ✅ Tekton
kubectl get pods -n tekton-pipelines
kubectl get pods -n tekton-builds
curl -k https://builds.sidapi.com
```

### Functional Tests

```bash
# ✅ Test DNS Resolution
nslookup sidapi.com
# Expected: Resolves to 10.0.0.201 (or public IP)

# ✅ Test HTTPS Access
curl -k https://sidapi.com
# Expected: HTTP 200 or appropriate response

# ✅ Test Longhorn UI
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80 &
curl http://localhost:8080
# Expected: HTTP 200
```

### Post-Startup Checklist

- [ ] All nodes showing "Ready"
- [ ] All system pods running
- [ ] FluxCD reconciling successfully
- [ ] Longhorn volumes healthy
- [ ] All PVCs bound
- [ ] Traefik LoadBalancer has IP
- [ ] Certificates ready
- [ ] Monitoring accessible
- [ ] Applications responding
- [ ] DNS resolving correctly
- [ ] HTTPS working
- [ ] No critical alerts in Prometheus/AlertManager

---

## Troubleshooting

### Node Stuck in NotReady

**Symptoms**: Node shows "NotReady" after startup

**Resolution**:
```bash
# Check node status details
kubectl describe node <node-name>

# Check kubelet logs
ssh ubuntu@<node> "sudo journalctl -u k3s -n 100"

# Restart K3s if needed
ssh ubuntu@<node> "sudo systemctl restart k3s"
```

### etcd Cluster Not Forming

**Symptoms**: Nodes can't join cluster, etcd errors in logs

**Resolution**:
```bash
# Check etcd member list
ssh ubuntu@aries1 "sudo k3s etcd-snapshot ls"

# Verify etcd cluster health
ssh ubuntu@aries1 "sudo k3s etcd-snapshot check"

# If corrupted, restore from latest snapshot
ssh ubuntu@aries1 "sudo k3s etcd-snapshot restore <snapshot-name>"
```

### Pods Stuck in Pending

**Symptoms**: Pods won't schedule after startup

**Resolution**:
```bash
# Check node cordoned status
kubectl get nodes

# Uncordon if needed
kubectl uncordon <node-name>

# Check pod events
kubectl describe pod <pod-name> -n <namespace>

# Check node resources
kubectl top nodes
kubectl describe node <node-name>
```

### PVCs Stuck in Pending

**Symptoms**: PersistentVolumeClaims can't bind to volumes

**Resolution**:
```bash
# Check Longhorn status
kubectl get pods -n longhorn-system

# Check volume health
kubectl -n longhorn-system get volumes

# Access Longhorn UI to investigate
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80

# If volume is degraded, allow time for Longhorn to rebuild
# Longhorn automatically rebuilds replicas when nodes come online
```

### Certificates Not Renewing

**Symptoms**: TLS certificates showing "Not Ready"

**Resolution**:
```bash
# Check cert-manager pods
kubectl get pods -n cert-manager

# Check certificate status
kubectl get certificates --all-namespaces
kubectl describe certificate <cert-name> -n <namespace>

# Check ClusterIssuer
kubectl describe clusterissuer letsencrypt-prod

# Force certificate renewal
kubectl delete certificaterequest -n <namespace> <request-name>
```

### FluxCD Not Reconciling

**Symptoms**: Applications not deploying after startup

**Resolution**:
```bash
# Check FluxCD status
flux check

# Check for suspended resources
flux get all

# Resume if suspended
flux resume source git flux-system
flux resume kustomization flux-system

# Force reconciliation
flux reconcile source git flux-system
flux reconcile kustomization flux-system --with-source

# Check FluxCD logs
kubectl logs -n flux-system deploy/kustomize-controller
kubectl logs -n flux-system deploy/source-controller
```

### Monitoring Stack Not Responding

**Symptoms**: Grafana/Prometheus not accessible

**Resolution**:
```bash
# Check monitoring pods
kubectl get pods -n monitoring

# Check PVC status (Prometheus stores data)
kubectl get pvc -n monitoring

# Allow time for Prometheus to recover WAL (~5-10 minutes)
kubectl logs -n monitoring prometheus-kube-prometheus-stack-prometheus-0

# Restart Grafana if needed
kubectl rollout restart -n monitoring deployment/kube-prometheus-stack-grafana
```

---

## Shutdown/Startup Scripts

### Automated Shutdown Script

Create: `~/Documents/aries-homelab/homelab-ansible/scripts/safe-shutdown.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig

echo "🛑 Starting safe cluster shutdown..."
echo ""

# Phase 1: Validation
echo "Phase 1: Pre-shutdown validation"
kubectl get nodes || { echo "❌ Cannot connect to cluster"; exit 1; }
echo ""

# Phase 2: Scale down
echo "Phase 2: Scaling down applications"
kubectl scale deployment -n tekton-pipelines --replicas=0 --all
kubectl scale deployment -n tekton-builds --replicas=0 --all
sleep 10
echo ""

# Phase 3: Suspend Flux
echo "Phase 3: Suspending FluxCD"
flux suspend source git flux-system
flux suspend kustomization flux-system
echo ""

# Phase 4: Drain nodes
echo "Phase 4: Draining nodes"
kubectl drain aries3 --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
kubectl drain aries2 --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
kubectl drain aries1 --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
echo ""

# Phase 5: Stop K3s
echo "Phase 5: Stopping K3s services"
ssh ubuntu@aries3 "sudo systemctl stop k3s"
ssh ubuntu@aries2 "sudo systemctl stop k3s"
ssh ubuntu@aries1 "sudo systemctl stop k3s"
echo ""

# Phase 6: Shutdown nodes
echo "Phase 6: Shutting down nodes"
read -p "Proceed with node shutdown? (yes/no): " confirm
if [ "$confirm" = "yes" ]; then
    ssh ubuntu@aries3 "sudo shutdown -h now"
    sleep 5
    ssh ubuntu@aries2 "sudo shutdown -h now"
    sleep 5
    ssh ubuntu@aries1 "sudo shutdown -h now"
    echo "✅ Shutdown initiated on all nodes"
else
    echo "⚠️  Node shutdown cancelled"
    echo "   Nodes are drained but still running"
    echo "   To shutdown manually: ssh ubuntu@aries<N> 'sudo shutdown -h now'"
fi
```

### Automated Startup Verification Script

Create: `~/Documents/aries-homelab/homelab-ansible/scripts/verify-startup.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig

echo "✅ Starting post-startup verification..."
echo ""

# Wait for cluster
echo "Waiting for cluster API..."
until kubectl get nodes &>/dev/null; do
    echo "  Waiting for API server..."
    sleep 5
done
echo "  ✓ API server responding"
echo ""

# Check nodes
echo "Checking nodes..."
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get nodes
echo ""

# Uncordon nodes
echo "Uncordoning nodes..."
kubectl uncordon aries1 aries2 aries3
echo ""

# Resume Flux
echo "Resuming FluxCD..."
flux resume source git flux-system
flux resume kustomization flux-system
flux reconcile source git flux-system
flux reconcile kustomization flux-system --with-source
echo ""

# Wait for critical apps
echo "Waiting for critical applications..."
kubectl wait --for=condition=ready pod -n traefik-system -l app.kubernetes.io/name=traefik --timeout=300s
kubectl wait --for=condition=ready pod -n longhorn-system -l app=longhorn-manager --timeout=300s
echo ""

# Summary
echo "=========================================="
echo "✅ Startup verification complete!"
echo "=========================================="
echo ""
echo "Nodes:"
kubectl get nodes
echo ""
echo "Critical Pods:"
kubectl get pods -n traefik-system
kubectl get pods -n longhorn-system
kubectl get pods -n monitoring
echo ""
echo "Next steps:"
echo "1. Check https://sidapi.com (or deployed apps)"
echo "2. Verify Grafana: https://monitoring.sidapi.com"
echo "3. Check Tekton: https://builds.sidapi.com"
```

Make scripts executable:
```bash
chmod +x ~/Documents/aries-homelab/homelab-ansible/scripts/safe-shutdown.sh
chmod +x ~/Documents/aries-homelab/homelab-ansible/scripts/verify-startup.sh
```

---

## Summary

### Planned Shutdown
```bash
# Automated (recommended)
~/Documents/aries-homelab/homelab-ansible/scripts/safe-shutdown.sh

# Manual steps
1. Drain nodes (15 min)
2. Stop K3s services (3 min)
3. Shutdown nodes (2 min)
Total: ~20 minutes
```

### Startup
```bash
# Power on nodes
1. aries1 → wait 2 min
2. aries2 → wait 2 min
3. aries3 → wait 2 min

# Verify
~/Documents/aries-homelab/homelab-ansible/scripts/verify-startup.sh

Total: ~15 minutes
```

### Emergency
```bash
# Immediate shutdown (NOT RECOMMENDED)
for node in aries{1,2,3}; do
    ssh ubuntu@$node "sudo shutdown -h now" &
done
```

---

**Last Updated**: 2025-10-14
**Tested On**: Aries K3s v1.29.9+k3s1
