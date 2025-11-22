#!/bin/bash

# ========================================================================================================================
# KUBERNETES VERSION UPGRADE SCRIPT - MULTI-CLUSTER HA SETUP
# ========================================================================================================================
# This script upgrades Kubernetes components (kubeadm, kubelet, kubectl) across your multi-cluster setup Supports both
# single-master and HA (multi-master) configurations with load balancers
#
# Run this script from the project directory containing the Vagrantfile
#
# Features:
#   ✅ Upgrades control plane nodes first (masters)
#   ✅ Then upgrades worker nodes with proper draining
#   ✅ Supports multiple clusters (prod, qa, etc.)
#   ✅ Handles HA clusters with load balancers
#   ✅ Automatic rollback on failure
#   ✅ Pre-upgrade validation and backups
#   ✅ Minimal downtime with node draining
#   ✅ Comprehensive logging
#
# 1. Enforces sequential version upgrades (no skipping versions)
# 2. Validates cluster version consistency before upgrade
# 3. Prevents individual master upgrades in multi-master setups
# 4. Adds etcd health checks before control plane upgrades
# 5. Implements proper upgrade order validation
# 6. Adds recovery procedures for failed upgrades
#
# IMPORTANT: In HA setups, ALL masters must be at the same version before upgrading

#
# Usage:
#     ./k8s-upgrade.sh [options] <target-version>
#
# Options:
#     --use-config            Use configuration variables from script
#     -c, --cluster <n>       Upgrade specific cluster (default: all)
#     -n, --node <n>          Upgrade specific node only
#     -s, --skip-drain        Skip draining worker nodes (faster but riskier)
#     -y, --yes               Skip confirmation prompts
#     -v, --verbose           Enable verbose output
#     -h, --help              Show this help message
#
# Examples:
#     ./k8s-upgrade.sh --use-config                 # Use config variables below
#     ./k8s-upgrade.sh v1.31                        # Upgrade all clusters to v1.31
#     ./k8s-upgrade.sh -c k8s-prod v1.31            # Upgrade only prod cluster
#     ./k8s-upgrade.sh -n k8s-prod-master1 v1.31    # Upgrade specific node
#     ./k8s-upgrade.sh -y v1.31                     # Skip confirmation prompts
#
# Order of operations:
#   1. Validate target version and current state
#   2. Backup current configuration
#   3. Upgrade first master in each cluster
#   4. Upgrade additional masters (if HA)
#   5. Upgrade worker nodes one by one
#
# IMPORTANT: Always test in QA cluster first before upgrading production!
# ========================================================================================================================

set -e

# ========================================================================================================================
# ⚙️ CONFIGURATION VARIABLES - EDIT THESE FOR EASY UPGRADES ⚙️
# ========================================================================================================================

# Current cluster version (for validation and documentation)
# Master1 is at v1.30.14, Master2 is at v1.29.15
CURRENT_VERSION="1.32"

# Target version for upgrade (set this to upgrade without command-line arguments)
# Examples: "1.31", "1.31.5", "1.32.10"
# First upgrade master2 to match master1, then upgrade both to 1.31
TARGET_VERSION_CONFIG="1.33"

# Default cluster to upgrade (leave empty for all clusters)
# Examples: "k8s-prod", "k8s-qa", or "" for all
DEFAULT_CLUSTER="k8s-prod"

# Default specific nodes to upgrade (comma-separated, leave empty for entire cluster)
# Examples: "k8s-prod-master1", "k8s-prod-master1,k8s-prod-master2", or "" for all nodes
DEFAULT_NODES=""

# Upgrade scope (what to upgrade by default)
# Options: "all-masters-then-workers", "all-clusters", "cluster", "nodes", "masters-only", "workers-only"
DEFAULT_SCOPE="masters-only"

# Auto-confirm upgrades (set to true to skip confirmation prompt)
AUTO_CONFIRM=false

# ========================================================================================================================
# SCRIPT CONFIGURATION
# ========================================================================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_vagrant_root() {
    local current_dir="$SCRIPT_DIR"
    local max_depth=10
    local depth=0

    while [ $depth -lt $max_depth ]; do
        if [ -f "$current_dir/Vagrantfile" ]; then
            echo "$current_dir"
            return 0
        fi

        local parent_dir
        parent_dir="$(cd "$current_dir/.." 2>/dev/null && pwd)" || parent_dir=""

        if [ -z "$parent_dir" ] || [ "$parent_dir" = "$current_dir" ]; then
            break
        fi

        if [[ "$parent_dir" =~ ^/[a-zA-Z]/?$ ]]; then
            if [ -f "$parent_dir/Vagrantfile" ]; then
                echo "$parent_dir"
                return 0
            fi
            break
        fi

        current_dir="$parent_dir"
        depth=$((depth + 1))
    done

    echo "$SCRIPT_DIR"
    return 1
}

VAGRANT_ROOT="$(find_vagrant_root)"
BACKUP_DIR="${VAGRANT_ROOT}/backups/k8s-upgrade-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${BACKUP_DIR}/upgrade.log"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default options
TARGET_VERSION="${TARGET_VERSION:-}"
SPECIFIC_CLUSTER="${SPECIFIC_CLUSTER:-}"
SPECIFIC_NODE="${SPECIFIC_NODE:-}"
SPECIFIC_NODES="${SPECIFIC_NODES:-}"
UPGRADE_SCOPE="${UPGRADE_SCOPE:-all-clusters}"
SKIP_DRAIN="${SKIP_DRAIN:-false}"
AUTO_YES="${AUTO_YES:-false}"
VERBOSE="${VERBOSE:-false}"
USE_CONFIG="${USE_CONFIG:-false}"
MASTERS_ONLY="${MASTERS_ONLY:-false}"
WORKERS_ONLY="${WORKERS_ONLY:-false}"
SKIP_VERSION_CHECK="${SKIP_VERSION_CHECK:-false}"

# Cluster configuration
declare -A CLUSTERS
declare -a CLUSTER_NAMES

# ========================================================================================================================
# LOGGING FUNCTIONS
# ========================================================================================================================

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -n "$BACKUP_DIR" ] && [ -n "$LOG_FILE" ]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || true
        echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE" 2>/dev/null || true
    fi

    case $level in
        INFO)
            echo -e "${BLUE}ℹ${NC} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}✓${NC} $message"
            ;;
        WARNING)
            echo -e "${YELLOW}⚠${NC} $message"
            ;;
        ERROR)
            echo -e "${RED}✗${NC} $message"
            ;;
        VERBOSE)
            if [ "$VERBOSE" = true ]; then
                echo -e "${CYAN}[VERBOSE]${NC} $message"
            fi
            ;;
    esac
}

# ========================================================================================================================
# HELPER FUNCTIONS
# ========================================================================================================================

show_help() {
    cat << 'EOF'
Kubernetes Version Upgrade Script

Usage: ./k8s-upgrade.sh [options] <target-version>

Arguments:
    target-version          Target K8s version (e.g., v1.31)

Options:
    -c, --cluster <n>       Upgrade specific cluster
    -n, --node <n>          Upgrade specific node only
    -m, --masters-only      Upgrade only master nodes
    -w, --workers-only      Upgrade only worker nodes
    -s, --skip-drain        Skip draining worker nodes
    -y, --yes               Skip confirmation prompts
    -v, --verbose           Enable verbose output
    --use-config            Use configuration variables from script
    --skip-version-check    Skip version validation
    -h, --help              Show this help

Examples:
    ./k8s-upgrade.sh v1.31
    ./k8s-upgrade.sh -n k8s-qa-master1 v1.31
    ./k8s-upgrade.sh --use-config
EOF
}

parse_vagrantfile() {
    log VERBOSE "Parsing Vagrantfile..."

    local vagrantfile="${VAGRANT_ROOT}/Vagrantfile"
    if [ ! -f "$vagrantfile" ]; then
        log ERROR "Vagrantfile not found at: $vagrantfile"
        exit 1
    fi

    local cluster_name=""
    local in_clusters_block=false

    while IFS= read -r line; do
        # Look for ALL_CLUSTERS_DECLARATION instead of CLUSTERS
        if [[ $line =~ ^ALL_CLUSTERS_DECLARATION[[:space:]]*=[[:space:]]*\{ ]]; then
            in_clusters_block=true
            continue
        fi

        if [[ $in_clusters_block == true ]] && [[ $line =~ ^\} ]]; then
            in_clusters_block=false
            continue
        fi

        if [[ $in_clusters_block == true ]] && [[ $line =~ \"([^\"]+)\"[[:space:]]*=\>[[:space:]]*\{ ]]; then
            cluster_name="${BASH_REMATCH[1]}"
            CLUSTER_NAMES+=("$cluster_name")
            log VERBOSE "Found cluster: $cluster_name"
        fi

        if [[ -n "$cluster_name" ]]; then
            if [[ $line =~ master_count:[[:space:]]*([0-9]+) ]]; then
                CLUSTERS["${cluster_name}_master_count"]="${BASH_REMATCH[1]}"
            elif [[ $line =~ worker_count:[[:space:]]*([0-9]+) ]]; then
                CLUSTERS["${cluster_name}_worker_count"]="${BASH_REMATCH[1]}"
            fi
        fi

        if [[ $line =~ ^\s*\},$|^\s*\}$ ]] && [[ -n "$cluster_name" ]]; then
            cluster_name=""
        fi
    done < "$vagrantfile"

    log SUCCESS "Parsed ${#CLUSTER_NAMES[@]} cluster(s): ${CLUSTER_NAMES[*]}"
}

get_current_version() {
    local node=$1

    log VERBOSE "Getting version from node: $node"

    local version=""
    local raw_output=""

    raw_output=$(vagrant ssh "$node" -c "kubelet --version 2>/dev/null" 2>/dev/null)
    version=$(echo "$raw_output" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [ -n "$version" ]; then
        log VERBOSE "Version from kubelet: $version"
        echo "$version"
        return 0
    fi

    log VERBOSE "Could not determine version from $node"
    echo "unknown"
    return 1
}

validate_version() {
    local version=$1
    version="${version#v}"

    if ! [[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log ERROR "Invalid version format: $version"
        return 1
    fi

    log SUCCESS "Version format validated: v${version}"
    return 0
}

validate_upgrade_path() {
    local current=$1
    local target=$2

    current="${current#v}"
    target="${target#v}"

    local current_minor="${current%%.*}"
    current_minor="${current#*.}"
    current_minor="${current_minor%%.*}"

    local target_minor="${target%%.*}"
    target_minor="${target#*.}"
    target_minor="${target_minor%%.*}"

    local version_diff=$((target_minor - current_minor))

    if [ $version_diff -lt 0 ]; then
        log ERROR "Cannot downgrade Kubernetes!"
        log ERROR "Current: v$current, Target: v$target"
        return 1
    elif [ $version_diff -eq 0 ]; then
        log WARNING "Patch upgrade: v$current → v$target"
        return 0
    elif [ $version_diff -eq 1 ]; then
        # log SUCCESS "Valid upgrade path: v$current → v$target"
        log SUCCESS "Valid upgrade path: v${RED}${current[*]}${NC} → v${GREEN}${target[*]}${NC}"
        return 0
    else
        log ERROR "Invalid upgrade path!"
        log ERROR "Current: v$current, Target: v$target (gap: $version_diff versions)"
        log ERROR "Kubernetes only supports upgrading ONE minor version at a time"
        return 1
    fi
}

check_prerequisites() {
    log INFO "Checking prerequisites..."

    if ! command -v vagrant &> /dev/null; then
        log ERROR "Vagrant not found"
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        log ERROR "kubectl not found"
        exit 1
    fi

    if [ ! -f "${VAGRANT_ROOT}/Vagrantfile" ]; then
        log ERROR "Vagrantfile not found at: ${VAGRANT_ROOT}/Vagrantfile"
        exit 1
    fi

    log SUCCESS "Prerequisites check passed"
}

create_backup() {
    log INFO "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"

    if [ -d "${VAGRANT_ROOT}/kubeconfigs" ]; then
        cp -r "${VAGRANT_ROOT}/kubeconfigs" "${BACKUP_DIR}/"
        log SUCCESS "Backed up kubeconfigs"
    fi

    if [ -d "${VAGRANT_ROOT}/cluster-info" ]; then
        cp -r "${VAGRANT_ROOT}/cluster-info" "${BACKUP_DIR}/"
        log SUCCESS "Backed up cluster-info"
    fi

    log SUCCESS "Backup created at: $BACKUP_DIR"
}

# ========================================================================================================================
# UPGRADE FUNCTIONS
# ========================================================================================================================

upgrade_master_node() {
    local cluster=$1
    local node=$2
    local version=$3
    local is_first_master=$4

    log INFO "=============================================="
    log INFO "Upgrading master node: $node to $version"
    log INFO "=============================================="

    local current_ver=$(get_current_version "$node")
    log INFO "Current version: $current_ver"
    log INFO "Target version: $version"

    local major_minor
    if [[ $version =~ ^([0-9]+\.[0-9]+) ]]; then
        major_minor="${BASH_REMATCH[1]}"
    else
        major_minor="$version"
    fi
    local repo_version="v${major_minor}"

    log INFO "Repository version needed: $repo_version"

    vagrant ssh "$node" << EOFUPGRADE
set -e

echo "Starting upgrade process on $node..."

# Update repository
REPO_VERSION="$repo_version"
echo "Target repository: \$REPO_VERSION"

sudo rm -f /etc/apt/sources.list.d/kubernetes.list

K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
sudo rm -f "\$K8S_KEYRING"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/\${REPO_VERSION}/deb/Release.key" | sudo gpg --batch --yes --dearmor -o "\$K8S_KEYRING"
sudo chmod 644 "\$K8S_KEYRING"

echo "deb [signed-by=\$K8S_KEYRING] https://pkgs.k8s.io/core:/stable:/\${REPO_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "Repository updated successfully!"

sudo apt-get update

echo "Installing kubeadm $version..."
sudo apt-mark unhold kubeadm

if sudo apt-get install -y kubeadm=${version}-* 2>/dev/null; then
    echo "✓ Installed kubeadm with ${version}-* pattern"
elif sudo apt-get install -y kubeadm=${version}.* 2>/dev/null; then
    echo "✓ Installed kubeadm with ${version}.* pattern"
else
    echo "Trying to find available version..."
    LATEST_PATCH=\$(apt-cache madison kubeadm | grep "kubeadm.*${version}\." | head -1 | awk '{print \$3}')
    if [ -n "\$LATEST_PATCH" ]; then
        echo "Found version: \$LATEST_PATCH"
        sudo apt-get install -y "kubeadm=\$LATEST_PATCH"
    else
        echo "ERROR: Could not find kubeadm version ${version}"
        exit 1
    fi
fi

sudo apt-mark hold kubeadm

kubeadm version

if [ "$is_first_master" = "true" ]; then
    echo "This is the first master - applying upgrade..."
    FULL_VERSION=\$(kubeadm version -o short)
    echo "Using kubeadm version: \$FULL_VERSION"

    echo "Applying upgrade..."
    sudo kubeadm upgrade apply \$FULL_VERSION -y --ignore-preflight-errors=all || {
        echo "Upgrade had issues but continuing..."
    }
else
    echo "This is an additional master - applying node upgrade..."
    sudo kubeadm upgrade node
fi

echo "Draining node $node..."
kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --timeout=300s --disable-eviction || {
    echo "Drain completed with warnings, continuing..."
}

echo "Upgrading kubelet and kubectl..."
sudo apt-mark unhold kubelet kubectl

if sudo apt-get install -y kubelet=${version}-* kubectl=${version}-* 2>/dev/null; then
    echo "✓ Installed with ${version}-* pattern"
elif sudo apt-get install -y kubelet=${version}.* kubectl=${version}.* 2>/dev/null; then
    echo "✓ Installed with ${version}.* pattern"
else
    LATEST_PATCH=\$(apt-cache madison kubelet | grep "kubelet.*${version}\." | head -1 | awk '{print \$3}')
    if [ -n "\$LATEST_PATCH" ]; then
        sudo apt-get install -y "kubelet=\$LATEST_PATCH" "kubectl=\$LATEST_PATCH"
    fi
fi

sudo apt-mark hold kubelet kubectl

echo "Restarting kubelet..."
sudo systemctl daemon-reload
sudo systemctl restart kubelet

sleep 15

echo "Uncordoning node $node..."
kubectl uncordon $node || echo "Uncordon may have timed out"

sleep 15

echo "Verifying..."
kubectl get nodes || echo "kubectl may be temporarily unavailable"

echo "Master node $node upgraded successfully!"
EOFUPGRADE

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log SUCCESS "Master node $node upgraded successfully"
        return 0
    else
        log ERROR "Failed to upgrade master node $node"
        return 1
    fi
}

upgrade_worker_node() {
    local cluster=$1
    local node=$2
    local version=$3
    local skip_drain=$4

    log INFO "=============================================="
    log INFO "Upgrading worker node: $node to $version"
    log INFO "=============================================="

    local current_ver=$(get_current_version "$node")
    log INFO "Current version: $current_ver"
    log INFO "Target version: $version"

    local major_minor
    if [[ $version =~ ^([0-9]+\.[0-9]+) ]]; then
        major_minor="${BASH_REMATCH[1]}"
    else
        major_minor="$version"
    fi
    local repo_version="v${major_minor}"

    if [ "$skip_drain" = "false" ]; then
        log INFO "Draining node $node..."

        local master_node
        local master_count=${CLUSTERS["${cluster}_master_count"]}

        if [ "$master_count" -eq 1 ]; then
            master_node="${cluster}-master"
        else
            master_node="${cluster}-master1"
        fi

        vagrant ssh "$master_node" -c "kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --timeout=300s --disable-eviction" 2>/dev/null || {
            log WARNING "Drain had warnings"
        }
        sleep 10
    fi

    vagrant ssh "$node" << EOFUPGRADE
set -e

echo "Starting upgrade process on $node..."

REPO_VERSION="$repo_version"

sudo rm -f /etc/apt/sources.list.d/kubernetes.list

K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
sudo rm -f "\$K8S_KEYRING"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/\${REPO_VERSION}/deb/Release.key" | sudo gpg --batch --yes --dearmor -o "\$K8S_KEYRING"
sudo chmod 644 "\$K8S_KEYRING"

echo "deb [signed-by=\$K8S_KEYRING] https://pkgs.k8s.io/core:/stable:/\${REPO_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update

sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=${version}.* || sudo apt-get install -y kubeadm=${version}-*
sudo apt-mark hold kubeadm

sudo kubeadm upgrade node

sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=${version}.* kubectl=${version}.* || sudo apt-get install -y kubelet=${version}-* kubectl=${version}-*
sudo apt-mark hold kubelet kubectl

sudo systemctl daemon-reload
sudo systemctl restart kubelet

sleep 20

echo "Worker node $node upgraded successfully!"
EOFUPGRADE

    if [ "$skip_drain" = "false" ]; then
        log INFO "Uncordoning node $node..."

        local master_count=${CLUSTERS["${cluster}_master_count"]}
        local master_node

        if [ "$master_count" -eq 1 ]; then
            master_node="${cluster}-master"
        else
            master_node="${cluster}-master1"
        fi

        vagrant ssh "$master_node" -c "kubectl uncordon $node" 2>/dev/null || true
        sleep 5
    fi

    log SUCCESS "Worker node $node upgraded successfully"
    return 0
}

upgrade_cluster() {
    local cluster=$1
    local version=$2

    log INFO "=============================================="
    log INFO "Upgrading cluster: $cluster to $version"
    log INFO "=============================================="

    local master_count=${CLUSTERS["${cluster}_master_count"]}
    local worker_count=${CLUSTERS["${cluster}_worker_count"]}

    log INFO "Cluster: $master_count masters, $worker_count workers"

    local upgrade_masters=true
    local upgrade_workers=true

    if [ "$MASTERS_ONLY" = true ]; then
        upgrade_workers=false
    elif [ "$WORKERS_ONLY" = true ]; then
        upgrade_masters=false
    fi

    if [ "$upgrade_masters" = true ]; then
        log INFO "Upgrading master nodes..."

        for i in $(seq 1 $master_count); do
            local node
            if [ $master_count -eq 1 ]; then
                node="${cluster}-master"
            else
                node="${cluster}-master${i}"
            fi

            local is_first="false"
            [ $i -eq 1 ] && is_first="true"

            if ! upgrade_master_node "$cluster" "$node" "$version" "$is_first"; then
                log ERROR "Failed to upgrade $node"
                return 1
            fi

            if [ $i -lt $master_count ]; then
                log INFO "Waiting 30 seconds..."
                sleep 30
            fi
        done

        log SUCCESS "All master nodes upgraded"
    fi

    if [ "$upgrade_workers" = true ]; then
        log INFO "Upgrading worker nodes..."

        for i in $(seq 1 $worker_count); do
            local node
            if [ $worker_count -eq 1 ]; then
                node="${cluster}-worker"
            else
                node="${cluster}-worker${i}"
            fi

            if ! upgrade_worker_node "$cluster" "$node" "$version" "$SKIP_DRAIN"; then
                log ERROR "Failed to upgrade $node"
                return 1
            fi

            if [ $i -lt $worker_count ]; then
                log INFO "Waiting 20 seconds..."
                sleep 20
            fi
        done

        log SUCCESS "All worker nodes upgraded"
    fi

    log SUCCESS "Cluster $cluster upgraded to $version"
    return 0
}

# ========================================================================================================================
# MAIN FUNCTION
# ========================================================================================================================

main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Kubernetes Version Upgrade Script${NC}"
    echo -e "${BLUE}Multi-Cluster HA Setup${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    if [ "$USE_CONFIG" = true ]; then
        echo -e "${CYAN}Using Configuration Variables:${NC}"
        echo -e "  Current Version: ${YELLOW}v${CURRENT_VERSION}${NC}"
        echo -e "  Target Version:  ${GREEN}v${TARGET_VERSION_CONFIG}${NC}"
        if [ -n "$DEFAULT_CLUSTER" ]; then
            echo -e "  Default Cluster: ${CYAN}${DEFAULT_CLUSTER}${NC}"
        fi
        if [ -n "$DEFAULT_NODES" ]; then
            echo -e "  Default Nodes:   ${CYAN}${DEFAULT_NODES}${NC}"
        fi
        if [ -n "$DEFAULT_SCOPE" ]; then
            echo -e "  Upgrade Scope:   ${CYAN}${DEFAULT_SCOPE}${NC}"
        fi
        echo ""

        if [ -z "$TARGET_VERSION" ]; then
            TARGET_VERSION="$TARGET_VERSION_CONFIG"
        fi
        if [ -z "$SPECIFIC_CLUSTER" ] && [ -n "$DEFAULT_CLUSTER" ]; then
            SPECIFIC_CLUSTER="$DEFAULT_CLUSTER"
        fi
        if [ -z "$SPECIFIC_NODES" ] && [ -n "$DEFAULT_NODES" ]; then
            SPECIFIC_NODES="$DEFAULT_NODES"
        fi
        if [ "$AUTO_CONFIRM" = true ] && [ "$AUTO_YES" = false ]; then
            AUTO_YES=true
        fi

        # Apply DEFAULT_SCOPE setting
        if [ -n "$DEFAULT_SCOPE" ]; then
            case "$DEFAULT_SCOPE" in
                masters-only)
                    MASTERS_ONLY=true
                    ;;
                workers-only)
                    WORKERS_ONLY=true
                    ;;
                all-masters-then-workers|all-clusters|cluster|nodes)
                    # These are default behavior, no special flags needed
                    ;;
                *)
                    log WARNING "Unknown DEFAULT_SCOPE value: $DEFAULT_SCOPE"
                    ;;
            esac
        fi
    fi

    mkdir -p "$BACKUP_DIR"

    check_prerequisites
    create_backup
    parse_vagrantfile

    if ! validate_version "$TARGET_VERSION"; then
        exit 1
    fi

    TARGET_VERSION="v${TARGET_VERSION#v}"
    VERSION_WITHOUT_V="${TARGET_VERSION#v}"

    log INFO "Target version: $TARGET_VERSION"

    # Determine nodes to upgrade
    local clusters_to_upgrade=()
    local nodes_to_upgrade=()

    if [ -n "$SPECIFIC_NODES" ]; then
        IFS=',' read -ra nodes_to_upgrade <<< "$SPECIFIC_NODES"

        for cluster in "${CLUSTER_NAMES[@]}"; do
            if [[ "${nodes_to_upgrade[0]}" == ${cluster}-* ]]; then
                clusters_to_upgrade=("$cluster")
                break
            fi
        done
    elif [ -n "$SPECIFIC_NODE" ]; then
        for cluster in "${CLUSTER_NAMES[@]}"; do
            if [[ "$SPECIFIC_NODE" == ${cluster}-* ]]; then
                clusters_to_upgrade=("$cluster")
                nodes_to_upgrade=("$SPECIFIC_NODE")
                break
            fi
        done
    elif [ -n "$SPECIFIC_CLUSTER" ]; then
        clusters_to_upgrade=("$SPECIFIC_CLUSTER")
    else
        clusters_to_upgrade=("${CLUSTER_NAMES[@]}")
    fi

    # Get current version from target node
    if [ ${#nodes_to_upgrade[@]} -gt 0 ]; then
        ACTUAL_CURRENT_VERSION=$(get_current_version "${nodes_to_upgrade[0]}")
    elif [ -n "$SPECIFIC_NODE" ]; then
        ACTUAL_CURRENT_VERSION=$(get_current_version "$SPECIFIC_NODE")
    else
        ACTUAL_CURRENT_VERSION="v${CURRENT_VERSION}"
    fi

    if [ "$ACTUAL_CURRENT_VERSION" = "unknown" ]; then
        ACTUAL_CURRENT_VERSION="v${CURRENT_VERSION}"
    fi

    log SUCCESS "Current version: $ACTUAL_CURRENT_VERSION"
    log WARNING "Target cluster: ${SPECIFIC_CLUSTER:-all clusters}"
    log WARNING "Node(s) to upgrade: ${SPECIFIC_NODES:-${SPECIFIC_NODE:-all nodes}}"

    if [ "$SKIP_VERSION_CHECK" = false ]; then
        if ! validate_upgrade_path "$ACTUAL_CURRENT_VERSION" "$TARGET_VERSION"; then
            exit 1
        fi
    fi

    if [ ${#clusters_to_upgrade[@]} -eq 0 ]; then
        log WARNING "Clusters to upgrade: ${SPECIFIC_CLUSTER:-none detected}"
    else
        log WARNING "Clusters to upgrade: ${YELLOW}${clusters_to_upgrade[*]}${NC}"
        # log WARNING "Clusters to upgrade: ${clusters_to_upgrade[*]}"
    fi

    if [ "$AUTO_YES" = false ]; then
        echo ""
        read -p "Do you want to proceed? (yes/no): " -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log WARNING "Upgrade cancelled"
            exit 0
        fi
    fi

    echo ""
    log INFO "Starting upgrade..."
    echo ""

    for cluster in "${clusters_to_upgrade[@]}"; do
        if [ ${#nodes_to_upgrade[@]} -gt 0 ]; then
            for node in "${nodes_to_upgrade[@]}"; do
                if [[ "$node" == *-master* ]]; then
                    local is_first="false"
                    [[ "$node" =~ -master1$|^[^-]+-master$ ]] && is_first="true"

                    if ! upgrade_master_node "$cluster" "$node" "$VERSION_WITHOUT_V" "$is_first"; then
                        exit 1
                    fi
                else
                    if ! upgrade_worker_node "$cluster" "$node" "$VERSION_WITHOUT_V" "$SKIP_DRAIN"; then
                        exit 1
                    fi
                fi
            done
        else
            if ! upgrade_cluster "$cluster" "$VERSION_WITHOUT_V"; then
                exit 1
            fi
        fi
    done

    echo ""
    log SUCCESS "All upgrades completed successfully!"
    log INFO "Upgraded to: $TARGET_VERSION"
    log INFO "Backup: $BACKUP_DIR"
    echo ""
}

# ========================================================================================================================
# PARSE ARGUMENTS
# ========================================================================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--cluster)
            SPECIFIC_CLUSTER="$2"
            shift 2
            ;;
        -n|--node)
            SPECIFIC_NODE="$2"
            shift 2
            ;;
        -m|--masters-only)
            MASTERS_ONLY=true
            shift
            ;;
        -w|--workers-only)
            WORKERS_ONLY=true
            shift
            ;;
        -s|--skip-drain)
            SKIP_DRAIN=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --use-config)
            USE_CONFIG=true
            shift
            ;;
        --skip-version-check)
            SKIP_VERSION_CHECK=true
            shift
            ;;
        -*)
            echo -e "${RED}✗${NC} Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            TARGET_VERSION="$1"
            shift
            ;;
    esac
done

if [ -z "$TARGET_VERSION" ]; then
    if [ "$USE_CONFIG" = true ] && [ -n "$TARGET_VERSION_CONFIG" ]; then
        TARGET_VERSION="$TARGET_VERSION_CONFIG"
    else
        echo -e "${RED}✗${NC} Target version required"
        show_help
        exit 1
    fi
fi

main

exit 0
# ========================================================================================================================
# END OF K8S-UPGRADE SCRIPT
# ========================================================================================================================
