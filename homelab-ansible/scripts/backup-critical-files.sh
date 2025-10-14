#!/usr/bin/env bash
#
# Backup Critical Files for Disaster Recovery
#
# This script backs up all critical files needed to recover the cluster
# Run this script regularly and store backups in a secure location
#
# Usage:
#   ./scripts/backup-critical-files.sh [backup-directory]
#
# Default backup location: ~/aries-backups/$(date +%Y%m%d-%H%M%S)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default backup directory
DEFAULT_BACKUP_DIR="${HOME}/aries-backups/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${1:-${DEFAULT_BACKUP_DIR}}"

# Files and directories to backup
SOPS_KEY="${HOME}/.config/sops/age/keys.txt"
SSH_KEY="${HOME}/.ssh/homelab_ed25519"
SSH_KEY_PUB="${HOME}/.ssh/homelab_ed25519.pub"
KUBECONFIG_DIR="$(dirname "$0")/../playbooks/artifacts"
ANSIBLE_DIR="$(dirname "$0")/.."
GITOPS_REPO="${HOME}/Documents/git/aries-cluster-config"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Aries Cluster - Critical Files Backup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Backup directory: ${BACKUP_DIR}${NC}"
echo ""

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Function to backup file with verification
backup_file() {
    local src="$1"
    local dest="$2"
    local desc="$3"

    if [ -f "${src}" ]; then
        echo -e "${YELLOW}📄 Backing up ${desc}...${NC}"
        mkdir -p "$(dirname "${dest}")"
        cp "${src}" "${dest}"
        echo -e "${GREEN}   ✅ ${src} → ${dest}${NC}"
    else
        echo -e "${RED}   ❌ ${desc} not found at ${src}${NC}"
        echo -e "${RED}      WARNING: This file is critical for recovery!${NC}"
    fi
}

# Backup SOPS Age key (MOST CRITICAL)
echo -e "${BLUE}1. SOPS Age Private Key (CRITICAL)${NC}"
backup_file "${SOPS_KEY}" "${BACKUP_DIR}/sops-age-key.txt" "SOPS Age Key"
echo ""

# Backup SSH keys
echo -e "${BLUE}2. SSH Keys${NC}"
backup_file "${SSH_KEY}" "${BACKUP_DIR}/ssh/homelab_ed25519" "SSH Private Key"
backup_file "${SSH_KEY_PUB}" "${BACKUP_DIR}/ssh/homelab_ed25519.pub" "SSH Public Key"
echo ""

# Backup kubeconfig
echo -e "${BLUE}3. Kubeconfig${NC}"
if [ -f "${KUBECONFIG_DIR}/kubeconfig" ]; then
    backup_file "${KUBECONFIG_DIR}/kubeconfig" "${BACKUP_DIR}/kubeconfig" "Kubeconfig"
else
    echo -e "${YELLOW}   ⚠️  Kubeconfig not found (expected if cluster not running)${NC}"
fi
echo ""

# Backup Ansible inventory and variables
echo -e "${BLUE}4. Ansible Configuration${NC}"
if [ -d "${ANSIBLE_DIR}" ]; then
    echo -e "${YELLOW}📂 Backing up Ansible configuration...${NC}"
    cp -r "${ANSIBLE_DIR}/inventories" "${BACKUP_DIR}/ansible-inventories"
    cp -r "${ANSIBLE_DIR}/group_vars" "${BACKUP_DIR}/ansible-group_vars"
    [ -d "${ANSIBLE_DIR}/host_vars" ] && cp -r "${ANSIBLE_DIR}/host_vars" "${BACKUP_DIR}/ansible-host_vars"
    echo -e "${GREEN}   ✅ Ansible configuration backed up${NC}"
else
    echo -e "${RED}   ❌ Ansible directory not found${NC}"
fi
echo ""

# Create GitOps repository backup
echo -e "${BLUE}5. GitOps Repository${NC}"
if [ -d "${GITOPS_REPO}" ]; then
    echo -e "${YELLOW}📂 Creating GitOps repository archive...${NC}"
    cd "${GITOPS_REPO}"
    git bundle create "${BACKUP_DIR}/aries-cluster-config.bundle" --all
    echo -e "${GREEN}   ✅ GitOps repository bundled${NC}"
    echo -e "${GREEN}      To restore: git clone aries-cluster-config.bundle aries-cluster-config${NC}"
else
    echo -e "${YELLOW}   ⚠️  GitOps repository not found at ${GITOPS_REPO}${NC}"
    echo -e "${YELLOW}      (OK if repository is only on GitHub)${NC}"
fi
echo ""

# Create credentials documentation template
echo -e "${BLUE}6. Credentials Documentation${NC}"
cat > "${BACKUP_DIR}/CREDENTIALS-TEMPLATE.md" <<'EOF'
# Aries Cluster Credentials

⚠️ **SECURITY WARNING**: Store this file in a secure password manager, NOT in Git!

## GitHub Tokens

### Flux GitOps Token
- **Username**: bsidio
- **Token**: ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
- **Scope**: repo (full control of private repositories)
- **Used by**: FluxCD for GitOps automation

### Tekton CI/CD Token
- **Username**: bsidio
- **Token**: ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
- **Scope**: repo (full control of private repositories)
- **Used by**: Tekton for private repository cloning

## Harbor Container Registry

### Admin Credentials
- **URL**: https://harbor.sidapi.com
- **Username**: admin
- **Password**: XXXXXXXXXXXXXXXX

### Robot Account (optional)
- **Username**: robot$xxxxxxxx
- **Token**: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

## Tekton Dashboard

- **URL**: https://builds.sidapi.com
- **Username**: admin
- **Password**: XXXXXXXXXXXXXXXX

## Longhorn Backup Storage

### Cloudflare R2 Credentials
- **Endpoint**: https://xxxxxxxxxxxxxx.r2.cloudflarestorage.com
- **Access Key**: XXXXXXXXXXXXXXXXXXXXXXXX
- **Secret Key**: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
- **Bucket**: longhorn-backups

## Grafana Dashboard

- **URL**: https://grafana.sidapi.com (or via port-forward)
- **Username**: admin
- **Password**: prom-operator (default) or XXXXXXXX

## DNS Configuration

### Cloudflare
- **Zone**: sidapi.com
- **API Token**: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
- **Records**:
  - A: sidapi.com → <MetalLB IP>
  - A: *.sidapi.com → <MetalLB IP>

## Let's Encrypt

- **Email**: your-email@example.com
- **Issuer**: letsencrypt-prod
- **Rate Limits**: 50 certificates per week per domain

## SOPS Age Key

- **Public Key**: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
- **Private Key Location**: ~/.config/sops/age/keys.txt
- **Backup Location**: [Store securely - this backup includes it]

## Recovery Contact

- **Cluster Operator**: [Your name and contact]
- **Backup Location**: [Where these backups are stored]
- **Last Updated**: $(date +%Y-%m-%d)
EOF

echo -e "${YELLOW}📄 Created credentials template...${NC}"
echo -e "${GREEN}   ✅ ${BACKUP_DIR}/CREDENTIALS-TEMPLATE.md${NC}"
echo -e "${YELLOW}      Fill in actual values and store securely!${NC}"
echo ""

# Create recovery instructions
cat > "${BACKUP_DIR}/RECOVERY-QUICK-START.md" <<EOF
# Quick Start Recovery Guide

Generated: $(date)

## Files in This Backup

\`\`\`
${BACKUP_DIR}/
├── sops-age-key.txt                  # CRITICAL - SOPS decryption key
├── ssh/
│   ├── homelab_ed25519               # SSH private key
│   └── homelab_ed25519.pub           # SSH public key
├── kubeconfig                        # Kubernetes cluster config
├── ansible-inventories/              # Ansible host inventory
├── ansible-group_vars/               # Ansible variables
├── aries-cluster-config.bundle       # GitOps repository backup
├── CREDENTIALS-TEMPLATE.md           # Credentials documentation
└── RECOVERY-QUICK-START.md           # This file
\`\`\`

## Prerequisites for Recovery

1. Physical access to cluster nodes or SSH access
2. This backup directory with all files
3. GitHub account access (bsidio)
4. DNS management access (Cloudflare for sidapi.com)

## Recovery Steps

### Step 1: Restore SOPS Key (CRITICAL FIRST STEP)

\`\`\`bash
# Restore SOPS Age key
mkdir -p ~/.config/sops/age
cp ${BACKUP_DIR}/sops-age-key.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# Set environment variable
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# Verify it works
cd /path/to/aries-cluster-config
sops -d clusters/aries/apps/harbor/harbor-secrets.secret.enc.yaml
\`\`\`

### Step 2: Restore SSH Keys

\`\`\`bash
# Restore SSH keys
mkdir -p ~/.ssh
cp ${BACKUP_DIR}/ssh/homelab_ed25519 ~/.ssh/
cp ${BACKUP_DIR}/ssh/homelab_ed25519.pub ~/.ssh/
chmod 600 ~/.ssh/homelab_ed25519
chmod 644 ~/.ssh/homelab_ed25519.pub

# Test SSH access
ssh -i ~/.ssh/homelab_ed25519 ubuntu@aries1
\`\`\`

### Step 3: Clone/Restore Repositories

\`\`\`bash
# Option A: Clone from GitHub (preferred)
cd ~/Documents
git clone https://github.com/bsidio/aries-homelab
git clone https://github.com/bsidio/aries-cluster-config

# Option B: Restore from backup bundle
cd ~/Documents
git clone ${BACKUP_DIR}/aries-cluster-config.bundle aries-cluster-config
git clone https://github.com/bsidio/aries-homelab  # Still need Ansible playbooks
\`\`\`

### Step 4: Run Automated Recovery

\`\`\`bash
cd ~/Documents/aries-homelab/homelab-ansible

# Get your GitHub Personal Access Token ready
# Then run the disaster recovery playbook:
ansible-playbook -i inventories/prod/hosts.ini playbooks/disaster-recovery.yml \\
  -e github_token=<your-github-token> \\
  -e github_user=bsidio
\`\`\`

This will automatically:
- ✅ Bootstrap all nodes
- ✅ Install K3s HA cluster
- ✅ Fetch kubeconfig
- ✅ Install Flux GitOps
- ✅ Deploy all applications

**Total Time**: ~30-45 minutes

### Step 5: Update DNS Records

After recovery completes, get the MetalLB IP:

\`\`\`bash
export KUBECONFIG=~/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig
kubectl get svc -n traefik-system traefik
\`\`\`

Update these DNS records in Cloudflare:
- sidapi.com → <MetalLB IP>
- *.sidapi.com → <MetalLB IP>

### Step 6: Verify Recovery

\`\`\`bash
# Check all pods
kubectl get pods --all-namespaces

# Test applications
curl -k https://harbor.sidapi.com
curl -k https://builds.sidapi.com

# Test Harbor login
docker login harbor.sidapi.com
\`\`\`

## Manual Recovery Steps

If the automated playbook fails, follow the detailed manual steps in:
~/Documents/aries-homelab/homelab-ansible/DISASTER-RECOVERY.md

## Troubleshooting

### SOPS Decryption Fails
- Verify Age key is at ~/.config/sops/age/keys.txt
- Check SOPS_AGE_KEY_FILE environment variable
- Ensure key file has correct permissions (600)

### Flux Bootstrap Fails
- Verify GitHub token has repo scope
- Check network connectivity to GitHub
- Ensure repository exists and is accessible

### Applications Not Deploying
- Check Flux status: \`flux get all\`
- View Flux logs: \`kubectl logs -n flux-system -l app=kustomize-controller\`
- Force reconciliation: \`flux reconcile kustomization flux-system --with-source\`

## Support

- Disaster Recovery Guide: ~/Documents/aries-homelab/homelab-ansible/DISASTER-RECOVERY.md
- Ansible Playbooks: ~/Documents/aries-homelab/homelab-ansible/playbooks/
- GitOps Repository: https://github.com/bsidio/aries-cluster-config
EOF

echo -e "${GREEN}   ✅ ${BACKUP_DIR}/RECOVERY-QUICK-START.md${NC}"
echo ""

# Calculate backup size
BACKUP_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)

# Create backup manifest
cat > "${BACKUP_DIR}/MANIFEST.txt" <<EOF
Aries Cluster Backup Manifest
==============================
Created: $(date)
Backup Directory: ${BACKUP_DIR}
Backup Size: ${BACKUP_SIZE}

Files Backed Up:
$(find "${BACKUP_DIR}" -type f -exec ls -lh {} \; | awk '{print $9, "(" $5 ")"}')

Verification:
- Run sha256sum on critical files to verify integrity
- Store this backup in multiple secure locations
- Test recovery process periodically

Next Steps:
1. Fill in CREDENTIALS-TEMPLATE.md with actual values
2. Store backup in secure location (encrypted external drive, cloud storage)
3. Verify backup integrity
4. Test recovery process in isolated environment
EOF

echo -e "${BLUE}7. Backup Manifest${NC}"
echo -e "${GREEN}   ✅ ${BACKUP_DIR}/MANIFEST.txt${NC}"
echo ""

# Final summary
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✅ BACKUP COMPLETE${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Backup Location: ${BACKUP_DIR}${NC}"
echo -e "${GREEN}Backup Size: ${BACKUP_SIZE}${NC}"
echo ""
echo -e "${YELLOW}📋 Next Steps:${NC}"
echo -e "${YELLOW}   1. Fill in CREDENTIALS-TEMPLATE.md with actual passwords${NC}"
echo -e "${YELLOW}   2. Store backup in secure location (encrypted)${NC}"
echo -e "${YELLOW}   3. Test recovery process periodically${NC}"
echo -e "${YELLOW}   4. Keep multiple backup copies in different locations${NC}"
echo ""
echo -e "${RED}⚠️  CRITICAL FILES:${NC}"
echo -e "${RED}   - sops-age-key.txt (CANNOT be regenerated)${NC}"
echo -e "${RED}   - SSH keys (needed for node access)${NC}"
echo -e "${RED}   - Credentials documentation (needed for external services)${NC}"
echo ""
echo -e "${BLUE}Recovery: Read ${BACKUP_DIR}/RECOVERY-QUICK-START.md${NC}"
echo ""

# Create compressed archive
echo -e "${BLUE}Creating compressed archive...${NC}"
ARCHIVE_NAME="aries-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
ARCHIVE_PATH="$(dirname "${BACKUP_DIR}")/${ARCHIVE_NAME}"
tar -czf "${ARCHIVE_PATH}" -C "$(dirname "${BACKUP_DIR}")" "$(basename "${BACKUP_DIR}")"
ARCHIVE_SIZE=$(du -sh "${ARCHIVE_PATH}" | cut -f1)
echo -e "${GREEN}   ✅ Archive created: ${ARCHIVE_PATH} (${ARCHIVE_SIZE})${NC}"
echo ""

echo -e "${GREEN}🎉 Backup process complete!${NC}"
