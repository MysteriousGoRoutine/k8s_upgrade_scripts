#!/bin/bash

# Sequential Kubernetes Worker Nodes Upgrade Script
# Upgrades worker nodes one by one with safety checks

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
K_VER=""
SSH_USER="ubuntu"
CONTROL_PLANE_HOST=""
declare -a WORKER_HOSTS=()
SSH_TIMEOUT=30
WAIT_BETWEEN_NODES=60
DRY_RUN=false
SKIP_VERIFICATION=false

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

show_help() {
    cat << EOF
Sequential Kubernetes Worker Nodes Upgrade Script

USAGE:
    $0 --version VERSION --control-plane HOST --workers HOST1,HOST2,... [OPTIONS]

REQUIRED:
    --version VERSION         Kubernetes version (e.g., 1.33.1-1.1)
    --control-plane HOST      Control plane hostname/IP
    --workers HOST1,HOST2     Comma-separated worker hostnames/IPs

OPTIONS:
    --ssh-user USER          SSH username (default: ubuntu)
    --ssh-timeout SECONDS    SSH timeout (default: 30)
    --wait-between SECONDS   Wait time between worker upgrades (default: 60)
    --dry-run                Show what would be done without executing
    --skip-verification      Skip post-upgrade verification
    -h, --help               Show this help

EXAMPLES:
    # Basic worker upgrade
    $0 --version 1.33.1-1.1 --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12

    # With custom wait time
    $0 --version 1.33.1-1.1 --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12 --wait-between 30

    # Dry run
    $0 --version 1.33.1-1.1 --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12 --dry-run

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            K_VER="$2"
            shift 2
            ;;
        --control-plane)
            CONTROL_PLANE_HOST="$2"
            shift 2
            ;;
        --workers)
            if [[ -n "$2" ]]; then
                IFS=',' read -ra WORKER_HOSTS <<< "$2"
            fi
            shift 2
            ;;
        --ssh-user)
            SSH_USER="$2"
            shift 2
            ;;
        --ssh-timeout)
            SSH_TIMEOUT="$2"
            shift 2
            ;;
        --wait-between)
            WAIT_BETWEEN_NODES="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-verification)
            SKIP_VERIFICATION=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate inputs
if [[ -z "$K_VER" ]]; then
    log_error "Kubernetes version is required. Use --version"
    exit 1
fi

if [[ -z "$CONTROL_PLANE_HOST" ]]; then
    log_error "Control plane host is required. Use --control-plane"
    exit 1
fi

if [[ ${#WORKER_HOSTS[@]} -eq 0 ]]; then
    log_error "Worker hosts are required. Use --workers"
    exit 1
fi

# Validate version format
if ! [[ "$K_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid version format. Expected: X.Y.Z-A.B (e.g., 1.33.1-1.1)"
    exit 1
fi

# Execute command remotely
execute_remote() {
    local host="$1"
    local cmd="$2"
    local description="$3"
    
    log_info "$description on $host"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would execute on $host: $cmd"
        return 0
    fi
    
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=no \
           "$SSH_USER@$host" "$cmd"; then
        log_success "$description completed on $host"
        return 0
    else
        log_error "$description failed on $host"
        return 1
    fi
}

# Test SSH connectivity
test_ssh_connection() {
    local host="$1"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would test SSH connection to $host"
        return 0
    fi
    
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes -o StrictHostKeyChecking=no \
           "$SSH_USER@$host" "echo 'SSH OK'" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Wait for node to be ready
wait_for_node_ready() {
    local node_name="$1"
    local max_wait=300  # 5 minutes
    local wait_time=0
    
    log_info "Waiting for node $node_name to be ready..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would wait for node $node_name to be ready"
        return 0
    fi
    
    while [[ $wait_time -lt $max_wait ]]; do
        if ssh "$SSH_USER@$CONTROL_PLANE_HOST" \
               "kubectl get node $node_name --no-headers | awk '{print \$2}' | grep -q Ready" 2>/dev/null; then
            log_success "Node $node_name is ready"
            return 0
        fi
        
        echo -n "."
        sleep 10
        wait_time=$((wait_time + 10))
    done
    
    log_error "Node $node_name did not become ready within $max_wait seconds"
    return 1
}

# Check cluster health
check_cluster_health() {
    log_info "Checking cluster health..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would check cluster health"
        return 0
    fi
    
    # Check all nodes are ready
    if execute_remote "$CONTROL_PLANE_HOST" \
                     "kubectl get nodes --no-headers | grep -v Ready | wc -l | grep -q '^0$'" \
                     "Checking all nodes are ready"; then
        return 0
    else
        log_warning "Some nodes are not ready"
        execute_remote "$CONTROL_PLANE_HOST" "kubectl get nodes" "Showing node status"
        return 1
    fi
}

# Upgrade single worker node
upgrade_worker_node() {
    local worker_ip="$1"
    local worker_name="$2"
    local worker_index="$3"
    local total_workers="$4"
    
    log "=== Upgrading Worker Node $worker_index/$total_workers: $worker_name ($worker_ip) ==="
    
    # Step 1: Drain the node
    log_info "Step 1: Draining node $worker_name"
    if ! execute_remote "$CONTROL_PLANE_HOST" \
                       "kubectl drain $worker_name --ignore-daemonsets --delete-emptydir-data --force --timeout=300s" \
                       "Draining node $worker_name"; then
        log_error "Failed to drain node $worker_name"
        return 1
    fi
    
    # Step 2: Upgrade packages on worker
    log_info "Step 2: Upgrading Kubernetes packages on $worker_ip"
    
    # Update repository
    local major_minor_version
    major_minor_version=$(echo "$K_VER" | sed -E 's/^([0-9]+\.[0-9]+)\..*$/\1/')
    local repo_line="deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${major_minor_version}/deb/ /"
    
    if ! execute_remote "$worker_ip" \
                       "sudo sh -c 'echo \"$repo_line\" > /etc/apt/sources.list.d/kubernetes.list'" \
                       "Updating Kubernetes repository"; then
        log_error "Failed to update repository on $worker_ip"
        return 1
    fi
    
    # Upgrade packages
    if ! execute_remote "$worker_ip" \
                       "sudo apt-mark unhold kubelet kubectl kubeadm && sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet=$K_VER kubectl=$K_VER kubeadm=$K_VER && sudo apt-mark hold kubelet kubectl kubeadm" \
                       "Upgrading Kubernetes packages"; then
        log_error "Failed to upgrade packages on $worker_ip"
        return 1
    fi
    
    # Upgrade node configuration
    if ! execute_remote "$worker_ip" \
                       "sudo kubeadm upgrade node" \
                       "Upgrading node configuration"; then
        log_error "Failed to upgrade node configuration on $worker_ip"
        return 1
    fi
    
    # Restart kubelet
    if ! execute_remote "$worker_ip" \
                       "sudo systemctl daemon-reload && sudo systemctl restart kubelet" \
                       "Restarting kubelet"; then
        log_error "Failed to restart kubelet on $worker_ip"
        return 1
    fi
    
    # Step 3: Wait for node to be ready
    log_info "Step 3: Waiting for node to be ready"
    if ! wait_for_node_ready "$worker_name"; then
        log_error "Node $worker_name did not become ready"
        return 1
    fi
    
    # Step 4: Uncordon the node
    log_info "Step 4: Uncordoning node $worker_name"
    if ! execute_remote "$CONTROL_PLANE_HOST" \
                       "kubectl uncordon $worker_name" \
                       "Uncordoning node $worker_name"; then
        log_error "Failed to uncordon node $worker_name"
        return 1
    fi
    
    # Step 5: Verify node is working
    if [[ "$SKIP_VERIFICATION" == false ]]; then
        log_info "Step 5: Verifying node upgrade"
        execute_remote "$worker_ip" "kubelet --version" "Checking kubelet version"
        execute_remote "$CONTROL_PLANE_HOST" "kubectl get node $worker_name -o wide" "Checking node status"
    fi
    
    log_success "Worker node $worker_name upgrade completed successfully!"
    return 0
}

# Main upgrade process
main() {
    local start_time
    start_time=$(date +%s)
    
    log "Starting sequential worker nodes upgrade"
    log "Target version: $K_VER"
    log "Control plane: $CONTROL_PLANE_HOST"
    log "Workers: ${WORKER_HOSTS[*]}"
    log "Wait between nodes: $WAIT_BETWEEN_NODES seconds"
    [[ "$DRY_RUN" == true ]] && log "Mode: DRY RUN"
    
    # Test SSH connectivity to all hosts
    log "Testing SSH connectivity..."
    
    if ! test_ssh_connection "$CONTROL_PLANE_HOST"; then
        log_error "Cannot connect to control plane: $CONTROL_PLANE_HOST"
        exit 1
    fi
    log_success "Control plane SSH: OK"
    
    for worker in "${WORKER_HOSTS[@]}"; do
        if ! test_ssh_connection "$worker"; then
            log_error "Cannot connect to worker: $worker"
            exit 1
        fi
    done
    log_success "All worker SSH connections: OK"
    
    # Initial cluster health check
    if ! check_cluster_health; then
        log_error "Cluster is not healthy before upgrade"
        exit 1
    fi
    
    # Upgrade workers sequentially
    local total_workers=${#WORKER_HOSTS[@]}
    local successful_upgrades=0
    
    for i in "${!WORKER_HOSTS[@]}"; do
        local worker="${WORKER_HOSTS[$i]}"
        local worker_name="worker-$i"
        local worker_index=$((i + 1))
        
        if upgrade_worker_node "$worker" "$worker_name" "$worker_index" "$total_workers"; then
            successful_upgrades=$((successful_upgrades + 1))
            
            # Wait between nodes (except for the last one)
            if [[ $i -lt $((total_workers - 1)) ]]; then
                log "Waiting $WAIT_BETWEEN_NODES seconds before upgrading next worker..."
                if [[ "$DRY_RUN" == false ]]; then
                    sleep "$WAIT_BETWEEN_NODES"
                fi
            fi
        else
            log_error "Failed to upgrade worker node $worker_name ($worker)"
            
            # Ask user if they want to continue
            if [[ "$DRY_RUN" == false ]]; then
                echo -n "Do you want to continue with remaining workers? (y/N): "
                read -r response
                if [[ ! "$response" =~ ^[Yy]$ ]]; then
                    log "Upgrade process stopped by user"
                    exit 1
                fi
            fi
        fi
    done
    
    # Final cluster health check
    if [[ "$SKIP_VERIFICATION" == false ]]; then
        log "Performing final cluster health check..."
        check_cluster_health
    fi
    
    # Summary
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo
    log "=== UPGRADE SUMMARY ==="
    log "Total workers: $total_workers"
    log "Successful upgrades: $successful_upgrades"
    log "Failed upgrades: $((total_workers - successful_upgrades))"
    log "Total time: ${duration} seconds"
    
    if [[ $successful_upgrades -eq $total_workers ]]; then
        log_success "All worker nodes upgraded successfully!"
        exit 0
    else
        log_error "Some worker node upgrades failed"
        exit 1
    fi
}

# Run main function
main