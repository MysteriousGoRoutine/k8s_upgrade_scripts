#!/bin/bash

# Kubernetes Version Checker Script
# This script checks available Kubernetes versions in the official repositories

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

show_help() {
    cat << EOF
Kubernetes Version Checker

USAGE:
    $0 [options]

OPTIONS:
    --check-repo VERSION    Check if specific version repository exists (e.g., 1.31, 1.32)
    --list-packages VERSION List available packages for version (e.g., 1.31, 1.32)
    --current              Show currently installed Kubernetes version
    --all                  Show all available major.minor versions
    --help, -h             Show this help message

EXAMPLES:
    # Check if v1.31 repository exists
    $0 --check-repo 1.31
    
    # List available packages for v1.31
    $0 --list-packages 1.31
    
    # Show current installed version
    $0 --current
    
    # Show all available versions
    $0 --all

EOF
}

check_repository() {
    local version="$1"
    local repo_url="https://pkgs.k8s.io/core:/stable:/v${version}/deb/"
    
    log "Checking repository for Kubernetes v${version}..."
    
    if curl -s --head "$repo_url" | head -n 1 | grep -q "200 OK"; then
        log_success "Repository exists: $repo_url"
        return 0
    else
        log_error "Repository does not exist or is not accessible: $repo_url"
        return 1
    fi
}

list_packages() {
    local version="$1"
    local repo_url="https://pkgs.k8s.io/core:/stable:/v${version}/deb/"
    
    log "Checking available packages for Kubernetes v${version}..."
    
    # First check if repository exists
    if ! check_repository "$version"; then
        return 1
    fi
    
    # Try to get package information
    local temp_sources="/tmp/k8s_temp_sources_$(date +%s).list"
    local temp_keyring="/tmp/k8s_temp_keyring_$(date +%s).gpg"
    
    # Download the GPG key
    log "Downloading Kubernetes GPG key..."
    if curl -fsSL https://pkgs.k8s.io/core:/stable:/v${version}/deb/Release.key | gpg --dearmor -o "$temp_keyring" 2>/dev/null; then
        log_success "GPG key downloaded successfully"
    else
        log_error "Failed to download GPG key"
        return 1
    fi
    
    # Create temporary sources file
    echo "deb [signed-by=$temp_keyring] $repo_url /" > "$temp_sources"
    
    # Update package list and get kubeadm versions
    log "Fetching package list..."
    if apt-get update -o Dir::Etc::sourcelist="$temp_sources" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" 2>/dev/null; then
        log_success "Package list updated successfully"
        
        echo -e "\n${CYAN}Available kubeadm packages for v${version}:${NC}"
        apt-cache madison kubeadm -o Dir::Etc::sourcelist="$temp_sources" -o Dir::Etc::sourceparts="-" | grep -E "v${version}" | head -10
        
        echo -e "\n${CYAN}Latest available versions:${NC}"
        apt-cache madison kubeadm -o Dir::Etc::sourcelist="$temp_sources" -o Dir::Etc::sourceparts="-" | grep -E "v${version}" | head -5 | while read -r line; do
            version_info=$(echo "$line" | awk '{print $3}')
            echo -e "  ${GREEN}$version_info${NC}"
        done
    else
        log_error "Failed to update package list"
    fi
    
    # Cleanup
    rm -f "$temp_sources" "$temp_keyring"
}

show_current_version() {
    log "Checking currently installed Kubernetes versions..."
    
    echo -e "\n${CYAN}Kubectl version:${NC}"
    if command -v kubectl >/dev/null 2>&1; then
        kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null || echo "kubectl not properly configured"
    else
        echo "kubectl not installed"
    fi
    
    echo -e "\n${CYAN}Kubeadm version:${NC}"
    if command -v kubeadm >/dev/null 2>&1; then
        kubeadm version -o short 2>/dev/null || kubeadm version 2>/dev/null || echo "kubeadm not properly configured"
    else
        echo "kubeadm not installed"
    fi
    
    echo -e "\n${CYAN}Kubelet version:${NC}"
    if command -v kubelet >/dev/null 2>&1; then
        kubelet --version 2>/dev/null || echo "kubelet not properly configured"
    else
        echo "kubelet not installed"
    fi
    
    echo -e "\n${CYAN}Installed packages:${NC}"
    dpkg -l | grep -E "(kubeadm|kubelet|kubectl)" | awk '{print $2 "\t" $3}' | column -t
}

check_all_versions() {
    log "Checking all available Kubernetes versions..."
    
    echo -e "\n${CYAN}Checking major Kubernetes versions:${NC}"
    
    # Check common versions
    local versions=("1.28" "1.29" "1.30" "1.31" "1.32" "1.33")
    
    for version in "${versions[@]}"; do
        echo -n "  v${version}: "
        if curl -s --head "https://pkgs.k8s.io/core:/stable:/v${version}/deb/" | head -n 1 | grep -q "200 OK"; then
            echo -e "${GREEN}Available${NC}"
        else
            echo -e "${RED}Not available${NC}"
        fi
    done
    
    echo -e "\n${CYAN}Recommended versions to use:${NC}"
    echo -e "  ${GREEN}v1.32${NC} - Latest stable release (December 2024)"
    echo -e "  ${GREEN}v1.31${NC} - Previous stable release (August 2024)"
    echo -e "  ${GREEN}v1.30${NC} - Older stable release (April 2024)"
    echo -e "  ${YELLOW}v1.29${NC} - Extended support (older)"
    
    echo -e "\n${YELLOW}Note: v1.33 is scheduled for release in April 2025${NC}"
}

# Main script logic
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

case $1 in
    --check-repo)
        if [[ $# -lt 2 ]]; then
            log_error "Version required for --check-repo"
            exit 1
        fi
        check_repository "$2"
        ;;
    --list-packages)
        if [[ $# -lt 2 ]]; then
            log_error "Version required for --list-packages"
            exit 1
        fi
        list_packages "$2"
        ;;
    --current)
        show_current_version
        ;;
    --all)
        check_all_versions
        ;;
    -h|--help)
        show_help
        ;;
    *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac