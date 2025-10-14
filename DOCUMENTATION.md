# Aries Homelab Cluster Documentation

**Last Updated:** October 13, 2025
**Cluster Name:** Aries
**K3s Version:** Latest stable
**GitOps:** FluxCD v2

---

## Table of Contents

1. [Cluster Overview](#cluster-overview)
2. [Infrastructure](#infrastructure)
3. [Networking](#networking)
4. [Storage](#storage)
5. [GitOps & Automation](#gitops--automation)
6. [Monitoring](#monitoring)
7. [Backup & Recovery](#backup--recovery)
8. [Security](#security)
9. [Troubleshooting](#troubleshooting)
10. [Maintenance Procedures](#maintenance-procedures)

---

## Cluster Overview

### Architecture
- **Type:** 3-node K3s HA cluster
- **Configuration:** Embedded etcd (no external database)
- **Control Plane:** Distributed across all 3 nodes
- **Management:** GitOps with FluxCD

### Key Features
- ✅ High Availability (HA) configuration
- ✅ Automated SSL certificate management
- ✅ Automatic DNS record creation
- ✅ Distributed block storage with replication
- ✅ Automated backups to Cloudflare R2
- ✅ Comprehensive monitoring stack

---

## Infrastructure

### Cluster Nodes

| Node | IP Address | Role | Hostname |
|------|------------|------|----------|
| aries1 | 10.0.0.10 | server | aries1.local |
| aries2 | 10.0.0.11 | server | aries2.local |
| aries3 | 10.0.0.12 | server | aries3.local |

### Access Credentials

**SSH Access:**
```bash
ssh ubuntu@aries1.local
ssh ubuntu@aries2.local
ssh ubuntu@aries3.local
```

**Kubernetes Access:**
```bash
# From your Mac
export KUBECONFIG=~/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig
kubectl get nodes

# Or if using default kubeconfig
kubectl --kubeconfig ~/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig get nodes
```

---

## Networking

### MetalLB Load Balancer

**IP Pool:** `10.0.0.200 - 10.0.0.220` (21 IPs available)

**Current Assignments:**
- `10.0.0.200` - nginx service (legacy)
- `10.0.0.201` - Traefik ingress controller

**Configuration Location:**
```
~/Documents/git/aries-cluster-config/clusters/aries/infrastructure/metallb/
```

### Ingress Controller

**Traefik v2**
- **Type:** LoadBalancer
- **External IP:** 10.0.0.201
- **Ports:** 80 (HTTP), 443 (HTTPS)
- **Features:**
  - Automatic HTTP → HTTPS redirect
  - Let's Encrypt SSL integration
  - IngressRoute support

**Access Traefik:**
```bash
kubectl -n traefik get svc
kubectl -n traefik get pods
```

### DNS Management

**External-DNS with Cloudflare**
- **Domain:** sidapi.com
- **Provider:** Cloudflare DNS
- **Authentication:** API Token (stored in SOPS-encrypted secret)
- **Auto-creates:** DNS records for ingresses

**How it works:**
1. Create ingress with annotation:
   ```yaml
   annotations:
     external-dns.alpha.kubernetes.io/hostname: myapp.sidapi.com
   ```
2. External-DNS automatically creates DNS record
3. Points to Traefik LoadBalancer IP (10.0.0.201)

### Port Forwarding Requirements

**UniFi/Router Configuration:**
- **Port 443** → `10.0.0.201:443` (HTTPS)
- **Optional:** Port 80 → `10.0.0.201:80` (HTTP, redirects to HTTPS)

---

## Storage

### Longhorn Distributed Storage

**Configuration:**
- **Replicas:** 3 (data replicated across all nodes)
- **Default Storage Class:** longhorn
- **UI Access:** Port-forward required (see below)

**Longhorn UI Access:**
```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Access: http://localhost:8080
```

**Storage Classes:**
```bash
kubectl get storageclass
# NAME                 PROVISIONER          RECLAIMPOLICY
# longhorn (default)   driver.longhorn.io   Delete
```

### Backup Configuration

**Backup Target:** Cloudflare R2 S3-compatible storage
- **Bucket:** aries
- **Endpoint:** f3970c61035f6ddfa3e9c904126e0a19.r2.cloudflarestorage.com
- **Credentials:** Stored in `longhorn-r2-backups` secret (SOPS encrypted)

**Recurring Backup:**
- **Name:** aries-backup
- **Schedule:** 3:00 AM daily (cron: `0 3 * * *`)
- **Retention:** 7 backups
- **Target Group:** default

**Backup Setup:**
1. Access Longhorn UI: http://localhost:8080
2. Navigate to: Volume → Select volume
3. Update Recurring Jobs: Assign to `default` group
4. Backup runs automatically at 3 AM

**Important Volumes to Backup:**
- ✅ Prometheus (50GB) - Metrics history
- ✅ Grafana (10GB) - Custom dashboards
- ⚪ AlertManager (10GB) - Optional

---

## GitOps & Automation

### FluxCD Configuration

**Git Repository:** https://github.com/bsidio/aries-cluster-config

**Directory Structure:**
```
aries-cluster-config/
├── clusters/
│   └── aries/
│       ├── flux-system/          # FluxCD bootstrap
│       ├── infrastructure/       # Core services
│       │   └── metallb/
│       └── apps/                 # Applications
│           ├── traefik/          # Ingress controller
│           ├── external-dns/     # DNS automation
│           ├── cert-manager/     # SSL certificates
│           ├── longhorn/         # Storage
│           └── monitoring/       # Monitoring stack
```

**FluxCD Status:**
```bash
# Check FluxCD status
flux check

# Check kustomizations
kubectl -n flux-system get kustomizations

# Force reconciliation
flux reconcile kustomization flux-system --with-source

# Suspend/Resume
flux suspend kustomization flux-system
flux resume kustomization flux-system
```

### SSL Certificate Automation

**Cert-Manager with Let's Encrypt**
- **Issuer:** letsencrypt-prod (production)
- **Challenge:** DNS-01 via Cloudflare
- **Auto-renewal:** 30 days before expiry

**ClusterIssuers:**
- `letsencrypt-prod` - Production certificates
- `letsencrypt-staging` - Testing (use for development)

**Usage Example:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/hostname: myapp.sidapi.com
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/redirect-scheme: https
spec:
  tls:
  - hosts:
    - myapp.sidapi.com
    secretName: myapp-tls
  rules:
  - host: myapp.sidapi.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
```

**Result:** Automatic DNS + SSL + HTTPS redirect!

---

## Monitoring

### Prometheus Stack

**Components:**
- **Prometheus:** Metrics collection and storage (50GB, 30-day retention)
- **Grafana:** Visualization and dashboards (10GB)
- **AlertManager:** Alert routing and management (10GB)
- **Node Exporter:** Node-level metrics
- **kube-state-metrics:** Kubernetes object metrics

**Access:**

**Via Domain (Preferred):**
- **URL:** https://monitoring.sidapi.com
- **Username:** admin
- **Password:** admin123 (⚠️ Change in production!)

**Via Port-Forward:**
```bash
# Grafana
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# Access: http://localhost:3000

# Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Access: http://localhost:9090

# AlertManager
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# Access: http://localhost:9093
```

**Pre-installed Dashboards:**
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace (Pods)
- Kubernetes / Compute Resources / Node (Pods)
- Node Exporter / Nodes
- Longhorn

**Storage:**
- All monitoring data backed up to R2 automatically
- 30-day metrics retention in Prometheus
- Persistent dashboards in Grafana

---

## Backup & Recovery

### Cluster Configuration Backup

**Backup Script Location:**
```bash
~/Documents/aries-homelab/backup-aries-cluster.sh
```

**Run Backup:**
```bash
~/Documents/aries-homelab/backup-aries-cluster.sh
```

**Backup Contents:**
- ✅ Kubernetes configuration (~/.kube)
- ✅ SSH keys
- ✅ SOPS/AGE encryption keys (CRITICAL!)
- ✅ Claude Code configuration
- ✅ Cluster information file
- ✅ Automated restore script

**Output:** `~/Desktop/aries-cluster-backup-YYYYMMDD_HHMMSS.tar.gz`

**⚠️ CRITICAL:** SOPS/AGE keys are required to decrypt secrets. Without them, you cannot access:
- R2 backup credentials
- Cloudflare API tokens
- Any encrypted secrets

### Restore Procedure

**From Configuration Backup:**
1. Extract backup: `tar -xzf aries-cluster-backup-*.tar.gz`
2. Run restore script: `cd aries-cluster-backup-* && ./restore.sh`
3. Clone Git repositories:
   ```bash
   git clone https://github.com/bsidio/aries-cluster-config ~/Documents/git/aries-cluster-config
   ```
4. Verify access: `kubectl get nodes`
5. Test SOPS: `sops -d clusters/aries/apps/longhorn/longhorn-r2-backups.secret.enc.yaml`

**From Longhorn Backup (Disaster Recovery):**
1. Rebuild K3s cluster using Ansible
2. Deploy Longhorn via FluxCD
3. Configure R2 backup target
4. Restore volumes from R2 backups via Longhorn UI

### Git Repository Backup

**Primary:** GitHub (https://github.com/bsidio/aries-cluster-config)

**Local Clone:**
```bash
~/Documents/git/aries-cluster-config/
```

**Backup Strategy:**
- All changes committed to GitHub
- Local clone serves as working copy
- Not included in Mac backup script (already on GitHub)

---

## Security

### Secrets Management

**SOPS with AGE Encryption**
- **Encryption:** age encryption
- **Key Location:** ~/.config/sops/age/keys.txt
- **Public Key:** Stored in .sops.yaml

**Encrypted Secrets:**
- Cloudflare API tokens (external-dns, cert-manager)
- Longhorn R2 backup credentials
- Grafana admin password (currently plaintext - should be encrypted)

**Encrypt a Secret:**
```bash
# Create secret file
cat > my-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: default
data:
  password: <BASE64_ENCODED_PASSWORD>
EOF

# Encrypt with SOPS
sops -e my-secret.yaml > my-secret.enc.yaml

# Decrypt for viewing
sops -d my-secret.enc.yaml
```

### Access Control

**Kubernetes RBAC:**
- Full cluster-admin access via kubeconfig
- No additional RBAC policies configured (single-user cluster)

**Node Access:**
- SSH key-based authentication
- User: ubuntu
- No password authentication

**Network Security:**
- Internal cluster network: 10.0.0.0/8
- External access only via Traefik ingress (10.0.0.201:443)
- No direct pod/service exposure

---

## Troubleshooting

### Common Issues

#### FluxCD Not Syncing

**Check Status:**
```bash
kubectl -n flux-system get kustomizations
```

**Force Reconciliation:**
```bash
flux reconcile kustomization flux-system --with-source
```

**Suspend and Resume:**
```bash
flux suspend kustomization flux-system
flux resume kustomization flux-system
```

#### Ingress 502 Bad Gateway

**Check Traefik:**
```bash
kubectl -n traefik get pods
kubectl -n traefik logs deployment/traefik
```

**Restart Traefik:**
```bash
kubectl -n traefik rollout restart deployment/traefik
```

**Check Backend Service:**
```bash
kubectl -n <namespace> get pods
kubectl -n <namespace> get svc
kubectl -n <namespace> describe ingress
```

#### Certificate Not Ready

**Check Certificate:**
```bash
kubectl -n <namespace> get certificates
kubectl -n <namespace> describe certificate <name>
```

**Check CertificateRequest:**
```bash
kubectl -n <namespace> get certificaterequests
kubectl -n <namespace> describe certificaterequest <name>
```

**Check ClusterIssuer:**
```bash
kubectl get clusterissuers
```

**Cert-Manager Logs:**
```bash
kubectl -n cert-manager logs deployment/cert-manager
```

#### Longhorn Backup Failed

**Check Backup Target:**
```bash
kubectl -n longhorn-system get settings backup-target -o yaml
```

**Check Backup Secret:**
```bash
kubectl -n longhorn-system get secret longhorn-r2-backups
```

**Test R2 Connectivity:**
Access Longhorn UI and check backup target status (should show "AVAILABLE")

**Check Volume Recurring Jobs:**
In Longhorn UI, verify volumes are assigned to "default" group

#### Pod Not Starting

**Check Pod Status:**
```bash
kubectl -n <namespace> get pods
kubectl -n <namespace> describe pod <pod-name>
kubectl -n <namespace> logs <pod-name>
```

**Check PVC:**
```bash
kubectl -n <namespace> get pvc
kubectl -n <namespace> describe pvc <pvc-name>
```

**Check Node Resources:**
```bash
kubectl top nodes
kubectl describe node <node-name>
```

### Useful Commands

**Cluster Health:**
```bash
# Node status
kubectl get nodes -o wide

# All resources
kubectl get all -A

# Events
kubectl get events -A --sort-by='.lastTimestamp'

# Resource usage
kubectl top nodes
kubectl top pods -A
```

**Longhorn:**
```bash
# Volume status
kubectl -n longhorn-system get volumes

# Backup status
kubectl -n longhorn-system get backups

# Recurring jobs
kubectl -n longhorn-system get recurringjobs
```

**FluxCD:**
```bash
# Check all Flux resources
flux get all

# Trace a resource
flux trace <resource-name>

# Check HelmReleases
kubectl -n <namespace> get helmreleases
```

---

## Maintenance Procedures

### Updating Applications

**Via GitOps (Recommended):**
1. Update version in `helmrelease.yaml`
2. Commit and push to GitHub
3. FluxCD automatically applies changes

**Example:**
```yaml
# Update Traefik version
spec:
  chart:
    spec:
      chart: traefik
      version: 31.x  # Changed from 30.x
```

### Upgrading K3s

**Using Ansible:**
```bash
cd ~/Documents/aries-homelab/homelab-ansible
ansible-playbook -i inventories/prod/hosts.ini playbooks/k3s-upgrade.yml
```

**Manual (per node):**
```bash
ssh aries1.local
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.5+k3s1 sh -s - server
```

### Adding a New Application

**Create Application Structure:**
```bash
cd ~/Documents/git/aries-cluster-config
mkdir -p clusters/aries/apps/myapp
```

**Create Files:**

1. **ns.yaml** - Namespace
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
```

2. **helmrepo.yaml** - Helm repository (if using Helm)
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: myapp-repo
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.example.com
```

3. **helmrelease.yaml** - Application deployment
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: myapp
  namespace: myapp
spec:
  interval: 5m
  chart:
    spec:
      chart: myapp
      version: 1.x
      sourceRef:
        kind: HelmRepository
        name: myapp-repo
        namespace: flux-system
  values:
    # Your configuration
```

4. **ingress.yaml** - Ingress with automatic SSL
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    external-dns.alpha.kubernetes.io/hostname: myapp.sidapi.com
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/redirect-scheme: https
spec:
  tls:
  - hosts:
    - myapp.sidapi.com
    secretName: myapp-tls
  rules:
  - host: myapp.sidapi.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
```

5. **kustomization.yaml** - Kustomize resources
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - helmrepo.yaml
  - helmrelease.yaml
  - ingress.yaml
```

**Add to Main Kustomization:**
```yaml
# clusters/aries/apps/kustomization.yaml
resources:
  - traefik
  - external-dns
  - cert-manager
  - longhorn
  - monitoring
  - myapp  # Add your new app
```

**Deploy:**
```bash
git add .
git commit -m "feat: add myapp deployment with automated SSL"
git push
```

**Verify:**
```bash
# Wait for FluxCD to sync (~1 minute)
flux get kustomizations

# Check deployment
kubectl -n myapp get all
kubectl -n myapp get ingress
kubectl -n myapp get certificates

# Access
# https://myapp.sidapi.com (automatic DNS + SSL!)
```

### Rotating Secrets

**SOPS-Encrypted Secrets:**
1. Decrypt existing secret:
   ```bash
   sops -d secret.enc.yaml > secret.yaml
   ```

2. Update values in secret.yaml

3. Re-encrypt:
   ```bash
   sops -e secret.yaml > secret.enc.yaml
   ```

4. Commit and push:
   ```bash
   git add secret.enc.yaml
   git commit -m "chore: rotate secret"
   git push
   ```

5. FluxCD will automatically apply

### Cluster Node Maintenance

**Drain Node:**
```bash
kubectl drain aries2.local --ignore-daemonsets --delete-emptydir-data
```

**Perform Maintenance:**
```bash
ssh aries2.local
sudo apt update && sudo apt upgrade -y
sudo reboot
```

**Uncordon Node:**
```bash
kubectl uncordon aries2.local
```

### Backup Validation

**Monthly Task:**
1. Run backup script
2. Verify backup archive created
3. Test extraction on separate machine (optional)
4. Store backup in secure location (cloud storage, external drive)

**Longhorn Backup Validation:**
1. Access Longhorn UI
2. Navigate to Backup section
3. Verify daily backups are being created
4. Check backup age (should have 7 daily backups)

---

## Quick Reference

### Essential URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | https://monitoring.sidapi.com | admin / admin123 |
| Longhorn UI | http://localhost:8080 (port-forward) | No auth |

### Essential Commands

```bash
# Cluster status
kubectl get nodes

# All pods
kubectl get pods -A

# FluxCD status
flux get all

# Force FluxCD sync
flux reconcile kustomization flux-system --with-source

# Longhorn UI
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80

# Grafana (local)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# Run backup
~/Documents/aries-homelab/backup-aries-cluster.sh

# SSH to nodes
ssh ubuntu@aries1.local
ssh ubuntu@aries2.local
ssh ubuntu@aries3.local
```

### Repository Locations

| Repository | Location |
|------------|----------|
| Cluster Config (Git) | ~/Documents/git/aries-cluster-config |
| Ansible Playbooks | ~/Documents/aries-homelab/homelab-ansible |
| Kubeconfig | ~/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig |
| SOPS Keys | ~/.config/sops/age/keys.txt |
| Backup Script | ~/Documents/aries-homelab/backup-aries-cluster.sh |

---

## Support & Resources

### Official Documentation
- **K3s:** https://docs.k3s.io/
- **FluxCD:** https://fluxcd.io/docs/
- **Longhorn:** https://longhorn.io/docs/
- **Traefik:** https://doc.traefik.io/traefik/
- **Cert-Manager:** https://cert-manager.io/docs/
- **Prometheus:** https://prometheus.io/docs/

### Git Repository
- **GitHub:** https://github.com/bsidio/aries-cluster-config

### Emergency Contacts
- **SOPS Keys:** CRITICAL - Store backup in secure location
- **Kubeconfig:** Required for cluster access
- **SSH Keys:** Required for node access

---

**Document Version:** 1.0
**Last Updated:** October 13, 2025
**Maintained By:** Aries Homelab