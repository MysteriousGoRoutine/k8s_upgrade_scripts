# Kubernetes Worker Nodes Upgrade Guide

This guide covers different methods to upgrade only the worker nodes in your Kubernetes cluster using the provided scripts.

## Prerequisites

- Control plane must already be upgraded to the target version or compatible version
- SSH access to all worker nodes (with your public key installed)
- `kubectl` access from control plane node
- Sudo privileges on all worker nodes

## Overview of Methods

| Method | Use Case | Pros | Cons |
|--------|----------|------|------|
| **Quick Script** | Simple scenarios | Easy syntax | Limited customization |
| **Main Script** | Full control | All options available | More complex syntax |
| **Sequential Script** | High safety requirements | One-by-one with checks | Slower process |
| **Local Script** | Manual control | Full control per node | Requires local access |

## Method 1: Quick Script (Recommended)

### Basic Worker Upgrade
```bash
./k8s_quick_upgrade.sh 1.33.1-1.1 remote-workers \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11,10.0.1.12,10.0.1.13
```

### With Options
```bash
./k8s_quick_upgrade.sh 1.33.1-1.1 remote-workers \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11,10.0.1.12 \
    --ssh-user ubuntu \
    --skip-verification \
    --dry-run
```

## Method 2: Main Script with --workers-only

### Basic Usage
```bash
./k8s_upgrade_remote_fixed.sh --version 1.33.1-1.1 --remote \
    --ssh-user ubuntu \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11,10.0.1.12,10.0.1.13 \
    --workers-only
```

### All Available Options
```bash
./k8s_upgrade_remote_fixed.sh --version 1.33.1-1.1 --remote \
    --ssh-user ubuntu \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11,10.0.1.12 \
    --workers-only \
    --auto-approve \
    --skip-verification \
    --skip-drain \
    --ssh-timeout 60 \
    --dry-run
```

## Method 3: Sequential Upgrade (Safest)

```bash
./k8s_upgrade_workers_sequential.sh \
    --version 1.33.1-1.1 \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11,10.0.1.12,10.0.1.13 \
    --wait-between 60 \
    --detailed
```

## Method 4: Local Upgrade (Manual)

On each worker node, run:
```bash
sudo ./k8s_upgrade_remote_fixed.sh --version 1.33.1-1.1 \
    --type worker \
    --node worker-0
```

**Note:** Replace `worker-0` with the actual node name shown in `kubectl get nodes`.

## Process Flow

### Automatic Process (Methods 1-3)
1. **SSH Connectivity Test** - Verify access to all nodes
2. **For Each Worker Node:**
   - Drain node (move pods to other nodes)
   - Update Kubernetes repository
   - Upgrade kubelet, kubectl, kubeadm packages
   - Run `kubeadm upgrade node`
   - Restart kubelet service
   - Wait for node to be Ready
   - Uncordon node (allow pods to schedule)
3. **Verification** - Check cluster health

### Manual Process (Method 4)
1. **Pre-drain** (from control plane):
   ```bash
   kubectl drain worker-0 --ignore-daemonsets --delete-emptydir-data
   ```
2. **Run upgrade script** (on worker node)
3. **Post-uncordon** (from control plane):
   ```bash
   kubectl uncordon worker-0
   ```

## Important Options

### --workers-only
Skips control plane upgrade completely, only upgrades worker nodes.

### --skip-drain
⚠️ **Dangerous**: Skips draining nodes before upgrade. Use only if:
- You've manually drained nodes
- You understand the risks of upgrading running nodes

### --skip-verification
Skips post-upgrade health checks. Useful when:
- API server connectivity issues exist
- You want faster execution
- You'll verify manually later

### --dry-run
Shows what would be executed without making changes. Always test with dry-run first!

## Troubleshooting

### SSH Connection Issues
```bash
# Test SSH manually
ssh ubuntu@10.0.1.11 "echo 'SSH works'"

# Check SSH key
ssh-add -l
```

### Node Not Ready After Upgrade
```bash
# Check node status
kubectl get nodes
kubectl describe node worker-0

# Check kubelet logs
ssh ubuntu@10.0.1.11 "sudo journalctl -u kubelet -f"
```

### Drain Issues
```bash
# Force drain if stuck
kubectl drain worker-0 --ignore-daemonsets --delete-emptydir-data --force

# Check what's preventing drain
kubectl get pods --all-namespaces --field-selector spec.nodeName=worker-0
```

### Package Installation Issues
```bash
# Check repository configuration
ssh ubuntu@10.0.1.11 "cat /etc/apt/sources.list.d/kubernetes.list"

# Manual package check
ssh ubuntu@10.0.1.11 "apt-cache policy kubelet"
```

## Verification After Upgrade

### Quick Check
```bash
./k8s_verify_cluster.sh --remote --control-plane 10.0.1.10
```

### Manual Verification
```bash
# Check all nodes are ready
kubectl get nodes

# Check node versions
kubectl get nodes -o wide

# Check system pods
kubectl get pods -n kube-system

# Check cluster health
kubectl get componentstatuses
```

## Best Practices

### 1. Always Test First
```bash
# Use dry-run before actual upgrade
./k8s_quick_upgrade.sh 1.33.1-1.1 remote-workers \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11,10.0.1.12 \
    --dry-run
```

### 2. Upgrade During Maintenance Window
- Plan for potential service disruption
- Ensure workloads can tolerate node restarts
- Have rollback plan ready

### 3. Monitor Resource Usage
```bash
# Check available resources before upgrade
kubectl top nodes
kubectl describe nodes
```

### 4. Backup Important Data
- Backup application data
- Note current cluster state
- Save current package versions

### 5. Gradual Approach
```bash
# Upgrade one node first, then others
./k8s_upgrade_workers_sequential.sh \
    --version 1.33.1-1.1 \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11 \
    --wait-between 300
```

## Common Scenarios

### Production Environment
```bash
# Conservative approach with verification
./k8s_upgrade_workers_sequential.sh \
    --version 1.33.1-1.1 \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11,10.0.1.12,10.0.1.13 \
    --wait-between 120
```

### Development Environment
```bash
# Fast upgrade with minimal checks
./k8s_quick_upgrade.sh 1.33.1-1.1 remote-workers \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11,10.0.1.12 \
    --skip-verification
```

### Testing Environment
```bash
# Dry-run first, then execute
./k8s_quick_upgrade.sh 1.33.1-1.1 remote-workers \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11 \
    --dry-run

# Then without dry-run
./k8s_quick_upgrade.sh 1.33.1-1.1 remote-workers \
    --control-plane 10.0.1.10 \
    --workers 10.0.1.11
```

## Rollback Procedure

If worker upgrade fails:

1. **Check node status:**
   ```bash
   kubectl get nodes
   kubectl describe node worker-0
   ```

2. **Downgrade packages:**
   ```bash
   ssh ubuntu@10.0.1.11 "sudo apt-mark unhold kubelet kubectl kubeadm"
   ssh ubuntu@10.0.1.11 "sudo apt-get install kubelet=1.33.0-1.1 kubectl=1.33.0-1.1 kubeadm=1.33.0-1.1"
   ssh ubuntu@10.0.1.11 "sudo systemctl restart kubelet"
   ```

3. **Restore repository:**
   ```bash
   ssh ubuntu@10.0.1.11 "sudo cp /etc/apt/sources.list.d/kubernetes.list.backup.* /etc/apt/sources.list.d/kubernetes.list"
   ```

## Safety Considerations

- **Never upgrade all workers simultaneously** in production
- **Ensure cluster has enough capacity** to run workloads on remaining nodes during upgrade
- **Test upgrades in non-production environment** first
- **Have monitoring in place** to detect issues quickly
- **Plan for rollback** if upgrade fails
- **Communicate maintenance window** to stakeholders

## Quick Reference

| Task | Command |
|------|---------|
| Quick worker upgrade | `./k8s_quick_upgrade.sh VERSION remote-workers --control-plane IP --workers IPs` |
| Safe sequential upgrade | `./k8s_upgrade_workers_sequential.sh --version VERSION --control-plane IP --workers IPs` |
| Dry-run test | Add `--dry-run` to any command |
| Skip verification | Add `--skip-verification` to any command |
| Manual drain | `kubectl drain NODE --ignore-daemonsets --delete-emptydir-data` |
| Manual uncordon | `kubectl uncordon NODE` |
| Check cluster | `./k8s_verify_cluster.sh --remote --control-plane IP` |

Remember: Always test in a non-production environment first!