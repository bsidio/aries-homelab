# Longhorn Quick Reference

Essential commands for managing Longhorn storage, backups, and disaster recovery.

## Environment Setup

```bash
export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig
```

---

## Access Longhorn UI

### Local Proxy (Recommended)
```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Access at: http://localhost:8080
```

### Background Proxy
```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80 &
# Stop: pkill -f "kubectl port-forward.*longhorn-frontend"
```

---

## Volume Management

### List Volumes
```bash
# All volumes
kubectl get volumes.longhorn.io -n longhorn-system

# With PVC mapping
kubectl get volumes.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | "\(.metadata.name): \(.status.kubernetesStatus.pvcName) (\(.status.kubernetesStatus.namespace))"'

# Show size and replicas
kubectl get volumes.longhorn.io -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
SIZE:.spec.size,\
REPLICAS:.spec.numberOfReplicas,\
STATE:.status.state
```

### Check Volume Details
```bash
kubectl get volume <volume-name> -n longhorn-system -o yaml
```

### List PVCs and Their Volumes
```bash
# All PVCs
kubectl get pvc -A

# Specific namespace
kubectl get pvc -n monitoring

# With volume names
kubectl get pvc -A -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
VOLUME:.spec.volumeName,\
SIZE:.spec.resources.requests.storage
```

---

## Backup Management

### List Backup Volumes
```bash
# All backup volumes (what's in R2)
kubectl get backupvolumes.longhorn.io -n longhorn-system

# With details
kubectl get backupvolumes.longhorn.io -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
SIZE:.status.size,\
CREATED:.metadata.creationTimestamp,\
LAST_BACKUP:.status.lastBackupAt
```

### List Backup Snapshots
```bash
# All backup snapshots
kubectl get backups.longhorn.io -n longhorn-system

# Count backups per volume
kubectl get backups.longhorn.io -n longhorn-system -o json | \
  jq -r '.items | group_by(.spec.snapshotName) | .[] | "\(.[0].spec.snapshotName): \(length) snapshots"'

# Check backup size
kubectl get backups.longhorn.io -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
VOLUME:.spec.snapshotName,\
STATE:.status.state,\
SIZE:.status.size
```

### Check Backup Configuration
```bash
# Backup target (R2 settings)
kubectl get settings.longhorn.io backup-target -n longhorn-system -o yaml

# Backup credentials
kubectl get secret longhorn-r2-backups -n longhorn-system

# Recurring backup jobs
kubectl get recurringjobs.longhorn.io -n longhorn-system
```

### Delete Backup Volumes
```bash
# Delete a specific backup volume (and all its snapshots)
kubectl delete backupvolume <pvc-id> -n longhorn-system

# Delete all backups for orphaned volumes
kubectl get backupvolumes.longhorn.io -n longhorn-system -o name | while read bv; do
  pvc_id=$(echo $bv | sed 's|backupvolume.longhorn.io/||')
  kubectl get pv $pvc_id &>/dev/null || kubectl delete $bv -n longhorn-system
done
```

---

## Restore from Backup

### List Available Backups for Restore
```bash
# Via Longhorn UI: http://localhost:8080 ’ Backup tab
# Or check backup volumes
kubectl get backupvolumes.longhorn.io -n longhorn-system
kubectl get backups.longhorn.io -n longhorn-system | grep <volume-name>
```

### Restore Volume from Backup
```yaml
# Create restore-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-volume
  namespace: <namespace>
  annotations:
    longhorn.io/restore-from-backup: "s3://aries@auto/backups/<backup-name>"
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: <size>  # Must match original or larger
```

Apply:
```bash
kubectl apply -f restore-pvc.yaml
```

### Restore via Longhorn UI (Easier)
1. Go to http://localhost:8080
2. Click **Backup** tab
3. Find the backup volume
4. Click **î** ’ **Restore**
5. Specify:
   - Name for new PVC
   - Namespace
   - Storage class
6. Click **OK**
7. New PVC will be created with restored data

---

## Disaster Recovery

### Complete Cluster Recovery

**Prerequisites:**
- Cloudflare R2 bucket with backups intact
- Fresh Kubernetes cluster with Longhorn installed
- R2 credentials configured

**Steps:**

1. **Configure Backup Target**
```bash
# Apply R2 credentials secret
kubectl apply -f clusters/aries/apps/longhorn/longhorn-r2-backups.secret.enc.yaml

# Set backup target
kubectl edit settings.longhorn.io backup-target -n longhorn-system
# Set: s3://aries@auto/
```

2. **Sync Backups**
```bash
# Via UI: Backup tab ’ Click "Restore Backup" button
# System will sync all available backups from R2
```

3. **Restore Critical Volumes**
```bash
# Restore in order:
# 1. Prometheus (monitoring data)
# 2. Grafana (dashboards)
# 3. Harbor database (registry metadata)
# 4. Loki (logs)
# 5. Application data (postgres, redis, etc.)
```

4. **Recreate Pods**
```bash
# Delete pods to pick up restored PVCs
kubectl delete pod <pod-name> -n <namespace>
```

### Backup Verification
```bash
# Ensure all critical volumes have recent backups
kubectl get backupvolumes.longhorn.io -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
LAST_BACKUP:.status.lastBackupAt,\
LAST_SYNCED:.status.lastSyncedAt

# Check for volumes missing backups
for pvc in $(kubectl get pvc -A -o json | jq -r '.items[].spec.volumeName'); do
  kubectl get backupvolume $pvc -n longhorn-system &>/dev/null || echo "No backup: $pvc"
done
```

---

## Recurring Jobs

### List Recurring Jobs
```bash
kubectl get recurringjobs.longhorn.io -n longhorn-system
```

### Check Job Configuration
```bash
kubectl get recurringjob <job-name> -n longhorn-system -o yaml
```

### Manually Trigger Backup Job
```bash
# Via UI: Volume tab ’ Select volume ’ Create Backup
# Or via CLI (create snapshot then backup):
kubectl exec -n longhorn-system <longhorn-manager-pod> -- \
  longhorn-manager volume <volume-name> snapshot create --name manual-backup
```

---

## Exclude Volumes from Backup

### Annotate PVC to Exclude
```bash
kubectl annotate pvc <pvc-name> -n <namespace> \
  "recurring-job.longhorn.io/source=ignore" \
  "longhorn.io/exclude-from-backup=true" \
  --overwrite
```

### Bulk Exclude (e.g., tekton-builds)
```bash
kubectl get pvc -n tekton-builds -o name | while read pvc; do
  kubectl annotate $pvc -n tekton-builds \
    "recurring-job.longhorn.io/source=ignore" \
    --overwrite
done
```

### Verify Exclusions
```bash
kubectl get pvc -n <namespace> -o json | \
  jq -r '.items[] | select(.metadata.annotations."recurring-job.longhorn.io/source" == "ignore") | .metadata.name'
```

---

## Troubleshooting

### Check Longhorn System Health
```bash
# Manager pods
kubectl get pods -n longhorn-system -l app=longhorn-manager

# Driver pods
kubectl get pods -n longhorn-system -l app=longhorn-driver-deployer

# CSI components
kubectl get pods -n longhorn-system | grep csi
```

### Check Volume Health
```bash
# All volumes status
kubectl get volumes.longhorn.io -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
STATE:.status.state,\
ROBUSTNESS:.status.robustness,\
REPLICAS:.spec.numberOfReplicas

# Volumes with issues
kubectl get volumes.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.state != "attached" and .status.state != "detached") | .metadata.name'
```

### Check Backup Status
```bash
# Failed backups
kubectl get backups.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.state != "Completed") | "\(.metadata.name): \(.status.state)"'

# Backup in progress
kubectl get backups.longhorn.io -n longhorn-system | grep -v Completed
```

### View Longhorn Logs
```bash
# Manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100

# Specific manager pod
kubectl logs -n longhorn-system <longhorn-manager-pod-name> -f

# CSI provisioner
kubectl logs -n longhorn-system -l app=csi-provisioner --tail=100

# All errors in last hour
kubectl logs -n longhorn-system -l app=longhorn-manager --since=1h | grep -i error
```

### Check Storage Usage
```bash
# Per-node storage
kubectl get nodes.longhorn.io -n longhorn-system -o custom-columns=\
NODE:.metadata.name,\
SCHEDULABLE:.spec.allowScheduling,\
STORAGE_AVAILABLE:.status.diskStatus.*.storageAvailable,\
STORAGE_SCHEDULED:.status.diskStatus.*.storageScheduled

# Total cluster storage
kubectl get nodes.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[].status.diskStatus | to_entries[] | .value |
    "Available: \(.storageAvailable | tonumber / 1073741824 | floor)GB, Used: \((.storageScheduled | tonumber) / 1073741824 | floor)GB"'
```

---

## Performance & Monitoring

### Check Volume Performance
```bash
# Volume latency and IOPS via UI
# http://localhost:8080 ’ Volume tab ’ Select volume ’ View metrics
```

### Enable Metrics
```bash
# Longhorn already exposes Prometheus metrics
# Metrics endpoint: http://longhorn-frontend:80/metrics

# Check ServiceMonitor
kubectl get servicemonitor -n longhorn-system
```

### Monitor Backup Progress
```bash
# Watch backup creation
kubectl get backups.longhorn.io -n longhorn-system -w

# Check specific backup
kubectl get backup <backup-name> -n longhorn-system -o yaml
```

---

## Cleanup & Maintenance

### Delete Orphaned Volumes
```bash
# List detached volumes
kubectl get volumes.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.state == "detached") | .metadata.name'

# Delete orphaned volumes (be careful!)
kubectl delete volume <volume-name> -n longhorn-system
```

### Clean Old Snapshots
```bash
# List snapshots
kubectl get snapshots.longhorn.io -n longhorn-system

# Delete old snapshots (Longhorn auto-cleans based on retention)
# Manual deletion:
kubectl delete snapshot <snapshot-name> -n longhorn-system
```

### Clean Orphaned Backups (Automated)
```bash
# Trigger orphaned backup cleanup job
kubectl create job --from=cronjob/cleanup-orphaned-backups cleanup-now -n longhorn-system

# Check cleanup logs
kubectl logs job/cleanup-now -n longhorn-system
```

---

## Storage Classes

### List Storage Classes
```bash
kubectl get storageclass

# Longhorn storage classes:
# - longhorn (default, no backups)
# - longhorn-backup (with recurring backups)
# - longhorn-retain (retain PV after PVC deletion)
```

### Create PVC with Specific Storage Class
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-backup  # or longhorn, longhorn-retain
  resources:
    requests:
      storage: 10Gi
```

---

## Migration & Upgrades

### Upgrade Longhorn
```bash
# Via Helm (managed by FluxCD)
# Edit clusters/aries/apps/longhorn/helmrelease.yaml
# Update version, commit, push

# Check upgrade status
kubectl get helmrelease longhorn -n longhorn-system
flux get helmreleases -n longhorn-system
```

### Migrate Volume Between Nodes
```bash
# Via UI: Volume tab ’ Select volume ’ Update Replicas
# Or force replica rebuild:
kubectl annotate volume <volume-name> -n longhorn-system \
  "longhorn.io/force-replica-rebuild=true"
```

---

## Quick Diagnostics

### Check Everything at Once
```bash
echo "=== Longhorn Pods ==="
kubectl get pods -n longhorn-system

echo -e "\n=== Volumes ==="
kubectl get volumes.longhorn.io -n longhorn-system | head -10

echo -e "\n=== Recent Backups ==="
kubectl get backups.longhorn.io -n longhorn-system --sort-by=.metadata.creationTimestamp | tail -5

echo -e "\n=== Storage Classes ==="
kubectl get storageclass | grep longhorn

echo -e "\n=== PVCs ==="
kubectl get pvc -A | grep longhorn | wc -l
echo "PVCs using Longhorn"
```

---

## Common Tasks

### Create Test Volume
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-longhorn-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF
```

### Delete Test Volume
```bash
kubectl delete pvc test-longhorn-pvc -n default
```

### Force Backup of Volume
```bash
# Via UI: Volume ’ Select ’ Create Backup
# Manual annotation triggers next backup job
kubectl annotate volume <volume-name> -n longhorn-system \
  "longhorn.io/last-backup=$(date +%s)"
```

---

## Configuration Files

### Key Files in Repository
```
/Users/sb/Documents/git/aries-cluster-config/clusters/aries/apps/longhorn/
   helmrelease.yaml                      # Longhorn Helm chart config
   longhorn-r2-backups.secret.enc.yaml   # R2 credentials (SOPS encrypted)
   storageclasses.yaml                   # Custom storage classes
   volumesnapshotclass.yaml              # Snapshot class
   cleanup-orphaned-backups.yaml         # Daily R2 cleanup CronJob
   kustomization.yaml                    # Resource list
```

### View Current Configuration
```bash
# Backup target
kubectl get settings.longhorn.io backup-target -n longhorn-system -o yaml

# All settings
kubectl get settings.longhorn.io -n longhorn-system

# R2 configuration
kubectl get secret longhorn-r2-backups -n longhorn-system -o yaml
```

---

## Backup & R2 Information

### Current Backup Configuration
- **Backup Target**: Cloudflare R2 (`s3://aries@auto/`)
- **Schedule**: Daily at 3:00 AM UTC
- **Retention**: 7 days
- **Cleanup**: Daily at 4:00 AM UTC (orphaned backups)

### What's Being Backed Up
- Prometheus (50GB) - Metrics database
- Grafana (10GB) - Dashboards
- Alertmanager (10GB) - Alert state
- Loki (20GB) - Application logs
- Harbor database (5GB) - Registry metadata
- Sample app databases (~200MB)

### What's Excluded from Backup
- Harbor registry (50GB) - Container images
- Harbor Redis (2GB) - Cache
- Harbor Trivy (5GB) - Vulnerability DB
- Harbor jobservice (1GB) - Logs
- Tekton build PVCs - Ephemeral workspaces

---

## Related Documentation

- **Longhorn Docs**: https://longhorn.io/docs/
- **Backup Guide**: `/Users/sb/Documents/aries-homelab/Databases/mysql-prometheus-monitoring.md`
- **R2 Configuration**: `clusters/aries/apps/longhorn/helmrelease.yaml`
- **Grafana Dashboard**: http://localhost:8080 (via port-forward)

---

## Emergency Contacts

**If Longhorn is broken:**
1. Check manager pods: `kubectl get pods -n longhorn-system`
2. Check logs: `kubectl logs -n longhorn-system -l app=longhorn-manager`
3. Access UI for visual troubleshooting: `kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80`
4. Check R2 backups are intact: `kubectl get backupvolumes.longhorn.io -n longhorn-system`

**Last Updated**: 2025-10-23
**Cluster**: aries
**Longhorn Version**: 1.6.x
