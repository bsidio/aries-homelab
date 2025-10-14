# Testing Ansible Playbooks

This guide shows you how to safely test the Ansible playbooks before running them on your infrastructure.

## Prerequisites

Ensure Ansible is installed:
```bash
ansible-playbook --version
```

You should see Ansible 2.10 or higher.

## Testing Levels

### Level 1: Syntax Validation ✅ (SAFE - No changes made)

Validate YAML syntax and playbook structure:

```bash
cd /Users/sb/Documents/aries-homelab/homelab-ansible

# Test individual playbooks
ansible-playbook --syntax-check playbooks/bootstrap.yml
ansible-playbook --syntax-check playbooks/k3s-ha.yml
ansible-playbook --syntax-check playbooks/metallb.yml
ansible-playbook --syntax-check playbooks/fetch-kubeconfig.yml

# Test all playbooks at once
for playbook in playbooks/*.yml; do
    echo "Checking: $playbook"
    ansible-playbook --syntax-check "$playbook"
done
```

**Result**: ✅ All playbooks pass syntax validation!

### Level 2: Lint Validation ✅ (SAFE - No changes made)

Check for best practices and potential issues:

```bash
cd /Users/sb/Documents/aries-homelab/homelab-ansible

# Lint individual playbooks
ansible-lint playbooks/bootstrap.yml
ansible-lint playbooks/k3s-ha.yml
ansible-lint playbooks/metallb.yml
ansible-lint playbooks/fetch-kubeconfig.yml

# Or lint everything
ansible-lint
```

**Expected**: Should pass with no errors (all issues fixed).

### Level 3: Check Mode (Dry Run) ⚠️ (SAFE - No changes made, but connects to hosts)

Run playbook in check mode to see what would change WITHOUT making actual changes:

```bash
cd /Users/sb/Documents/aries-homelab/homelab-ansible

# Check mode for bootstrap (requires -u sid -k -K for first time)
ansible-playbook -i inventories/prod/hosts.ini \
  playbooks/bootstrap.yml \
  -u sid -k -K \
  --check \
  --diff

# Check mode for k3s-ha (after bootstrap)
ansible-playbook -i inventories/prod/hosts.ini \
  playbooks/k3s-ha.yml \
  --check \
  --diff
```

**What this does**:
- `--check`: Runs in "dry-run" mode (no actual changes)
- `--diff`: Shows what would be changed
- `-k`: Prompts for SSH password (only for initial bootstrap)
- `-K`: Prompts for sudo password (only for initial bootstrap)

**Note**: Some tasks may show "failed" in check mode if they depend on previous changes (e.g., checking for files that would be created). This is normal.

### Level 4: Limited Scope Test ⚠️ (MAKES CHANGES - Test on single host)

Test on a single node first:

```bash
# Test bootstrap on just aries1
ansible-playbook -i inventories/prod/hosts.ini \
  playbooks/bootstrap.yml \
  -u sid -k -K \
  --limit aries1

# Verify the changes on aries1
ssh ubuntu@10.0.0.233
```

**Recommendation**: If you have spare hardware or VMs, test there first before running on production cluster.

### Level 5: Full Run 🚨 (MAKES CHANGES - Production)

Only run after validating all previous levels:

```bash
cd /Users/sb/Documents/aries-homelab/homelab-ansible

# Bootstrap all nodes (first time only)
ansible-playbook -i inventories/prod/hosts.ini \
  playbooks/bootstrap.yml \
  -u sid -k -K

# Install K3s HA cluster
ansible-playbook -i inventories/prod/hosts.ini \
  playbooks/k3s-ha.yml

# Fetch kubeconfig
ansible-playbook -i inventories/prod/hosts.ini \
  playbooks/fetch-kubeconfig.yml

# Deploy MetalLB
ansible-playbook -i inventories/prod/hosts.ini \
  playbooks/metallb.yml
```

## Quick Test Commands

### Test SSH connectivity:
```bash
cd /Users/sb/Documents/aries-homelab/homelab-ansible

# Ping all hosts
ansible -i inventories/prod/hosts.ini aries -m ping

# Get facts from all hosts
ansible -i inventories/prod/hosts.ini aries -m setup
```

### Test individual tasks:
```bash
# Run a single task using ad-hoc command
ansible -i inventories/prod/hosts.ini aries \
  -m ansible.builtin.command \
  -a "uptime" \
  --become
```

## Validation Checklist

Before running on production:

- [ ] ✅ Syntax check passed (`--syntax-check`)
- [ ] ✅ Lint check passed (`ansible-lint`)
- [ ] ⚠️ Check mode reviewed (`--check --diff`)
- [ ] ⚠️ SSH connectivity verified (`ansible -m ping`)
- [ ] ⚠️ Inventory file reviewed (`cat inventories/prod/hosts.ini`)
- [ ] ⚠️ Group vars reviewed (`cat group_vars/*.yml`)
- [ ] ⚠️ Backup of current cluster state created
- [ ] 🚨 Ready for production run

## Troubleshooting Test Failures

### Syntax errors:
```
ERROR! Syntax Error while loading YAML.
```
**Fix**: Check YAML indentation and structure.

### Module not found:
```
ERROR! couldn't resolve module/action 'some_module'
```
**Fix**: Ensure using `ansible.builtin.*` prefix for all builtin modules.

### SSH connection failed:
```
UNREACHABLE! => {"changed": false, "msg": "Failed to connect"}
```
**Fix**:
- Verify hosts are reachable: `ping 10.0.0.233`
- Check SSH key: `ssh -i ~/.ssh/homelab_ed25519 sid@10.0.0.233`
- Verify inventory: `cat inventories/prod/hosts.ini`

### Permission denied:
```
fatal: [aries1]: FAILED! => {"msg": "Missing sudo password"}
```
**Fix**: Use `-K` flag to prompt for sudo password, or ensure passwordless sudo is configured.

## What Changed in Recent Fixes

The following modules were replaced with builtin alternatives:

1. **SSH Key Authorization** (bootstrap.yml:50)
   - Old: `authorized_key` (requires ansible.posix collection)
   - New: `ansible.builtin.lineinfile` (builtin)
   - Test: Verify SSH key is added to `~/.ssh/authorized_keys`

2. **Sysctl Configuration** (bootstrap.yml:79)
   - Old: `ansible.posix.sysctl` (requires ansible.posix collection)
   - New: `ansible.builtin.lineinfile` writing to `/etc/sysctl.conf`
   - Test: Verify sysctl settings in `/etc/sysctl.conf`

3. **Timezone Configuration** (bootstrap.yml:89)
   - Old: `community.general.timezone` (requires community.general collection)
   - New: `ansible.builtin.file` creating symlink to `/usr/share/zoneinfo/UTC`
   - Test: `ls -la /etc/localtime` and `timedatectl`

## Verification After Running

After running playbooks, verify the changes:

### Bootstrap verification:
```bash
# Check user was created
ssh ubuntu@10.0.0.233 whoami

# Check packages installed
ssh ubuntu@10.0.0.233 "dpkg -l | grep -E 'curl|vim|htop'"

# Check sysctl settings
ssh ubuntu@10.0.0.233 "sysctl vm.swappiness"

# Check timezone
ssh ubuntu@10.0.0.233 "timedatectl"
```

### K3s verification:
```bash
# Check K3s is running
export KUBECONFIG=/Users/sb/Documents/aries-homelab/homelab-ansible/playbooks/artifacts/kubeconfig
kubectl get nodes
kubectl get pods -A
```

### MetalLB verification:
```bash
# Check MetalLB pods
kubectl -n metallb-system get pods

# Check IP pool
kubectl -n metallb-system get ipaddresspools
```

## Rollback Plan

If something goes wrong:

1. **Bootstrap issues**:
   - Manually remove ubuntu user: `sudo userdel -r ubuntu`
   - Revert sysctl: `sudo vi /etc/sysctl.conf`

2. **K3s issues**:
   - Uninstall K3s: `ssh ubuntu@NODE "sudo /usr/local/bin/k3s-uninstall.sh"`
   - Re-run playbook

3. **MetalLB issues**:
   - Delete resources: `kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml`

## Safe Testing Workflow

Recommended testing order:

1. ✅ Run syntax check (Level 1)
2. ✅ Run lint validation (Level 2)
3. ⚠️ Run check mode on one host (Level 3)
4. ⚠️ Verify check mode output looks correct
5. ⚠️ Run on single test host if available (Level 4)
6. ⚠️ Verify results on test host
7. 🚨 Run on production (Level 5)

**Never skip Level 1 and 2!** They catch 90% of issues without touching your infrastructure.
