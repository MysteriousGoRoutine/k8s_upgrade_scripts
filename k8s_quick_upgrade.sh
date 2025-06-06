#!/bin/bash

# Quick Kubernetes Upgrade Script
# Simplified version for common upgrade scenarios

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
K_VER=""
MODE=""
SSH_USER="ubuntu"
CONTROL_PLANE=""
WORKERS=""
SKIP_VERIFICATION=false
DRY_RUN=false

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
Quick Kubernetes Upgrade Script

USAGE:
    $0 <version> <mode> [options]

ARGUMENTS:
    version     Kubernetes version (e.g., 1.33.1-1.1)
    mode        Upgrade mode:
                  local-cp     - Upgrade local control plane
                  local-worker - Upgrade local worker node  
                  remote-cp    - Upgrade remote control plane
                  remote-workers - Upgrade remote worker nodes only
                  remote-all   - Upgrade entire remote cluster

OPTIONS:
    --ssh-user USER       SSH username (default: ubuntu)
    --control-plane IP    Control plane IP (for remote modes)
    --workers IP1,IP2     Worker IPs (for remote-all mode)
    --skip-verification   Skip post-upgrade verification checks
    --dry-run             Show what would be done without executing

EXAMPLES:
    # Local control plane upgrade
    sudo $0 1.33.1-1.1 local-cp
    
    # Local worker upgrade (specify node name when prompted)
    sudo $0 1.33.1-1.1 local-worker
    
    # Remote control plane only
    $0 1.33.1-1.1 remote-cp --control-plane 10.0.1.10
    
    # Remote worker nodes only
    $0 1.33.1-1.1 remote-workers --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12
    
    # Full remote cluster upgrade
    $0 1.33.1-1.1 remote-all --control-plane 10.0.1.10 --workers 10.0.1.11,10.0.1.12

EOF
}

# Parse arguments
if [[ $# -lt 2 ]]; then
    show_help
    exit 1
fi

K_VER="$1"
MODE="$2"
shift 2

while [[ $# -gt 0 ]]; do
    case $1 in
        --ssh-user)
            SSH_USER="$2"
            shift 2
            ;;
        --control-plane)
            CONTROL_PLANE="$2"
            shift 2
            ;;
        --workers)
            WORKERS="$2"
            shift 2
            ;;
        --skip-verification)
            SKIP_VERIFICATION=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate version format
if ! [[ "$K_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid version format. Expected: X.Y.Z-A.B (e.g., 1.33.1-1.1)"
    exit 1
fi

# Get the full upgrade script path
FULL_SCRIPT="$(dirname "$0")/k8s_upgrade_remote_fixed.sh"

if [[ ! -f "$FULL_SCRIPT" ]]; then
    log_error "Full upgrade script not found: $FULL_SCRIPT"
    log_error "Please ensure k8s_upgrade_remote_fixed.sh is in the same directory"
    exit 1
fi

# Execute based on mode
case $MODE in
    local-cp)
        log "Starting local control plane upgrade to $K_VER"
        cmd="sudo $FULL_SCRIPT --version $K_VER --type control-plane --auto-approve"
        [[ "$SKIP_VERIFICATION" == true ]] && cmd="$cmd --skip-verification"
        [[ "$DRY_RUN" == true ]] && cmd="$cmd --dry-run"
        exec $cmd
        ;;
        
    local-worker)
        echo -n "Enter worker node name: "
        read -r NODE_NAME
        if [[ -z "$NODE_NAME" ]]; then
            log_error "Node name is required for worker upgrade"
            exit 1
        fi
        log "Starting local worker upgrade to $K_VER (node: $NODE_NAME)"
        cmd="sudo $FULL_SCRIPT --version $K_VER --type worker --node $NODE_NAME --auto-approve"
        [[ "$SKIP_VERIFICATION" == true ]] && cmd="$cmd --skip-verification"
        [[ "$DRY_RUN" == true ]] && cmd="$cmd --dry-run"
        exec $cmd
        ;;
        
    remote-cp)
        if [[ -z "$CONTROL_PLANE" ]]; then
            log_error "Control plane IP required for remote-cp mode. Use --control-plane"
            exit 1
        fi
        log "Starting remote control plane upgrade to $K_VER"
        log "Target: $CONTROL_PLANE"
        cmd="$FULL_SCRIPT --version $K_VER --remote --ssh-user $SSH_USER --control-plane $CONTROL_PLANE"
        [[ "$SKIP_VERIFICATION" == true ]] && cmd="$cmd --skip-verification"
        [[ "$DRY_RUN" == true ]] && cmd="$cmd --dry-run"
        exec $cmd
        ;;
        
    remote-workers)
        if [[ -z "$CONTROL_PLANE" ]]; then
            log_error "Control plane IP required for remote-workers mode. Use --control-plane"
            exit 1
        fi
        if [[ -z "$WORKERS" ]]; then
            log_error "Worker IPs required for remote-workers mode. Use --workers"
            exit 1
        fi
        log "Starting worker nodes upgrade to $K_VER"
        log "Control plane: $CONTROL_PLANE (for drain/uncordon operations)"
        log "Workers: $WORKERS"
        cmd="$FULL_SCRIPT --version $K_VER --remote --ssh-user $SSH_USER --control-plane $CONTROL_PLANE --workers $WORKERS --workers-only"
        [[ "$SKIP_VERIFICATION" == true ]] && cmd="$cmd --skip-verification"
        [[ "$DRY_RUN" == true ]] && cmd="$cmd --dry-run"
        exec $cmd
        ;;
        
    remote-all)
        if [[ -z "$CONTROL_PLANE" ]]; then
            log_error "Control plane IP required for remote-all mode. Use --control-plane"
            exit 1
        fi
        if [[ -z "$WORKERS" ]]; then
            log_error "Worker IPs required for remote-all mode. Use --workers"
            exit 1
        fi
        log "Starting full cluster upgrade to $K_VER"
        log "Control plane: $CONTROL_PLANE"
        log "Workers: $WORKERS"
        cmd="$FULL_SCRIPT --version $K_VER --remote --ssh-user $SSH_USER --control-plane $CONTROL_PLANE --workers $WORKERS"
        [[ "$SKIP_VERIFICATION" == true ]] && cmd="$cmd --skip-verification"
        [[ "$DRY_RUN" == true ]] && cmd="$cmd --dry-run"
        exec $cmd
        ;;
        
    *)
        log_error "Invalid mode: $MODE"
        log_error "Valid modes: local-cp, local-worker, remote-cp, remote-workers, remote-all"
        show_help
        exit 1
        ;;
esac