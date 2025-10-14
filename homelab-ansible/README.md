# Aries Homelab - K3s HA Cluster

This repository contains Ansible playbooks to bootstrap and manage a 3-node HA K3s cluster for the Aries homelab.

## Cluster Information

- **Cluster Name**: Aries
- **Nodes**:
  - `aries1` (10.0.0.233) - Control plane, etcd, master
  - `aries2` (10.0.0.119) - Control plane, etcd, master
  - `aries3` (10.0.0.140) - Control plane, etcd, master
- **K3s Version**: v1.29.9+k3s1
- **Network Configuration**:
  - Cluster CIDR: 10.42.0.0/16
  - Service CIDR: 10.43.0.0/16
  - ServiceLB: Disabled (ready for MetalLB)

## Prerequisites

- SSH access to all nodes with `sid` user (for initial bootstrap)
- Ansible installed on your local machine
- SSH key pair (`~/.ssh/homelab_ed25519`)

## Directory Structure

```
homelab-ansible/
├── inventories/
│   └── prod/
│       └── hosts.ini       # Inventory file with Aries nodes
├── group_vars/
│   ├── all.yml            # Common variables for all hosts
│   └── aries.yml          # K3s-specific variables
├── playbooks/
│   ├── bootstrap.yml       # Initial node configuration
│   ├── k3s-ha.yml         # K3s HA installation
│   └── fetch-kubeconfig.yml # Fetch kubeconfig locally
└── artifacts/             # Runtime artifacts (created automatically)
    ├── k3s_node_token.txt # Cluster join token
    └── kubeconfig         # Cluster kubeconfig
```

## Installation Steps

### 1. Bootstrap the Nodes

First-time setup to configure the nodes with the `ubuntu` user and base packages:

```bash
cd homelab-ansible
ansible-playbook -i inventories/prod/hosts.ini playbooks/bootstrap.yml -u sid -k -K
```

This will:
- Create the `ubuntu` user with sudo privileges
- Install base packages (curl, vim, git, python3, etc.)
- Configure iSCSI services for Longhorn storage
- Apply system tuning for Kubernetes
- Set up kernel modules for K3s

### 2. Install K3s HA Cluster

After bootstrap, install K3s in HA mode:

```bash
ansible-playbook -i inventories/prod/hosts.ini playbooks/k3s-ha.yml
```

This will:
- Initialize K3s on aries1 with cluster-init
- Join aries2 and aries3 as additional control plane nodes
- Create symlinks for kubectl on all nodes

### 3. Fetch Kubeconfig

Get the kubeconfig file for local cluster management:

```bash
ansible-playbook -i inventories/prod/hosts.ini playbooks/fetch-kubeconfig.yml
```

The kubeconfig will be saved to `playbooks/artifacts/kubeconfig`

## Using kubectl

### Option 1: Direct Usage
```bash
export KUBECONFIG=playbooks/artifacts/kubeconfig
kubectl get nodes
```

### Option 2: Copy to Standard Location
```bash
mkdir -p ~/.kube
cp playbooks/artifacts/kubeconfig ~/.kube/config-aries
export KUBECONFIG=~/.kube/config-aries
kubectl get nodes
```

### Option 3: Add to Shell Profile
Add to your `~/.bashrc` or `~/.zshrc`:
```bash
export KUBECONFIG=~/.kube/config-aries
```

## Verifying the Cluster

Check cluster status:
```bash
kubectl get nodes
kubectl get pods -A
kubectl cluster-info
```

Expected output:
```
NAME     STATUS   ROLES                       AGE   VERSION
aries1   Ready    control-plane,etcd,master   XXm   v1.29.9+k3s1
aries2   Ready    control-plane,etcd,master   XXm   v1.29.9+k3s1
aries3   Ready    control-plane,etcd,master   XXm   v1.29.9+k3s1
```

## Configuration Files

### group_vars/aries.yml
Contains K3s-specific configuration:
- K3s version
- Primary node IP
- Network CIDRs
- Disabled components

### group_vars/all.yml
Contains common configuration:
- Admin user settings
- Base packages list
- System tuning parameters

## SSH Access

After bootstrap, you can SSH to any node using:
```bash
ssh ubuntu@<node-ip>
```

The `ubuntu` user has passwordless sudo configured.

## Troubleshooting

### Variable Loading Issues
Ensure you run playbooks from the `homelab-ansible` directory so Ansible can find the group_vars.

### SSH Connection Issues
If you see SSH config errors, ensure your `~/.ssh/config` is compatible with the SSH version:
```bash
export PATH="/usr/bin:$PATH"
```

### Network Connectivity
Verify you can reach the nodes:
```bash
ping 10.0.0.233
curl -k https://10.0.0.233:6443/livez
```

## MetalLB Load Balancer

MetalLB is installed and configured to provide LoadBalancer services for your cluster.

### Configuration
- **IP Pool**: 10.0.0.200-10.0.0.220
- **Mode**: Layer 2 (L2Advertisement)
- **Namespace**: metallb-system

### Installation
```bash
ansible-playbook -i inventories/prod/hosts.ini playbooks/metallb.yml
```

### Testing MetalLB
Create a test service:
```bash
kubectl create deployment nginx --image=nginx --replicas=2
kubectl expose deployment nginx --port=80 --type=LoadBalancer
kubectl get svc nginx
```

The service will be assigned an IP from the pool (e.g., 10.0.0.200).

### Verify MetalLB Status
```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspools
kubectl -n metallb-system get l2advertisements
```

## Cluster Architecture

### Node Roles
All three nodes serve as **both control plane AND worker nodes**:
- Control plane components: API server, scheduler, controller manager, etcd
- Worker components: Can run application workloads
- No taints preventing workload scheduling

This is an efficient setup for a homelab:
- Maximum resource utilization (all nodes run workloads)
- High availability (3 control planes for redundancy)
- Simplified management (no dedicated worker nodes needed)

### Network Services
- **K3s**: Lightweight Kubernetes (ServiceLB and Traefik disabled)
- **MetalLB**: Provides LoadBalancer services with L2 mode
- **IP Range**: 10.0.0.200-220 reserved for LoadBalancer services

## FluxCD GitOps

FluxCD is installed to provide GitOps continuous deployment from your cluster configuration repository.

### Repository Structure
The cluster configuration is managed in a separate private repository: `aries-cluster-config`

```
aries-cluster-config/
├── clusters/
│   └── aries/
│       ├── kustomization.yaml
│       └── core/
│           ├── kustomization.yaml
│           ├── namespaces.yaml
│           └── metallb/
│               ├── kustomization.yaml
│               └── pool.yaml
└── .gitignore
```

### Installation
FluxCD was bootstrapped to watch the `clusters/aries` path in your private GitHub repository:

```bash
flux bootstrap github \
  --owner=bsidio \
  --repository=aries-cluster-config \
  --branch=main \
  --path=clusters/aries \
  --personal
```

### Managing Infrastructure via GitOps

#### Current GitOps-Managed Components:
- ✅ **MetalLB**: Load balancer with IP pool configuration
- ✅ **Longhorn**: Distributed storage with Cloudflare R2 backups
- ✅ **Namespaces**: Core system namespaces
- ✅ **SOPS Encryption**: Secure secret management with AGE

#### Adding New Components:
1. Add manifests to the appropriate directory in `aries-cluster-config`
2. Update kustomization.yaml files to include new resources
3. Commit and push changes
4. Flux automatically syncs within ~5 minutes

#### Monitoring GitOps:
```bash
# Check Flux system status
kubectl -n flux-system get deployments,pods

# Check Git repository sync status
kubectl -n flux-system get gitrepositories

# Check kustomization reconciliation
kubectl -n flux-system get kustomizations

# Force reconciliation
flux reconcile kustomization flux-system
```

### GitOps Workflow

1. **Make Changes**: Edit manifests in `aries-cluster-config` repo
2. **Commit & Push**: `git add . && git commit -m "feat: add new component" && git push`
3. **Auto-Sync**: Flux detects changes and applies them to the cluster
4. **Verify**: Check deployment status with kubectl

## Longhorn Distributed Storage

Longhorn provides distributed block storage with automatic backups to Cloudflare R2.

### Configuration
- **Default StorageClass**: `longhorn` (2 replicas for HA)
- **Backup Target**: Cloudflare R2 bucket `aries`
- **Backup Schedule**: Daily at 3 AM (retains 7 backups)
- **Data Path**: `/var/lib/longhorn` on each node

### Monitoring Longhorn
```bash
# Check Longhorn pods
kubectl -n longhorn-system get pods

# Verify default StorageClass
kubectl get storageclass

# Check Longhorn volumes
kubectl get pv,pvc -A

# Access Longhorn UI (port-forward)
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Browse to http://localhost:8080
```

### Secret Management with SOPS
Sensitive data (like R2 credentials) is encrypted using SOPS with AGE encryption:

- **Encryption Key**: Stored in `~/.config/sops/age/keys.txt`
- **SOPS Config**: `.sops.yaml` in cluster config repo
- **Encrypted Files**: `*.secret.enc.yaml` pattern

#### Encrypting New Secrets:
```bash
# Create secret file
cat > new-secret.secret.enc.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
stringData:
  key: "value"
EOF

# Encrypt with SOPS
sops -e -i new-secret.secret.enc.yaml
```

### Security Note
The GitHub Personal Access Token used for Flux requires these permissions:
- `repo` (full repository access)
- `admin:repo_hook` (repository hooks)
- `admin:public_key` (deploy keys)

## Repository Structure

Your homelab uses a **dual-repository approach**:

### 1. Ansible Bootstrap Repository (`aries-homelab`)
- **Purpose**: One-time cluster bootstrap and infrastructure setup
- **Location**: `/Users/sb/Documents/aries-homelab/homelab-ansible`
- **Contains**: Node configuration, K3s installation, initial MetalLB setup

### 2. GitOps Configuration Repository (`aries-cluster-config`)
- **Purpose**: Ongoing cluster management via GitOps
- **Location**: `/Users/sb/Documents/git/aries-cluster-config`
- **Contains**: Application deployments, configurations, encrypted secrets

```
aries-cluster-config/
├── .sops.yaml                    # SOPS encryption configuration
├── clusters/aries/
│   ├── kustomization.yaml       # Main cluster configuration
│   ├── core/                    # Core infrastructure
│   │   ├── namespaces.yaml
│   │   └── metallb/            # LoadBalancer configuration
│   └── apps/                    # Applications
│       └── longhorn/           # Distributed storage
│           ├── helmrelease.yaml     # Longhorn Helm chart
│           ├── s3-credentials.secret.enc.yaml  # Encrypted R2 credentials
│           └── recurring-jobs.yaml  # Backup schedule
```

## Documentation Links

### 📚 **Complete Documentation**
- **[GitOps Repository Documentation](https://github.com/bsidio/aries-cluster-config)** - Complete guide for ongoing cluster management
- **This README** - Bootstrap and initial setup procedures

### 🔗 **Repository Links**
- **Bootstrap Repository**: `/Users/sb/Documents/aries-homelab/homelab-ansible` (This location)
- **GitOps Repository**: `/Users/sb/Documents/git/aries-cluster-config` ([GitHub](https://github.com/bsidio/aries-cluster-config))

## Next Steps

- ✅ ~~Install MetalLB for LoadBalancer services~~ (Complete)
- ✅ ~~Install FluxCD for GitOps~~ (Complete)
- ✅ ~~Deploy Longhorn for distributed storage~~ (Complete)
- ✅ ~~Set up SOPS secret encryption~~ (Complete)
- Set up Ingress controller (nginx) (via GitOps)
- Deploy monitoring stack (Prometheus/Grafana) (via GitOps)
- Add cert-manager for TLS certificates (via GitOps)
- Deploy applications using persistent volumes
