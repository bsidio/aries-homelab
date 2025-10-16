# Aries Homelab - Session Memory

## Infrastructure Overview

**Kubernetes Cluster**: Aries homelab cluster
**Config Location**: `/Users/sb/Documents/aries-homelab/homelab-ansible`
**Kubeconfig**: `/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig`
**GitOps**: FluxCD managing cluster from aries-cluster-config

## Key Repositories

### 1. aries-cluster-config
- **URL**: https://github.com/bsidio/aries-cluster-config
- **Location**: `/Users/sb/Documents/git/aries-cluster-config`
- **Purpose**: Cluster GitOps configuration (FluxCD)
- **Branch**: main
- **Structure**:
  ```
  clusters/aries/
  ├── apps/
  │   ├── monitoring/          # kube-prometheus-stack + Grafana dashboards
  │   ├── tekton/              # CI/CD pipelines
  │   └── ...
  └── infrastructure/
  ```

### 2. aries-grafana
- **URL**: https://github.com/bsidio/aries-grafana
- **Location**: `/Users/sb/Documents/git/aries-grafana`
- **Purpose**: Grafana dashboard management (GitOps)
- **Branch**: main
- **See**: `/Users/sb/Documents/git/aries-grafana/MEMORY.md` for details

### 3. docker-compose-test (Sample App)
- **URL**: Not specified
- **Location**: `/Users/sb/Documents/git/docker-compose-test`
- **Purpose**: Sample application with Tekton CI/CD
- **Components**: frontend (Next.js), api (Node.js), postgres, redis
- **Deployed URL**: https://sample-app.sidapi.com

### 4. homelab-ansible
- **Location**: `/Users/sb/Documents/aries-homelab/homelab-ansible`
- **Purpose**: Ansible playbooks for cluster setup
- **Kubeconfig**: `playbooks/artifacts/kubeconfig`

## Environment Variables

```bash
# Kubernetes
export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig

# SOPS Encryption
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

## Cluster Services

### Monitoring Stack
- **Helm Chart**: kube-prometheus-stack
- **Namespace**: monitoring
- **Grafana URL**: https://monitoring.sidapi.com
- **Components**: Prometheus, Grafana, Alertmanager
- **Dashboards**: 25 built-in + custom from Git

### CI/CD (Tekton)
- **Namespace**: tekton
- **Pipelines**: Docker build, Kompose conversion, secret injection
- **Tasks**: generate-ingress, inject-secrets, build-docker-image

### Sample Application
- **Namespace**: sample-app
- **URL**: https://sample-app.sidapi.com
- **Components**:
  - frontend: Next.js on port 80
  - api: Node.js on port 3000
  - postgres: PostgreSQL with persistent storage
  - redis: Redis with authentication

## FluxCD Configuration

### Main System
- **GitRepository**: flux-system
- **URL**: https://github.com/bsidio/aries-cluster-config
- **Interval**: Auto-sync
- **Path**: clusters/aries/

### Grafana Dashboards
- **GitRepository**: grafana-dashboards
- **URL**: ssh://git@github.com/bsidio/aries-grafana
- **Interval**: 1 minute
- **Path**: kustomize/production
- **Secret**: grafana-dashboards-deploy-key (SOPS-encrypted)

## SOPS Encryption

### Configuration
- **Config File**: `/Users/sb/Documents/git/aries-cluster-config/.sops.yaml`
- **Pattern**: `*.secret.enc.yaml`
- **Key Type**: AGE
- **Key Location**: `~/.config/sops/age/keys.txt`
- **Public Key**: `age175xnehnljmet4v6fhj6sxguehgjz4ufxxsvmv5t9ztf9tggxlprsjt8vd7`

### Usage
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# Encrypt a secret
sops --encrypt --in-place file.secret.enc.yaml

# Decrypt to stdout
sops --decrypt file.secret.enc.yaml

# Edit encrypted file
sops file.secret.enc.yaml
```

## Recent Work Summary

### Session: Grafana Dashboard GitOps (2025-10-15)

**Goal**: Create automated GitOps workflow for Grafana dashboards

**Achievements**:
1. ✅ Created aries-grafana repository with Kustomize configuration
2. ✅ Configured FluxCD GitRepository and Kustomization
3. ✅ Created SOPS-encrypted SSH deploy key
4. ✅ Built pre-commit hook for automatic kustomization.yaml generation
5. ✅ Tested and verified dashboard deployment end-to-end
6. ✅ Documented workflow in README, QUICKSTART, SETUP, MEMORY

**Workflow**: Drop JSON → Git commit (hook runs) → Push → FluxCD syncs (1-6 min) → Dashboard appears



## Common Commands

### FluxCD
```bash
# Set kubeconfig
export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig

# Check status
flux get sources git
flux get kustomizations

# Force reconciliation
flux reconcile kustomization flux-system --with-source
flux reconcile source git grafana-dashboards
flux reconcile kustomization grafana-dashboards
```

### Kubernetes
```bash
# Pods
kubectl get pods -A
kubectl get pods -n monitoring
kubectl get pods -n sample-app
kubectl get pods -n tekton

# Logs
kubectl logs -n <namespace> <pod-name>
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard

# ConfigMaps
kubectl get configmaps -n monitoring -l grafana_dashboard=1

# Secrets (encrypted with SOPS)
kubectl get secrets -n flux-system
```

### Git Workflows

**aries-cluster-config** (Cluster Configuration):
```bash
cd /Users/sb/Documents/git/aries-cluster-config
git pull
# Make changes to clusters/aries/apps/
git add .
git commit -m "feat: description"
git push
# FluxCD auto-applies within minutes
```

**aries-grafana** (Dashboard Management):
```bash
cd /Users/sb/Documents/git/aries-grafana
# Add dashboard JSON to kustomize/base/dashboards/
git add kustomize/base/dashboards/new-dashboard.json
git commit -m "feat: add new-dashboard"  # Pre-commit hook runs automatically
git push
# Dashboard appears in Grafana in 1-6 minutes
```

## Troubleshooting

### FluxCD Not Syncing
```bash
# Check GitRepository status
flux get sources git <name>

# Check for errors
flux get kustomizations <name>

# Force reconciliation
flux reconcile source git <name>
flux reconcile kustomization <name>
```

### Pod Issues
```bash
# Check pod status
kubectl get pods -n <namespace>

# Describe pod
kubectl describe pod -n <namespace> <pod-name>

# View logs
kubectl logs -n <namespace> <pod-name>

# Restart deployment
kubectl rollout restart deployment/<name> -n <namespace>
```

### SOPS Decryption Issues
```bash
# Verify AGE key file exists
ls -la ~/.config/sops/age/keys.txt

# Set environment variable
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# Test decryption
sops --decrypt clusters/aries/apps/monitoring/grafana-dashboards-deploy-key.secret.enc.yaml
```

### Certificate/Ingress Issues
```bash
# Check cert-manager certificates
kubectl get certificates -A

# Check Traefik IngressRoutes
kubectl get ingressroute -A

# Check cert-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
```

## URLs & Access

- **Grafana**: https://monitoring.sidapi.com
- **Sample App**: https://sample-app.sidapi.com
- **GitHub - Cluster Config**: https://github.com/bsidio/aries-cluster-config
- **GitHub - Grafana Dashboards**: https://github.com/bsidio/aries-grafana

## Key Learnings

1. **Kubernetes Service Discovery**: Auto-injects environment variables like `POSTGRES_PORT`, `REDIS_HOST` that can collide with custom variables. Solution: Use unique names like `DB_HOST`, `CACHE_HOST`.

2. **Kustomize Security**: Files must be within or below the kustomization directory. Cannot use `../../` paths.

3. **FluxCD Polling**: GitRepository resources poll on intervals (default 1m). Use `flux reconcile` to force immediate sync.

4. **SOPS Naming**: Files must match `.sops.yaml` pattern (e.g., `*.secret.enc.yaml`) to be encrypted.

5. **Pre-commit Hooks**: Powerful automation tool. Install with `git config core.hooksPath .githooks`.

6. **Grafana Sidecar**: Watches ConfigMaps with specific labels. No need to restart Grafana when adding dashboards.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                     GitHub                              │
│  ┌──────────────────┐  ┌─────────────────────────┐    │
│  │ aries-cluster-   │  │ aries-grafana           │    │
│  │ config           │  │ (dashboards)            │    │
│  └────────┬─────────┘  └──────────┬──────────────┘    │
└───────────┼────────────────────────┼───────────────────┘
            │                        │
            │ Poll every 1m          │ Poll every 1m
            ▼                        ▼
┌─────────────────────────────────────────────────────────┐
│              FluxCD (in Kubernetes)                     │
│  ┌──────────────┐            ┌──────────────────┐      │
│  │ flux-system  │            │ grafana-         │      │
│  │ GitRepository│            │ dashboards       │      │
│  │ Kustomization│            │ GitRepository    │      │
│  └──────┬───────┘            │ Kustomization    │      │
│         │                    └────────┬─────────┘      │
│         │                             │                 │
│         ▼                             ▼                 │
│  ┌──────────────────────┐   ┌──────────────────┐      │
│  │ Kubernetes Resources │   │ ConfigMaps       │      │
│  │ (apps, infra)        │   │ (dashboards)     │      │
│  └──────────────────────┘   └────────┬─────────┘      │
│                                       │                 │
│                                       ▼                 │
│                              ┌──────────────────┐      │
│                              │ Grafana Sidecar  │      │
│                              │ (k8s-sidecar)    │      │
│                              └────────┬─────────┘      │
│                                       │                 │
│                                       ▼                 │
│                              ┌──────────────────┐      │
│                              │ Grafana UI       │      │
│                              └──────────────────┘      │
└─────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                          https://monitoring.sidapi.com
```

## Additional Working Directories

Per session context, you also work with:
- `/tmp` - Temporary files
- `/Users/sb/Documents/git/aries-grafana/kustomize/production`
- `/Users/sb/Documents/git/aries-grafana/dashboards`
- `/Users/sb/Documents/git/aries-grafana/.github/workflows`

## Project Status

**Overall**: ✅ Operational
**Sample App**: ✅ Deployed and accessible
**Monitoring**: ✅ Grafana dashboard GitOps fully automated
**CI/CD**: ✅ Tekton pipelines working
**GitOps**: ✅ FluxCD syncing all repositories

## Last Updated

Date: 2025-10-15
Session: Grafana Dashboard GitOps Automation
