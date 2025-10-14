# Disaster Recovery Guide - Aries Cluster

Complete guide to rebuild the Aries K3s cluster from scratch.

## Prerequisites

Before starting recovery, ensure you have:

1. ✅ **SSH Access**: SSH key at `~/.ssh/homelab_ed25519`
2. ✅ **SOPS Age Key**: Private key backed up from `~/.config/sops/age/keys.txt`
3. ✅ **GitHub Access**: Personal access token for flux-system
4. ✅ **DNS Access**: Ability to configure sidapi.com DNS records
5. ✅ **Git Repositories**:
   - `aries-homelab` (Ansible playbooks)
   - `aries-cluster-config` (GitOps configuration)

## Recovery Time Objective (RTO)

**Total Time**: ~30-45 minutes
- Node Bootstrap: ~10 minutes
- K3s Installation: ~5 minutes
- Flux Setup: ~5 minutes
- Application Deployment: ~15-25 minutes (automatic via Flux)

## Step-by-Step Recovery

### Phase 1: Restore SOPS Key (2 minutes)

```bash
# 1. Restore SOPS Age private key
mkdir -p ~/.config/sops/age
# Copy your backed-up Age key to:
cp /path/to/backup/keys.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# 2. Verify key is valid
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d /path/to/any-encrypted-secret.yaml
```

**⚠️ CRITICAL**: Without this key, you cannot decrypt secrets and must regenerate all of them.

### Phase 2: Bootstrap Cluster Nodes (10 minutes)

```bash
cd /Users/sb/Documents/aries-homelab/homelab-ansible

# 1. Bootstrap nodes with base configuration
ansible-playbook -i inventories/prod/hosts.ini playbooks/bootstrap.yml -u sid -k -K

# This configures:
# - ubuntu user with sudo
# - Base packages (curl, vim, git, python3)
# - iSCSI services for Longhorn
# - System tuning for Kubernetes
# - Required kernel modules
```

### Phase 3: Install K3s HA Cluster (5 minutes)

```bash
# 2. Install K3s in HA mode
ansible-playbook -i inventories/prod/hosts.ini playbooks/k3s-ha.yml

# This creates:
# - 3-node control plane with embedded etcd
# - Cluster CIDR: 10.42.0.0/16
# - Service CIDR: 10.43.0.0/16
# - ServiceLB disabled (using MetalLB)

# 3. Fetch kubeconfig
ansible-playbook -i inventories/prod/hosts.ini playbooks/fetch-kubeconfig.yml

# 4. Verify cluster
export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig
kubectl get nodes
# Should show: aries1, aries2, aries3 all Ready
```

### Phase 4: Install Flux GitOps (5 minutes)

```bash
# 1. Set environment variables
export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig
export GITHUB_TOKEN=<your-github-token>
export GITHUB_USER=bsidio

# 2. Bootstrap Flux (idempotent)
flux bootstrap github \
  --owner=${GITHUB_USER} \
  --repository=aries-cluster-config \
  --branch=main \
  --path=clusters/aries \
  --personal \
  --private=false

# 3. Verify Flux installation
kubectl get pods -n flux-system
# Should see: source-controller, kustomize-controller, helm-controller, notification-controller

# 4. Watch Flux reconcile
flux get kustomizations --watch
```

### Phase 5: Verify Application Deployment (15-25 minutes)

Flux will automatically deploy all applications. Monitor progress:

```bash
# Watch all namespaces
watch kubectl get pods --all-namespaces

# Check specific applications
kubectl get pods -n traefik-system      # Ingress controller
kubectl get pods -n cert-manager        # TLS certificates
kubectl get pods -n harbor-system       # Container registry
kubectl get pods -n longhorn-system     # Persistent storage
kubectl get pods -n monitoring          # Prometheus/Grafana
kubectl get pods -n loki-stack          # Logging
kubectl get pods -n tekton-pipelines    # CI/CD pipelines
kubectl get pods -n tekton-builds       # Build namespace

# Check Flux status
flux get all
```

### Phase 6: Post-Deployment Validation (5 minutes)

```bash
# 1. Verify DNS resolution
kubectl get svc -n traefik-system traefik
# Note the EXTERNAL-IP (from MetalLB)

# 2. Check DNS records point to cluster IP
dig +short sidapi.com
dig +short harbor.sidapi.com
dig +short builds.sidapi.com
# Should all point to MetalLB IP

# 3. Verify TLS certificates
kubectl get certificates --all-namespaces
# All should show READY=True

# 4. Test application access
curl -k https://harbor.sidapi.com   # Harbor UI
curl -k https://builds.sidapi.com   # Tekton Dashboard
curl -k https://sidapi.com          # Any deployed apps

# 5. Verify Longhorn storage
kubectl get pvc --all-namespaces
# All should be Bound

# 6. Test Harbor login
docker login harbor.sidapi.com
# Use credentials from: clusters/aries/apps/harbor/harbor-secrets.secret.enc.yaml

# 7. Verify Tekton webhooks
kubectl get eventlistener -n tekton-builds
# Should see github-webhook-listener running
```

## Critical Files to Back Up

Keep offline backups of these files:

### 1. SOPS Age Private Key
```bash
~/.config/sops/age/keys.txt
```
**⚠️ MOST CRITICAL** - Without this, you must recreate all secrets manually.

### 2. SSH Keys
```bash
~/.ssh/homelab_ed25519
~/.ssh/homelab_ed25519.pub
```

### 3. Git Repositories
```bash
# Already backed up on GitHub:
# - github.com/bsidio/aries-homelab (Ansible)
# - github.com/bsidio/aries-cluster-config (GitOps)
```

### 4. Credentials Documentation
Keep a secure record of:
- GitHub Personal Access Token (for Flux)
- GitHub Personal Access Token (for Tekton)
- Harbor admin password
- Tekton dashboard credentials
- Longhorn R2 backup credentials

## What Gets Restored Automatically

Once Flux is running, it automatically restores:

✅ **Infrastructure**:
- Traefik ingress with MetalLB
- cert-manager with Let's Encrypt
- external-dns configuration

✅ **Storage**:
- Longhorn distributed storage
- Longhorn backups to Cloudflare R2

✅ **Security**:
- Harbor container registry
- All TLS certificates
- All encrypted secrets (via SOPS)

✅ **Observability**:
- Prometheus monitoring
- Grafana dashboards
- Loki logging stack

✅ **CI/CD**:
- Tekton pipelines and tasks
- GitHub webhook listeners
- Harbor integration
- Tekton Dashboard UI

✅ **Applications**:
- Any applications in GitOps repo
- Their services and ingress routes
- Their persistent storage claims

## What Requires Manual Intervention

❌ **External Dependencies**:

1. **DNS Records**: Must point to new MetalLB IP
   - sidapi.com → <METALLB_IP>
   - *.sidapi.com → <METALLB_IP>

2. **GitHub Webhooks**: Must point to new IP
   - Update webhook URL if public IP changed
   - Located at: GitHub repo → Settings → Webhooks

3. **Let's Encrypt Rate Limits**:
   - If recovering multiple times in a week
   - May need to use staging certificates temporarily

4. **Longhorn Backup Restoration**:
   - If recovering from R2 backups
   - Must manually restore PV data from R2

## Testing Disaster Recovery

**Recommended**: Test this process quarterly on a separate cluster or VM environment.

```bash
# Destroy cluster (DANGEROUS - only for testing!)
# ansible-playbook -i inventories/prod/hosts.ini playbooks/destroy-cluster.yml

# Then follow recovery steps above
```

## Recovery Scenarios

### Scenario 1: Single Node Failure
- **RTO**: ~5 minutes
- **Action**: Node self-heals or drain/replace node
- **Data Loss**: None (HA cluster)

### Scenario 2: Complete Cluster Failure (All Nodes Down)
- **RTO**: ~30-45 minutes (full recovery)
- **Action**: Follow all phases above
- **Data Loss**: Depends on Longhorn backup age

### Scenario 3: Data Corruption
- **RTO**: ~15 minutes
- **Action**: Restore Longhorn volumes from R2 backup
- **Data Loss**: Since last backup (configure backup frequency)

### Scenario 4: GitOps Repository Deleted
- **RTO**: ~5 minutes
- **Action**: Restore from Git provider backup or local clone
- **Data Loss**: None (multiple copies)

### Scenario 5: Lost SOPS Key
- **RTO**: Several hours
- **Action**: Manually recreate all secrets
- **Data Loss**: Must reconfigure all credentials

## Improvement Recommendations

To achieve true "few clicks" recovery:

### Option 1: Create Recovery Playbook
```bash
# Create: playbooks/disaster-recovery.yml
# This would:
# 1. Bootstrap nodes
# 2. Install K3s
# 3. Install Flux
# 4. Wait for all applications
#
# Single command recovery:
# ansible-playbook -i inventories/prod/hosts.ini playbooks/disaster-recovery.yml
```

### Option 2: Automated Backup Script
```bash
# Create: scripts/backup-cluster-state.sh
# This would backup:
# - SOPS Age key (encrypted)
# - Kubeconfig
# - Cluster state snapshot
# - Run daily via cron
```

### Option 3: Infrastructure as Code
Consider adding:
- Terraform for DNS records
- Terraform for GitHub webhook configuration
- Ansible playbook for Flux bootstrap

## Emergency Contacts

- **Cluster Operator**: [Your contact info]
- **DNS Provider**: Cloudflare
- **Container Registry**: Harbor (self-hosted)
- **Backup Storage**: Cloudflare R2

## Last Updated

2025-10-14 - Initial disaster recovery documentation

## Recovery Checklist

Use this checklist during actual recovery:

- [ ] SOPS Age key restored to `~/.config/sops/age/keys.txt`
- [ ] SSH access to all nodes verified
- [ ] Node bootstrap completed (`bootstrap.yml`)
- [ ] K3s HA cluster installed (`k3s-ha.yml`)
- [ ] Kubeconfig fetched and configured
- [ ] All nodes showing Ready
- [ ] Flux bootstrapped to GitHub repository
- [ ] Flux controllers running in flux-system namespace
- [ ] Flux reconciled aries-cluster-config repository
- [ ] Traefik deployed and LoadBalancer has external IP
- [ ] cert-manager deployed and ready
- [ ] Harbor deployed and accessible
- [ ] Longhorn deployed with healthy replicas
- [ ] Monitoring stack deployed (Prometheus/Grafana)
- [ ] Tekton pipelines deployed
- [ ] All certificates showing READY=True
- [ ] DNS records updated to new MetalLB IP
- [ ] GitHub webhooks updated to new IP (if changed)
- [ ] Harbor login successful
- [ ] Test application deployment via Tekton
- [ ] All PVCs bound and data accessible
- [ ] Backup verification from Longhorn R2

**Recovery Complete!** 🎉
