#!/bin/bash

# Kubernetes Cluster Status Verification Script
# Quick script to check cluster health after upgrades

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
REMOTE_MODE=false
SSH_USER="ubuntu"
CONTROL_PLANE_HOST=""
SSH_TIMEOUT=30
DETAILED=false

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
Kubernetes Cluster Status Verification Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --remote                Enable remote mode (check via SSH)
    --ssh-user USER         SSH username (default: ubuntu)
    --control-plane HOST    Control plane hostname/IP for remote checks
    --ssh-timeout SECONDS   SSH timeout (default: 30)
    --detailed              Show detailed information
    -h, --help              Show this help

EXAMPLES:
    # Check local cluster
    $0

    # Check remote cluster
    $0 --remote --ssh-user ubuntu --control-plane 10.0.1.10

    # Detailed check with more information
    $0 --detailed

    # Remote detailed check
    $0 --remote --control-plane 10.0.1.10 --detailed

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --remote)
            REMOTE_MODE=true
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
        --ssh-timeout)
            SSH_TIMEOUT="$2"
            shift 2
            ;;
        --detailed)
            DETAILED=true
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

# Validate inputs for remote mode
if [[ "$REMOTE_MODE" == true && -z "$CONTROL_PLANE_HOST" ]]; then
    log_error "Control plane host is required for remote mode. Use --control-plane"
    exit 1
fi

# Execute command locally
execute_local() {
    local cmd="$1"
    local description="$2"
    local critical="${3:-true}"
    
    log_info "$description"
    
    if eval "$cmd" 2>/dev/null; then
        log_success "$description - OK"
        return 0
    else
        if [[ "$critical" == "true" ]]; then
            log_error "$description - FAILED"
        else
            log_warning "$description - FAILED (non-critical)"
        fi
        return 1
    fi
}

# Execute command remotely
execute_remote() {
    local cmd="$1"
    local description="$2"
    local critical="${3:-true}"
    
    log_info "$description (remote: $CONTROL_PLANE_HOST)"
    
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=no \
           "$SSH_USER@$CONTROL_PLANE_HOST" "$cmd" 2>/dev/null; then
        log_success "$description - OK"
        return 0
    else
        if [[ "$critical" == "true" ]]; then
            log_error "$description - FAILED"
        else
            log_warning "$description - FAILED (non-critical)"
        fi
        return 1
    fi
}

# Generic execute function
execute_check() {
    local cmd="$1"
    local description="$2"
    local critical="${3:-true}"
    
    if [[ "$REMOTE_MODE" == true ]]; then
        execute_remote "$cmd" "$description" "$critical"
    else
        execute_local "$cmd" "$description" "$critical"
    fi
}

# Check basic connectivity
check_connectivity() {
    echo
    log "=== CONNECTIVITY CHECKS ==="
    
    if [[ "$REMOTE_MODE" == true ]]; then
        log_info "Testing SSH connection to $CONTROL_PLANE_HOST"
        if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes -o StrictHostKeyChecking=no \
               "$SSH_USER@$CONTROL_PLANE_HOST" "echo 'SSH OK'" >/dev/null 2>&1; then
            log_success "SSH connection - OK"
        else
            log_error "SSH connection - FAILED"
            return 1
        fi
    fi
    
    execute_check "kubectl cluster-info --request-timeout=10s >/dev/null" "Kubernetes API server connectivity"
    return 0
}

# Check component versions
check_versions() {
    echo
    log "=== VERSION CHECKS ==="
    
    execute_check "kubectl version --client --short" "kubectl client version" false
    execute_check "kubeadm version --output=short" "kubeadm version" false
    
    if [[ "$REMOTE_MODE" == false ]] || ssh -q "$SSH_USER@$CONTROL_PLANE_HOST" "command -v kubelet" >/dev/null 2>&1; then
        execute_check "kubelet --version" "kubelet version" false
    fi
    
    if [[ "$DETAILED" == true ]]; then
        execute_check "kubectl version --short" "Full Kubernetes version info" false
    fi
}

# Check node status
check_nodes() {
    echo
    log "=== NODE STATUS CHECKS ==="
    
    execute_check "kubectl get nodes --no-headers | grep -v Ready | wc -l | grep -q '^0$'" "All nodes ready"
    
    if [[ "$DETAILED" == true ]]; then
        log_info "Node details:"
        execute_check "kubectl get nodes -o wide" "Node detailed status" false
        
        log_info "Node conditions:"
        execute_check "kubectl describe nodes | grep -A 10 'Conditions:'" "Node conditions" false
    else
        execute_check "kubectl get nodes" "Node basic status" false
    fi
}

# Check system pods
check_system_pods() {
    echo
    log "=== SYSTEM PODS CHECKS ==="
    
    execute_check "kubectl get pods -n kube-system --no-headers | grep -v Running | grep -v Completed | wc -l | grep -q '^0$'" "All system pods running"
    
    if [[ "$DETAILED" == true ]]; then
        log_info "System pods details:"
        execute_check "kubectl get pods -n kube-system -o wide" "System pods detailed status" false
        
        # Check for any failed pods
        local failed_pods
        if [[ "$REMOTE_MODE" == true ]]; then
            failed_pods=$(ssh "$SSH_USER@$CONTROL_PLANE_HOST" "kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l" || echo "0")
        else
            failed_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l || echo "0")
        fi
        
        if [[ "$failed_pods" -gt 0 ]]; then
            log_warning "Found $failed_pods non-running pods"
            execute_check "kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded" "Failed pods details" false
        else
            log_success "No failed pods found"
        fi
    fi
}

# Check cluster health
check_cluster_health() {
    echo
    log "=== CLUSTER HEALTH CHECKS ==="
    
    # Try modern health check first, fall back to legacy
    if ! execute_check "kubectl get --raw='/livez?verbose' | grep -q 'livez check passed'" "Cluster liveness" false; then
        execute_check "kubectl get componentstatuses | grep -v Healthy | grep -v NAME | wc -l | grep -q '^0$'" "Component health (legacy)" false
    fi
    
    if ! execute_check "kubectl get --raw='/readyz?verbose' | grep -q 'readyz check passed'" "Cluster readiness" false; then
        log_warning "Readiness check not available or failed"
    fi
    
    if [[ "$DETAILED" == true ]]; then
        execute_check "kubectl get componentstatuses" "Component status details" false
        execute_check "kubectl get events --sort-by='.lastTimestamp' --all-namespaces | tail -10" "Recent cluster events" false
    fi
}

# Check storage and networking
check_infrastructure() {
    if [[ "$DETAILED" != true ]]; then
        return 0
    fi
    
    echo
    log "=== INFRASTRUCTURE CHECKS ==="
    
    execute_check "kubectl get storageclass" "Storage classes" false
    execute_check "kubectl get pv" "Persistent volumes" false
    
    # Check CNI
    execute_check "kubectl get pods -n kube-system | grep -E '(calico|flannel|weave|cilium|antrea)'" "CNI pods" false
    
    # Check DNS
    execute_check "kubectl get pods -n kube-system | grep -E '(coredns|kube-dns)'" "DNS pods" false
    
    # Check ingress controllers (common ones)
    execute_check "kubectl get pods --all-namespaces | grep -E '(ingress|nginx|traefik|istio)'" "Ingress controllers" false
}

# Main verification function
run_verification() {
    local start_time
    start_time=$(date +%s)
    
    log "Starting Kubernetes cluster verification..."
    [[ "$REMOTE_MODE" == true ]] && log "Remote mode: $CONTROL_PLANE_HOST"
    [[ "$DETAILED" == true ]] && log "Detailed mode: enabled"
    
    local checks_passed=0
    local total_checks=0
    
    # Run checks
    if check_connectivity; then ((checks_passed++)); fi; ((total_checks++))
    if check_versions; then ((checks_passed++)); fi; ((total_checks++))
    if check_nodes; then ((checks_passed++)); fi; ((total_checks++))
    if check_system_pods; then ((checks_passed++)); fi; ((total_checks++))
    if check_cluster_health; then ((checks_passed++)); fi; ((total_checks++))
    if check_infrastructure; then ((checks_passed++)); fi; ((total_checks++))
    
    # Summary
    echo
    log "=== VERIFICATION SUMMARY ==="
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log "Verification completed in ${duration} seconds"
    log "Checks passed: $checks_passed/$total_checks"
    
    if [[ $checks_passed -eq $total_checks ]]; then
        log_success "All verification checks passed! Cluster appears healthy."
        return 0
    elif [[ $checks_passed -gt $((total_checks / 2)) ]]; then
        log_warning "Most checks passed, but some issues detected. Review the output above."
        return 1
    else
        log_error "Multiple verification checks failed. Cluster may have issues."
        return 2
    fi
}

# Add suggestions based on common issues
show_troubleshooting_tips() {
    echo
    log "=== TROUBLESHOOTING TIPS ==="
    log "If you see issues, try these common troubleshooting steps:"
    log "1. Check node resources: kubectl describe nodes"
    log "2. Check pod logs: kubectl logs -n kube-system <pod-name>"
    log "3. Check events: kubectl get events --sort-by='.lastTimestamp'"
    log "4. Restart kubelet: sudo systemctl restart kubelet"
    log "5. Check network connectivity between nodes"
    log "6. Verify DNS resolution: nslookup kubernetes.default"
    echo
}

# Main execution
main() {
    if ! run_verification; then
        show_troubleshooting_tips
        exit 1
    fi
}

# Run main function
main