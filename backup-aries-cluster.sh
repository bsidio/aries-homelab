#!/bin/bash

# Aries Cluster Backup Script
# Backs up critical cluster configuration files (excluding Git repos)

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BACKUP_DIR="$HOME/cluster-backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="aries-cluster-backup-${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"
FINAL_ARCHIVE="$HOME/Desktop/${BACKUP_NAME}.tar.gz"

echo -e "${GREEN}=== Aries Cluster Configuration Backup ===${NC}"
echo "Timestamp: ${TIMESTAMP}"
echo ""

# Create backup directory
echo -e "${YELLOW}Creating backup directory...${NC}"
mkdir -p "${BACKUP_PATH}"

# 1. Kubernetes Configuration
echo -e "${YELLOW}Backing up Kubernetes configuration...${NC}"
if [ -d "$HOME/.kube" ]; then
    cp -r "$HOME/.kube" "${BACKUP_PATH}/"
    echo -e "${GREEN}✓${NC} Kubernetes config backed up"
else
    echo -e "${RED}✗${NC} No .kube directory found"
fi

# Also backup the ansible kubeconfig
if [ -f "$HOME/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig" ]; then
    mkdir -p "${BACKUP_PATH}/ansible-artifacts"
    cp "$HOME/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig" "${BACKUP_PATH}/ansible-artifacts/"
    echo -e "${GREEN}✓${NC} Ansible kubeconfig backed up"
fi

# 2. SSH Keys
echo -e "${YELLOW}Backing up SSH keys...${NC}"
if [ -d "$HOME/.ssh" ]; then
    mkdir -p "${BACKUP_PATH}/ssh"
    # Only backup keys and config, not known_hosts (can be regenerated)
    cp "$HOME/.ssh/id_"* "${BACKUP_PATH}/ssh/" 2>/dev/null || true
    [ -f "$HOME/.ssh/config" ] && cp "$HOME/.ssh/config" "${BACKUP_PATH}/ssh/"
    echo -e "${GREEN}✓${NC} SSH keys backed up"
else
    echo -e "${RED}✗${NC} No .ssh directory found"
fi

# 3. SOPS/AGE Encryption Keys (CRITICAL!)
echo -e "${YELLOW}Backing up SOPS/AGE encryption keys...${NC}"
if [ -f "$HOME/.config/sops/age/keys.txt" ]; then
    mkdir -p "${BACKUP_PATH}/sops"
    cp -r "$HOME/.config/sops" "${BACKUP_PATH}/"
    echo -e "${GREEN}✓${NC} SOPS/AGE keys backed up (CRITICAL - Keep these safe!)"
else
    echo -e "${RED}✗${NC} No SOPS/AGE keys found - WARNING: You may not be able to decrypt secrets!"
fi

# 4. Claude Code Configuration (optional)
echo -e "${YELLOW}Backing up Claude Code configuration...${NC}"
if [ -d "$HOME/.claude" ]; then
    cp -r "$HOME/.claude" "${BACKUP_PATH}/"
    echo -e "${GREEN}✓${NC} Claude Code config backed up"
else
    echo -e "${YELLOW}○${NC} No Claude Code config found (optional)"
fi

# 5. Create inventory file with important info
echo -e "${YELLOW}Creating cluster information file...${NC}"
cat > "${BACKUP_PATH}/cluster-info.txt" << EOF
Aries Cluster Backup Information
================================
Backup Date: $(date)
Hostname: $(hostname)
User: $(whoami)

Cluster Nodes:
- aries1.local (10.0.0.10)
- aries2.local (10.0.0.11)
- aries3.local (10.0.0.12)

MetalLB IP Pool: 10.0.0.200-220
Current LoadBalancer IPs:
- Traefik: 10.0.0.201

Git Repositories (stored on GitHub):
- https://github.com/bsidio/aries-cluster-config
- Local path: ~/Documents/git/aries-cluster-config

Important Notes:
- SOPS/AGE keys are CRITICAL for decrypting secrets
- Kubeconfig contains cluster access credentials
- SSH keys are needed for node access

Restore Instructions:
1. Extract this backup to your home directory
2. Copy .kube to ~/.kube
3. Copy .ssh files to ~/.ssh (chmod 600 for private keys)
4. Copy .config/sops to ~/.config/sops
5. Clone Git repos from GitHub
EOF
echo -e "${GREEN}✓${NC} Cluster info file created"

# 6. Create restore script
echo -e "${YELLOW}Creating restore script...${NC}"
cat > "${BACKUP_PATH}/restore.sh" << 'RESTORE_SCRIPT'
#!/bin/bash
# Aries Cluster Configuration Restore Script

set -e

echo "=== Aries Cluster Configuration Restore ==="
echo "This will restore configuration files to your home directory."
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# Restore Kubernetes config
if [ -d ".kube" ]; then
    echo "Restoring Kubernetes configuration..."
    cp -r .kube "$HOME/"
    chmod 600 "$HOME/.kube/config" 2>/dev/null || true
fi

# Restore SSH keys
if [ -d "ssh" ]; then
    echo "Restoring SSH keys..."
    mkdir -p "$HOME/.ssh"
    cp ssh/* "$HOME/.ssh/"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh/id_"* 2>/dev/null || true
fi

# Restore SOPS config
if [ -d ".config/sops" ]; then
    echo "Restoring SOPS/AGE keys..."
    mkdir -p "$HOME/.config"
    cp -r .config "$HOME/"
    chmod 600 "$HOME/.config/sops/age/keys.txt" 2>/dev/null || true
fi

# Restore Claude config (optional)
if [ -d ".claude" ]; then
    echo "Restoring Claude Code configuration..."
    cp -r .claude "$HOME/"
fi

echo ""
echo "Restore complete! Next steps:"
echo "1. Clone Git repositories from GitHub:"
echo "   git clone https://github.com/bsidio/aries-cluster-config ~/Documents/git/aries-cluster-config"
echo "2. Test kubectl connection:"
echo "   kubectl get nodes"
echo "3. Verify SOPS decryption:"
echo "   cd ~/Documents/git/aries-cluster-config"
echo "   sops -d clusters/aries/apps/longhorn/longhorn-r2-backups.secret.enc.yaml"
RESTORE_SCRIPT

chmod +x "${BACKUP_PATH}/restore.sh"
echo -e "${GREEN}✓${NC} Restore script created"

# 7. Create the final archive
echo -e "${YELLOW}Creating compressed archive...${NC}"
cd "${BACKUP_DIR}"
tar -czf "${FINAL_ARCHIVE}" "${BACKUP_NAME}"
ARCHIVE_SIZE=$(du -h "${FINAL_ARCHIVE}" | cut -f1)
echo -e "${GREEN}✓${NC} Archive created: ${FINAL_ARCHIVE} (${ARCHIVE_SIZE})"

# 8. Cleanup temporary files
echo -e "${YELLOW}Cleaning up temporary files...${NC}"
rm -rf "${BACKUP_PATH}"

# Final summary
echo ""
echo -e "${GREEN}=== Backup Complete ===${NC}"
echo "Backup saved to: ${FINAL_ARCHIVE}"
echo "Size: ${ARCHIVE_SIZE}"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC}"
echo "1. Store this backup in a secure location (cloud storage, external drive)"
echo "2. The SOPS/AGE keys are CRITICAL - without them you cannot decrypt secrets"
echo "3. Test the restore process on another machine if possible"
echo ""
echo "To restore on another machine:"
echo "1. Extract the archive: tar -xzf ${BACKUP_NAME}.tar.gz"
echo "2. Run the restore script: cd ${BACKUP_NAME} && ./restore.sh"
echo "3. Clone Git repos from GitHub"
