#!/bin/bash

# Enhanced Kubernetes Upgrade Script with Remote SSH Support
# Based on official kubeadm upgrade documentation
# https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
K_VER=""
NODE=""
NODE_TYPE=""
DRY_RUN=false
SKIP_DRAIN=false
SKIP_REPO_UPDATE=false
AUTO_APPROVE=false
SHOW_PROGRESS=true
SKIP_VERIFICATION=false
WORKERS_ONLY=false

# Remote execution settings
REMOTE_MODE=false
SSH_USER=""
CONTROL_PLANE_HOST=""
declare -a WORKER_HOSTS=()  # Properly declare array
SSH_TIMEOUT=30
REMOTE_SCRIPT_PATH="/tmp/k8s_upgrade_$(date +%s).sh"

# Kubernetes repository configuration
K8S_SOURCES_FILE="/etc/apt/sources.list.d/kubernetes.list"
K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
K8S_REPO_BASE="https://pkgs.k8s.io/core:/stable:/"

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
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

log_remote() {
    echo -e "${CYAN}[REMOTE]${NC} $1"
}

log_progress() {
    if [[ "$SHOW_PROGRESS" == true ]]; then
        echo -e "${YELLOW}[PROGRESS]${NC} $1"
    fi
}

# Help function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Enhanced Kubernetes Upgrade Script with Remote SSH Support

MODES:
    Local Mode:  Execute upgrade on current machine
    Remote Mode: Execute upgrade on remote machines via SSH

LOCAL MODE OPTIONS:
    -v, --version VERSION       Kubernetes version to upgrade to (e.g., 1.33.0-1.1)
    -n, --node NODE            Node name for worker node operations
    -t, --type TYPE            Node type: control-plane or worker
    -d, --dry-run              Show what would be done without executing
    -s, --skip-drain           Skip draining node (use with caution)
    -r, --skip-repo-update     Skip updating Kubernetes repository
    -y, --auto-approve         Auto-approve upgrade without interactive confirmation
    --skip-verification        Skip post-upgrade verification checks
    --workers-only             Skip control plane upgrade (workers only)

REMOTE MODE OPTIONS:
    --remote                   Enable remote mode
    --ssh-user USER            SSH username for remote connections
    --control-plane HOST       Control plane node hostname/IP
    --workers HOST1,HOST2,...  Comma-separated list of worker node hostnames/IPs
    --ssh-timeout SECONDS      SSH connection timeout (default: 30)

GENERAL OPTIONS:
    -h, --help                 Show this help message

LOCAL MODE EXAMPLES:
    # Upgrade control plane node locally
    $0 --version 1.33.0-1.1 --type control-plane

    # Upgrade worker node locally
    $0 --version 1.33.0-1.1 --type worker --node worker-0

    # Auto-approve upgrade without confirmation
    $0 --version 1.33.0-1.1 --type control-plane --auto-approve

REMOTE MODE EXAMPLES:
    # Upgrade entire cluster remotely
    $0 --version 1.33.0-1.1 --remote --ssh-user ubuntu \\
       --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12

    # Dry run for remote cluster upgrade
    $0 --version 1.33.0-1.1 --remote --ssh-user ubuntu \\
       --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12 --dry-run

    # Auto-approve remote upgrade
    $0 --version 1.33.0-1.1 --remote --ssh-user ubuntu \\
       --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12 --auto-approve

    # Upgrade only control plane remotely
    $0 --version 1.33.0-1.1 --remote --ssh-user ubuntu \\
       --control-plane 10.0.1.10

    # Upgrade only worker nodes remotely
    $0 --version 1.33.0-1.1 --remote --ssh-user ubuntu \\
       --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12 --workers-only

    # Example of using the script to upgrade a remote cluster
    $0 --version 1.33.3-1.1 \\
       --remote \\
       --ssh-user ubuntu \\
       --control-plane leader-ld \\
       --workers worker-ld-1,worker-ld-2,worker-ld-3 \\
       --auto-approve
EOF
}

# Parse command line arguments
parse_args() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                K_VER="$2"
                shift 2
                ;;
            -n|--node)
                NODE="$2"
                shift 2
                ;;
            -t|--type)
                NODE_TYPE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -s|--skip-drain)
                SKIP_DRAIN=true
                shift
                ;;
            -r|--skip-repo-update)
                SKIP_REPO_UPDATE=true
                shift
                ;;
            -y|--auto-approve)
                AUTO_APPROVE=true
                shift
                ;;
            --skip-verification)
                SKIP_VERIFICATION=true
                shift
                ;;
            --workers-only)
                WORKERS_ONLY=true
                shift
                ;;
            --remote)
                REMOTE_MODE=true
                AUTO_APPROVE=true  # Auto-enable for remote mode
                shift
                ;;
            --ssh-user)
                SSH_USER="$2"
                shift 2
                ;;
            --control-plane)
                CONTROL_PLANE_HOST="$2"
                shift 2
                ;;
            --workers)
                # Properly parse comma-separated workers
                if [[ -n "$2" ]]; then
                    IFS=',' read -ra WORKER_HOSTS <<< "$2"
                fi
                shift 2
                ;;
            --ssh-timeout)
                SSH_TIMEOUT="$2"
                shift 2
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
}

# Extract major.minor version from full version
get_major_minor_version() {
    local version="$1"
    echo "$version" | sed -E 's/^([0-9]+\.[0-9]+)\..*$/\1/'
}

# Validate inputs
validate_inputs() {
    if [[ -z "$K_VER" ]]; then
        log_error "Kubernetes version is required. Use -v or --version"
        exit 1
    fi

    # Validate version format
    if ! [[ "$K_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid version format. Expected format: X.Y.Z-A.B (e.g., 1.33.0-1.1)"
        exit 1
    fi

    if [[ "$REMOTE_MODE" == true ]]; then
        # Remote mode validation
        if [[ -z "$SSH_USER" ]]; then
            log_error "SSH user is required for remote mode. Use --ssh-user"
            exit 1
        fi

        if [[ -z "$CONTROL_PLANE_HOST" ]]; then
            log_error "Control plane host is required for remote mode. Use --control-plane"
            exit 1
        fi
    else
        # Local mode validation
        if [[ -z "$NODE_TYPE" ]]; then
            log_error "Node type is required for local mode. Use -t or --type (control-plane or worker)"
            exit 1
        fi

        if [[ "$NODE_TYPE" != "control-plane" && "$NODE_TYPE" != "worker" ]]; then
            log_error "Node type must be either 'control-plane' or 'worker'"
            exit 1
        fi

        if [[ "$NODE_TYPE" == "worker" && -z "$NODE" ]]; then
            log_error "Node name is required for worker node upgrades. Use -n or --node"
            exit 1
        fi
    fi
}

# Test SSH connectivity
test_ssh_connection() {
    local host="$1"
    local description="$2"

    log_remote "Testing SSH connection to $host ($description)..."

    if [[ "$DRY_RUN" == true ]]; then
        log_warning "[DRY-RUN] Would test SSH connection to $host"
        return 0
    fi

    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes -o StrictHostKeyChecking=no \
           "$SSH_USER@$host" "echo 'SSH connection successful'" >/dev/null 2>&1; then
        log_success "SSH connection to $host successful"
        return 0
    else
        log_error "SSH connection to $host failed"
        return 1
    fi
}

# Execute command remotely
execute_remote_cmd() {
    local host="$1"
    local cmd="$2"
    local description="$3"
    local use_sudo="${4:-true}"

    log_remote "$description on $host"

    local full_cmd="$cmd"
    if [[ "$use_sudo" == "true" ]]; then
        full_cmd="sudo $cmd"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would execute on $host: $full_cmd"
        return 0
    fi

    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=no \
           "$SSH_USER@$host" "$full_cmd"; then
        log_success "$description completed on $host"
        return 0
    else
        log_error "$description failed on $host"
        log_error "Failed command: $full_cmd"
        suggest_rollback
        return 1
    fi
}

# Execute command remotely (non-critical - won't exit on failure)
execute_remote_cmd_soft() {
    local host="$1"
    local cmd="$2"
    local description="$3"
    local use_sudo="${4:-true}"

    log_remote "$description on $host"

    local full_cmd="$cmd"
    if [[ "$use_sudo" == "true" ]]; then
        full_cmd="sudo $cmd"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would execute on $host: $full_cmd"
        return 0
    fi

    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=no \
           "$SSH_USER@$host" "$full_cmd"; then
        log_success "$description completed on $host"
        return 0
    else
        log_warning "$description failed on $host (non-critical)"
        return 1
    fi
}

# Copy script to remote host
copy_script_to_remote() {
    local host="$1"

    log_remote "Copying upgrade script to $host"

    if [[ "$DRY_RUN" == true ]]; then
        log_warning "[DRY-RUN] Would copy script to $host:$REMOTE_SCRIPT_PATH"
        return 0
    fi

    if scp -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=no \
           "$0" "$SSH_USER@$host:$REMOTE_SCRIPT_PATH"; then
        log_success "Script copied to $host"
        execute_remote_cmd "$host" "chmod +x $REMOTE_SCRIPT_PATH" "Making script executable" false
        return 0
    else
        log_error "Failed to copy script to $host"
        return 1
    fi
}

# Execute local upgrade on remote host
execute_remote_upgrade() {
    local host="$1"
    local node_type="$2"
    local node_name="$3"

    log_remote "Starting Kubernetes upgrade on $host (type: $node_type)"

    # Build remote command
    local remote_cmd="$REMOTE_SCRIPT_PATH --version $K_VER --type $node_type --auto-approve"
    [[ -n "$node_name" ]] && remote_cmd="$remote_cmd --node $node_name"
    [[ "$DRY_RUN" == true ]] && remote_cmd="$remote_cmd --dry-run"
    [[ "$SKIP_REPO_UPDATE" == true ]] && remote_cmd="$remote_cmd --skip-repo-update"
    [[ "$SKIP_DRAIN" == true ]] && remote_cmd="$remote_cmd --skip-drain"
    [[ "$SKIP_VERIFICATION" == true ]] && remote_cmd="$remote_cmd --skip-verification"
    [[ "$WORKERS_ONLY" == true ]] && remote_cmd="$remote_cmd --workers-only"

    if [[ "$DRY_RUN" == true ]]; then
        log_warning "[DRY-RUN] Would execute on $host: sudo $remote_cmd"
        return 0
    fi

    # Execute upgrade
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=no \
           "$SSH_USER@$host" "sudo $remote_cmd"; then
        log_success "Kubernetes upgrade completed on $host"

        # Cleanup remote script
        execute_remote_cmd "$host" "rm -f $REMOTE_SCRIPT_PATH" "Cleaning up remote script" false
        return 0
    else
        log_error "Kubernetes upgrade failed on $host"
        return 1
    fi
}

# Get number of worker hosts
get_worker_count() {
    echo "${#WORKER_HOSTS[@]}"
}

# Check if worker hosts array is empty
has_workers() {
    local count
    count=$(get_worker_count)
    [[ $count -gt 0 ]] && [[ -n "${WORKER_HOSTS[0]:-}" ]]
}

# Remote cluster upgrade orchestration
remote_cluster_upgrade() {
    log "Starting remote Kubernetes cluster upgrade"
    log "Target version: $K_VER"
    log "Control plane: $CONTROL_PLANE_HOST"

    # Safe worker hosts display
    if has_workers; then
        log "Workers: ${WORKER_HOSTS[*]}"
    else
        log "Workers: none"
    fi

    [[ "$DRY_RUN" == true ]] && log "Mode: DRY RUN"
    [[ "$AUTO_APPROVE" == true ]] && log "Mode: AUTO APPROVE"

    # Test SSH connections
    log "Testing SSH connectivity to all nodes..."
    test_ssh_connection "$CONTROL_PLANE_HOST" "control plane" || exit 1

    if has_workers; then
        for worker in "${WORKER_HOSTS[@]}"; do
            [[ -n "$worker" ]] && { test_ssh_connection "$worker" "worker" || exit 1; }
        done
    fi

    log_success "All SSH connections successful"

    # Step 1: Upgrade control plane (unless workers-only mode)
    if [[ "$WORKERS_ONLY" == false ]]; then
        log "=== STEP 1: Upgrading Control Plane ==="
        log_progress "Starting control plane upgrade on $CONTROL_PLANE_HOST"
        copy_script_to_remote "$CONTROL_PLANE_HOST" || exit 1
        execute_remote_upgrade "$CONTROL_PLANE_HOST" "control-plane" "" || exit 1
        log_progress "Control plane upgrade completed successfully"

        # Wait for control plane to be ready
        if [[ "$DRY_RUN" == false ]] && has_workers; then
            log "Waiting for control plane to be ready before upgrading workers..."
            sleep 30
        fi
    else
        log "Skipping control plane upgrade (workers-only mode)"
    fi

    # Step 2: Upgrade worker nodes
    if has_workers; then
        if [[ "$WORKERS_ONLY" == true ]]; then
            log "=== UPGRADING WORKER NODES ONLY ==="
        else
            log "=== STEP 2: Upgrading Worker Nodes ==="
        fi

        for i in "${!WORKER_HOSTS[@]}"; do
            local worker="${WORKER_HOSTS[$i]}"
            [[ -z "$worker" ]] && continue

            local total_workers
            total_workers=$(get_worker_count)
            log_progress "Upgrading worker node $((i+1))/$total_workers: $worker"

            # Drain node before upgrade
            if [[ "$SKIP_DRAIN" == false ]]; then
                log_progress "Draining node $worker before upgrade"
                execute_remote_cmd "$CONTROL_PLANE_HOST" \
                    "kubectl drain $worker --ignore-daemonsets --delete-emptydir-data --force --timeout=300s" \
                    "Draining node $worker" false
            fi

            copy_script_to_remote "$worker" || exit 1
            execute_remote_upgrade "$worker" "worker" "$worker" || exit 1

            # Uncordon node after upgrade
            log_progress "Bringing node $worker back online"
            execute_remote_cmd "$CONTROL_PLANE_HOST" \
                "kubectl uncordon $worker" \
                "Uncordoning node $worker" false

            log_progress "Worker node $worker upgrade completed ($((i+1))/$total_workers)"

            # Wait between worker upgrades
            if [[ "$DRY_RUN" == false && $i -lt $((total_workers - 1)) ]]; then
                log "Waiting 30 seconds before next worker upgrade..."
                sleep 30
            fi
        done
    fi

    log_success "Remote Kubernetes cluster upgrade completed successfully!"

    if [[ "$DRY_RUN" == false && "$SKIP_VERIFICATION" == false ]]; then
        log "Verifying cluster status..."
        verify_cluster_status
    elif [[ "$SKIP_VERIFICATION" == true ]]; then
        log "Skipping post-upgrade verification as requested"
    fi
}

# Execute command with dry-run support (for local execution)
execute_cmd() {
    local cmd="$1"
    local description="$2"

    log "$description"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would execute: $cmd"
    else
        eval "$cmd"
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            log_success "$description completed"
        else
            log_error "$description failed (exit code: $exit_code)"
            log_error "Failed command: $cmd"
            suggest_rollback
            exit 1
        fi
    fi
}

# Execute command with dry-run support (non-critical - won't exit on failure)
execute_cmd_soft() {
    local cmd="$1"
    local description="$2"

    log "$description"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would execute: $cmd"
        return 0
    else
        eval "$cmd"
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            log_success "$description completed"
            return 0
        else
            log_warning "$description failed (non-critical, exit code: $exit_code)"
            return 1
        fi
    fi
}

# Check if running as root for certain operations (local execution)
check_root() {
    if [[ $EUID -ne 0 && "$DRY_RUN" == false ]]; then
        log_error "This script needs to be run with sudo for actual execution"
        exit 1
    fi
}

# Update Kubernetes repository (local execution)
update_k8s_repository() {
    if [[ "$SKIP_REPO_UPDATE" == true ]]; then
        log_warning "Skipping Kubernetes repository update as requested"
        return 0
    fi

    log "Updating Kubernetes repository configuration..."

    local major_minor_version
    major_minor_version=$(get_major_minor_version "$K_VER")
    local new_repo_line="deb [signed-by=$K8S_KEYRING] ${K8S_REPO_BASE}v${major_minor_version}/deb/ /"

    log "Target Kubernetes version: v$major_minor_version"
    log "New repository line: $new_repo_line"

    # Check if kubernetes.list exists
    if [[ ! -f "$K8S_SOURCES_FILE" ]]; then
        log_warning "Kubernetes sources file does not exist: $K8S_SOURCES_FILE"
        execute_cmd "echo '$new_repo_line' > $K8S_SOURCES_FILE" "Creating Kubernetes sources file"
        return 0
    fi

    # Read current repository configuration
    if [[ "$DRY_RUN" == false ]]; then
        local current_repo
        current_repo=$(cat "$K8S_SOURCES_FILE" 2>/dev/null || echo "")

        if [[ -n "$current_repo" ]]; then
            log "Current repository configuration:"
            echo "  $current_repo"

            # Extract current version from repository URL
            local current_version
            current_version=$(echo "$current_repo" | sed -n 's/.*\/v\([0-9]\+\.[0-9]\+\)\/deb\/.*/\1/p')

            if [[ -n "$current_version" ]]; then
                log "Current repository version: v$current_version"

                if [[ "$current_version" == "$major_minor_version" ]]; then
                    log_success "Repository is already configured for version v$major_minor_version"
                    return 0
                else
                    log "Repository version needs to be updated from v$current_version to v$major_minor_version"
                fi
            else
                log_warning "Could not extract version from current repository configuration"
            fi
        fi
    fi

    # Backup current configuration
    if [[ -f "$K8S_SOURCES_FILE" ]]; then
        execute_cmd "cp $K8S_SOURCES_FILE ${K8S_SOURCES_FILE}.backup.$(date +%Y%m%d_%H%M%S)" "Backing up current Kubernetes sources file"
    fi

    # Update repository configuration
    execute_cmd "echo '$new_repo_line' > $K8S_SOURCES_FILE" "Updating Kubernetes repository configuration"

    # Verify keyring exists
    if [[ "$DRY_RUN" == false && ! -f "$K8S_KEYRING" ]]; then
        log_error "Kubernetes keyring not found: $K8S_KEYRING"
        log_error "Please ensure Kubernetes repository is properly configured with GPG key"
        exit 1
    fi

    log_success "Kubernetes repository updated successfully"
}

# Upgrade kubeadm (local execution)
upgrade_kubeadm() {
    log "Starting kubeadm upgrade..."

    execute_cmd "apt-mark unhold kubeadm" "Unholding kubeadm package"
    execute_cmd "apt-get update" "Updating package list"
    execute_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y kubeadm=$K_VER" "Installing kubeadm version $K_VER"
    execute_cmd "apt-mark hold kubeadm" "Holding kubeadm package"
}

# Control plane specific operations (local execution)
upgrade_control_plane() {
    log "Upgrading control plane node..."

    update_k8s_repository
    upgrade_kubeadm

    execute_cmd "kubeadm upgrade plan" "Checking upgrade plan"

    # Handle interactive confirmation
    if [[ "$DRY_RUN" == false && "$AUTO_APPROVE" == false ]]; then
        log_warning "Please review the upgrade plan above."
        read -p "Do you want to continue with the upgrade? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Upgrade cancelled by user"
            exit 0
        fi
    fi

    local k8s_version
    k8s_version=$(echo "$K_VER" | sed 's/-.*$//')  # Remove package revision part

    # Use --yes flag for non-interactive execution
    if [[ "$AUTO_APPROVE" == true || "$REMOTE_MODE" == true ]]; then
        execute_cmd "kubeadm upgrade apply v${k8s_version} --yes" "Applying cluster upgrade (auto-approved)"
    else
        execute_cmd "kubeadm upgrade apply v${k8s_version}" "Applying cluster upgrade"
    fi

    # Upgrade kubelet and kubectl on control plane
    execute_cmd "apt-mark unhold kubelet kubectl" "Unholding kubelet and kubectl packages"
    execute_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet=$K_VER kubectl=$K_VER" "Installing kubelet and kubectl version $K_VER"
    execute_cmd "apt-mark hold kubelet kubectl" "Holding kubelet and kubectl packages"
    execute_cmd "systemctl daemon-reload" "Reloading systemd daemon"
    execute_cmd "systemctl restart kubelet" "Restarting kubelet service"
}

# Worker node specific operations (local execution)
upgrade_worker() {
    log "Upgrading worker node: $NODE"

    # Update repository and upgrade packages on worker node
    update_k8s_repository

    execute_cmd "apt-mark unhold kubelet kubectl kubeadm" "Unholding Kubernetes packages"
    execute_cmd "apt-get update" "Updating package list"
    execute_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet=$K_VER kubectl=$K_VER kubeadm=$K_VER" "Installing Kubernetes packages version $K_VER"
    execute_cmd "apt-mark hold kubelet kubectl kubeadm" "Holding Kubernetes packages"

    # Upgrade node configuration
    execute_cmd "kubeadm upgrade node" "Upgrading node configuration"

    # Restart kubelet
    execute_cmd "systemctl daemon-reload" "Reloading systemd daemon"
    execute_cmd "systemctl restart kubelet" "Restarting kubelet service"
}

# Pre-flight checks for local execution
preflight_checks() {
    log "Running pre-flight checks..."

    # Check if kubectl is available for worker operations
    if [[ "$NODE_TYPE" == "worker" ]]; then
        if ! command -v kubectl &> /dev/null; then
            log_error "kubectl is not available. Required for worker node operations."
            exit 1
        fi
    fi

    # Check if sources directory exists
    if [[ ! -d "$(dirname "$K8S_SOURCES_FILE")" ]]; then
        log_warning "APT sources directory does not exist: $(dirname "$K8S_SOURCES_FILE")"
        if [[ "$DRY_RUN" == false ]]; then
            execute_cmd "mkdir -p $(dirname "$K8S_SOURCES_FILE")" "Creating APT sources directory"
        fi
    fi

    log_success "Pre-flight checks passed"
}

# Local upgrade execution
local_upgrade() {
    log "Starting local Kubernetes upgrade process"
    log "Version: $K_VER"
    log "Node type: $NODE_TYPE"
    [[ -n "$NODE" ]] && log "Node name: $NODE"
    [[ "$DRY_RUN" == true ]] && log "Mode: DRY RUN"
    [[ "$AUTO_APPROVE" == true ]] && log "Mode: AUTO APPROVE"
    [[ "$SKIP_REPO_UPDATE" == true ]] && log "Repository update: SKIPPED"

    preflight_checks

    if [[ "$DRY_RUN" == false ]]; then
        check_root
    fi

    case $NODE_TYPE in
        control-plane)
            upgrade_control_plane
            ;;
        worker)
            upgrade_worker
            ;;
    esac

    log_success "Local Kubernetes upgrade process completed successfully!"

    if [[ "$DRY_RUN" == false && "$SKIP_VERIFICATION" == false ]]; then
        verify_local_status
    elif [[ "$SKIP_VERIFICATION" == true ]]; then
        log "Skipping post-upgrade verification as requested"
    fi
}

# Verify cluster status after remote upgrade
verify_cluster_status() {
    log "=== POST-UPGRADE VERIFICATION ==="

    execute_remote_cmd "$CONTROL_PLANE_HOST" "kubectl get nodes -o wide" "Getting cluster nodes status" false

    log "Checking component versions..."
    execute_remote_cmd_soft "$CONTROL_PLANE_HOST" "kubectl version --client --short 2>/dev/null || kubectl version --client" "Checking kubectl version" false
    execute_remote_cmd_soft "$CONTROL_PLANE_HOST" "kubeadm version" "Checking kubeadm version" false

    # Test API server connectivity first
    if execute_remote_cmd_soft "$CONTROL_PLANE_HOST" "kubectl cluster-info &>/dev/null" "Testing API server connectivity" false; then
        log "Checking cluster health..."
        execute_remote_cmd_soft "$CONTROL_PLANE_HOST" "kubectl get componentstatuses 2>/dev/null || kubectl get --raw='/healthz?verbose'" "Checking cluster components" false

        log "Checking node readiness..."
        execute_remote_cmd_soft "$CONTROL_PLANE_HOST" "kubectl get nodes --no-headers | awk '{print \$1, \$2}'" "Checking node status" false

        if has_workers; then
            log "Checking pods status..."
            execute_remote_cmd_soft "$CONTROL_PLANE_HOST" "kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || echo 'No problematic pods found'" "Checking for non-running pods" false
        fi
    else
        log_warning "Cannot connect to Kubernetes API server for detailed cluster verification"
        log "This is normal if API server is restarting after upgrade"
        log "You can run 'kubectl get nodes' manually once the API server is ready"
    fi

    log_success "Cluster verification completed"
}

# Verify local status after upgrade
verify_local_status() {
    log "=== POST-UPGRADE VERIFICATION ==="

    if command -v kubectl &> /dev/null; then
        log "Checking local component versions..."
        execute_cmd_soft "kubectl version --client --short 2>/dev/null || kubectl version --client" "Checking kubectl version"
        execute_cmd_soft "kubeadm version" "Checking kubeadm version"
        execute_cmd_soft "kubelet --version" "Checking kubelet version"

        if [[ "$NODE_TYPE" == "control-plane" ]]; then
            log "Checking cluster status..."
            if kubectl cluster-info &>/dev/null; then
                execute_cmd_soft "kubectl get nodes" "Getting cluster nodes"
                execute_cmd_soft "kubectl get componentstatuses 2>/dev/null || kubectl get --raw='/healthz?verbose'" "Checking cluster health"
            else
                log_warning "Cannot connect to Kubernetes API server for cluster status check"
                log "This is normal if API server is restarting after upgrade"
                log "You can run 'kubectl get nodes' manually once the API server is ready"
            fi
        fi
    else
        log "Checking local component versions..."
        execute_cmd_soft "kubeadm version" "Checking kubeadm version"
        execute_cmd_soft "kubelet --version" "Checking kubelet version"
    fi

    log_success "Local verification completed"
}

# Suggest rollback procedures
suggest_rollback() {
    log_error "=== ROLLBACK SUGGESTIONS ==="
    log_error "If you need to rollback this upgrade, consider:"
    log_error "1. Check backup files in /etc/apt/sources.list.d/ (*.backup.*)"
    log_error "2. Restore previous Kubernetes repository configuration"
    log_error "3. Downgrade packages manually:"
    log_error "   sudo apt-mark unhold kubeadm kubelet kubectl"
    log_error "   sudo apt-get install kubeadm=<old-version> kubelet=<old-version> kubectl=<old-version>"
    log_error "   sudo apt-mark hold kubeadm kubelet kubectl"
    log_error "4. For control plane nodes, you may need to restore etcd backup"
    log_error "5. Check Kubernetes documentation for version-specific rollback procedures"
    log_error "==============================================="
}

# Main function
main() {
    if [[ "$REMOTE_MODE" == true ]]; then
        remote_cluster_upgrade
    else
        local_upgrade
    fi
}

# Parse arguments and run main function
parse_args "$@"
validate_inputs
main
