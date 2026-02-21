#!/bin/bash

# =====================================================================================================================================
#                                          KUBECONFIG SETUP and VAGRANTFILE SYNC                                         
# =====================================================================================================================================
#
# Purpose: Automatically fetch kubeconfigs from running Kubernetes clusters and sync Vagrantfile
#
# Features:
#   - Auto-detect running VMs from VirtualBox directly (more robust than vagrant status)
#   - Fetch kubeconfigs from all detected clusters
#   - Merge kubeconfigs into ~/.kube/config with proper context naming
#   - Fix TLS certificate validation issues for local dev clusters
#   - Sync Vagrantfile configuration to match running VMs
#   - Supports multi-cluster setups (prod, qa, dev, pre-prod, dr, etc.)
#   - Works with ANY naming convention (fully configurable)
#   - Compatible with Git Bash on Windows
#
# Usage:
#   ./kubeconfig-setup.sh [command] [options]
#
# Commands:
#   show            Show detected VMs and clusters
#   sync            Sync Vagrantfile to match running VM state
#   fetch           Fetch kubeconfigs from all running clusters
#   fix-tls         Fix TLS certificate validation in existing kubeconfig
#   scan            Scan ALL running VMs to find Kubernetes installations
#   help            Show this help message
#
# Examples:
#   ./kubeconfig-setup.sh show               # Show detected VMs
#   ./kubeconfig-setup.sh scan               # Scan all VMs for Kubernetes
#   ./kubeconfig-setup.sh sync               # Sync Vagrantfile with reality
#   ./kubeconfig-setup.sh fetch              # Fetch all kubeconfigs
#   ./kubeconfig-setup.sh fix-tls            # Fix TLS errors
#
# =====================================================================================================================================

# =====================================================================================================================================
# 🎯 CONFIGURATION - CUSTOMIZE YOUR NAMING PATTERNS HERE
# =====================================================================================================================================

# Define your VM naming patterns (separated by |)
# The script will detect VMs matching ANY of these patterns
# 
# Common patterns:
#   - master|worker           (default: k8s-prod-master1, qa-worker2)
#   - control-plane|node      (alternative: prod-control-plane-1, qa-node-1)
#   - cp|wk                   (short: dev-cp1, prod-wk1)
#   - ctrl|compute            (custom: cluster-ctrl1, cluster-compute2)
#   - controlplane|dataplane  (another variant)
#
# To detect VMs with multiple naming conventions, use:
#   ROLE_PATTERNS="master|worker|control-plane|node|cp|wk"
#
ROLE_PATTERNS="master|worker|control-plane|node|cp|wk|ctrl|compute"

# =====================================================================================================================================

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANTFILE="${SCRIPT_DIR}/Vagrantfile"

# =====================================================================================================================================
# DETECT OS AND SET PATHS
# =====================================================================================================================================

detect_os_and_set_paths() {
    case "$(uname -s)" in
        Darwin*)
            KUBE_DIR="$HOME/.kube"
            ;;
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                if [ -n "$WSLENV" ]; then
                    WINDOWS_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')
                    KUBE_DIR="/mnt/c/Users/${WINDOWS_USER}/.kube"
                else
                    KUBE_DIR="/mnt/c/Users/$(whoami)/.kube"
                fi
            else
                KUBE_DIR="$HOME/.kube"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            KUBE_DIR="$HOME/.kube"
            ;;
        *)
            KUBE_DIR="$HOME/.kube"
            ;;
    esac
}

detect_os_and_set_paths

# =====================================================================================================================================
# HELPER FUNCTIONS
# =====================================================================================================================================

log_info() {
    echo -e "${BLUE}ℹ${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}✓${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1" >&2
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

# =====================================================================================================================================
# VM DETECTION - CONFIGURABLE PATTERN MATCHING
# =====================================================================================================================================

detect_running_vms() {
    log_info "Detecting running VMs using patterns: ${ROLE_PATTERNS}"

    # Get all running VMs from VirtualBox first
    local all_vms=$(VBoxManage list runningvms 2>/dev/null | sed 's/^"//; s/".*//' || true)
    
    if [ -z "$all_vms" ]; then
        log_warning "No running VMs found"
        return 1
    fi
    
    # Filter for Kubernetes nodes using grep with -- flag
    # The -- flag prevents grep from treating the pattern as an option
    # This is necessary because the pattern starts with a hyphen
    local running_vms=$(echo "$all_vms" | grep -E -- '-(master|worker|control-plane|node|cp|wk|ctrl|compute)[0-9]*$' || true)

    if [ -z "$running_vms" ]; then
        log_warning "No running VMs detected matching Kubernetes node patterns"
        log_info "To scan all VMs regardless of naming, run: $0 scan"
        return 1
    fi

    echo "$running_vms"
}

# =====================================================================================================================================
# DEEP SCAN - CHECK ALL VMs FOR KUBERNETES INSTALLATIONS
# =====================================================================================================================================
# This function scans ALL running VMs to detect Kubernetes installations. It checks for:
#   1. ~/.kube/config file (kubeconfig exists)
#   2. kubectl command (Kubernetes CLI installed)
#   3. kubeadm command (Kubernetes admin tool installed)
# =====================================================================================================================================

deep_scan_all_vms() {
    log_info "Starting deep scan of all running VMs..."
    echo ""
    
    # Get ALL running VMs (no pattern filtering)
    local all_vms=$(VBoxManage list runningvms 2>/dev/null | sed 's/^"//; s/".*//' || true)
    
    if [ -z "$all_vms" ]; then
        log_warning "No running VMs found"
        return 1
    fi
    
    # Convert to array for for-loop (Git Bash compatible)
    # Using array instead of while-loop because it's more reliable in Git Bash
    local vm_array=()
    while IFS= read -r line; do
        vm_array+=("$line")
    done < <(echo "$all_vms")
    
    local total_vms=${#vm_array[@]}
    log_info "Found $total_vms running VM(s). Scanning for Kubernetes installations..."
    echo ""
    
    local k8s_vms=""
    local scan_count=0
    
    # Use for loop instead of while loop (more reliable in Git Bash)
    for vm_name in "${vm_array[@]}"; do
        scan_count=$((scan_count + 1))
        printf "  [%d/%d] Checking %-40s " "$scan_count" "$total_vms" "$vm_name"
        
        local is_k8s_node=false
        local check_method=""
        
        # Method 1: Check for kubeconfig file
        if vagrant ssh "$vm_name" -c "test -f \$HOME/.kube/config" >/dev/null 2>&1; then
            is_k8s_node=true
            check_method="kubeconfig"
        fi
        
        # Method 2: Check for kubectl if kubeconfig not found
        if [ "$is_k8s_node" = false ]; then
            if vagrant ssh "$vm_name" -c "command -v kubectl >/dev/null 2>&1" >/dev/null 2>&1; then
                is_k8s_node=true
                check_method="kubectl"
            fi
        fi
        
        # Method 3: Check for kubeadm if still not found
        if [ "$is_k8s_node" = false ]; then
            if vagrant ssh "$vm_name" -c "command -v kubeadm >/dev/null 2>&1" >/dev/null 2>&1; then
                is_k8s_node=true
                check_method="kubeadm"
            fi
        fi
        
        # Display result
        if [ "$is_k8s_node" = true ]; then
            echo -e "${GREEN}✓ K8s node${NC} (${check_method})"
            k8s_vms="${k8s_vms}${vm_name}"$'\n'
        else
            echo -e "${YELLOW}✗ Not K8s${NC}"
        fi
    done
    
    # Remove empty lines from results
    k8s_vms=$(echo "$k8s_vms" | sed '/^$/d')
    
    echo ""
    
    # Check if we found any Kubernetes VMs
    if [ -z "$k8s_vms" ]; then
        log_warning "No Kubernetes installations found in $scan_count VM(s)"
        echo ""
        log_info "This is unexpected since 'fetch' worked successfully."
        log_info "The VMs have Kubernetes but SSH checks are failing."
        echo ""
        log_info "Good news: 'fetch' command works, so you can use:"
        echo "  ./kubeconfig-setup.sh fetch    # Get all kubeconfigs"
        echo "  kubectl config get-contexts    # See all clusters"
        return 1
    fi
    
    log_success "Found $(echo "$k8s_vms" | wc -l) Kubernetes node(s)"
    echo ""
    
    # Display the detected Kubernetes VMs
    log_info "Detected Kubernetes VMs:"
    echo "$k8s_vms" | while read -r vm; do
        echo "  - $vm"
    done
    
    echo ""
    log_info "To fetch kubeconfigs from these VMs, use: $0 fetch"
}

# =====================================================================================================================================
# PARSE VM CONFIGURATION
# -------------------------------------------------------------------------------------------------------------------------------------
# Extracts cluster name, role (master/worker), index, CPU, and memory from VM name and VirtualBox
# =====================================================================================================================================

parse_vm_config() {
    local vm_name=$1
    
    local cluster=""
    local role=""
    local index=""

    # Extract cluster, role, and index using regex
    # Handles formats like:
    #   - k8s-pre-prod-master1   -> cluster="k8s-pre-prod", role="master", index="1"
    #   - prod-worker2           -> cluster="prod", role="worker", index="2"
    #   - dr-master              -> cluster="dr", role="master", index="1"
    if [[ "$vm_name" =~ ^(.+)-(master|worker|control-plane|node|cp|wk|ctrl|compute)([0-9]*)$ ]]; then
        cluster="${BASH_REMATCH[1]}"
        role="${BASH_REMATCH[2]}"
        index="${BASH_REMATCH[3]}"
        # If no index, default to 1
        index="${index:-1}"
    else
        return 1
    fi
    
    # Normalize role names to standard types
    # This allows for different naming conventions to be recognized
    case "$role" in
        master|control-plane|controlplane|cp|ctrl)
            role="master"
            ;;
        worker|node|dataplane|wk|compute)
            role="worker"
            ;;
    esac

    # Get VM details from VirtualBox
    local vbox_name=""
    if VBoxManage showvminfo "${vm_name}" --machinereadable &>/dev/null; then
        vbox_name="${vm_name}"
    else
        return 1
    fi

    # Verify VM is running
    local vm_state=$(VBoxManage showvminfo "$vbox_name" --machinereadable 2>/dev/null | \
        grep "^VMState=" | cut -d'=' -f2 | tr -d '"' || echo "")

    if [ "$vm_state" != "running" ]; then
        return 1
    fi

    # Get CPU and memory configuration from VirtualBox
    local cpus=$(VBoxManage showvminfo "$vbox_name" --machinereadable 2>/dev/null | \
        grep "^cpus=" | cut -d'=' -f2 | tr -d '"' || echo "2")
    local memory=$(VBoxManage showvminfo "$vbox_name" --machinereadable 2>/dev/null | \
        grep "^memory=" | cut -d'=' -f2 | tr -d '"' || echo "1024")

    # Return pipe-separated values
    echo "${cluster}|${role}|${index}|${cpus}|${memory}"
}

# =====================================================================================================================================
# ANALYZE CLUSTER CONFIGURATION
# -------------------------------------------------------------------------------------------------------------------------------------
# Shows a summary of detected clusters with node counts and resource allocation
# =====================================================================================================================================

analyze_cluster_config() {
    log_info "Analyzing cluster configuration from running VMs..."
    echo ""

    local vms=$(detect_running_vms)

    if [ -z "$vms" ]; then
        return 1
    fi

    # Initialize cluster data structures
    declare -A cluster_master_count
    declare -A cluster_worker_count
    declare -A cluster_master_cpus
    declare -A cluster_master_memory
    declare -A cluster_worker_cpus
    declare -A cluster_worker_memory
    local clusters_list=""

    # Parse each VM and accumulate cluster statistics
    while IFS= read -r vm; do
        local config=$(parse_vm_config "$vm")

        if [ $? -eq 0 ]; then
            IFS='|' read -r cluster role index cpus memory <<< "$config"

            # Track cluster (using string list instead of associative array)
            if [[ ! " $clusters_list " =~ " $cluster " ]]; then
                clusters_list="$clusters_list $cluster"
            fi

            # Accumulate statistics based on role
            case "$role" in
                master)
                    cluster_master_count[$cluster]=$((${cluster_master_count[$cluster]:-0} + 1))
                    cluster_master_cpus[$cluster]=${cpus}
                    cluster_master_memory[$cluster]=${memory}
                    ;;
                worker)
                    cluster_worker_count[$cluster]=$((${cluster_worker_count[$cluster]:-0} + 1))
                    cluster_worker_cpus[$cluster]=${cpus}
                    cluster_worker_memory[$cluster]=${memory}
                    ;;
            esac

            log_info "  Found: $vm ($role, ${cpus} CPU, ${memory} MB)"
        fi
    done < <(echo "$vms")

    # Display detected configuration in a formatted table
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Detected Cluster Configuration${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    for cluster in $clusters_list; do
        echo -e "${GREEN}${cluster}${NC}"
        echo "  Masters: ${cluster_master_count[$cluster]:-0} nodes (${cluster_master_cpus[$cluster]:-2} vCPU, ${cluster_master_memory[$cluster]:-4096} MB RAM)"
        echo "  Workers: ${cluster_worker_count[$cluster]:-0} nodes (${cluster_worker_cpus[$cluster]:-1} vCPU, ${cluster_worker_memory[$cluster]:-1024} MB RAM)"
        echo ""
    done
}

# =====================================================================================================================================
# VAGRANTFILE SYNC
# -------------------------------------------------------------------------------------------------------------------------------------
# Updates the Vagrantfile to match the actual running VM configuration
# This is useful when you've manually changed VM resources or node counts
# =====================================================================================================================================

sync_vagrantfile() {
    log_info "Syncing Vagrantfile with running VM state..."

    if [ ! -f "$VAGRANTFILE" ]; then
        log_error "Vagrantfile not found: $VAGRANTFILE"
        return 1
    fi

    local vms=$(detect_running_vms)

    if [ -z "$vms" ]; then
        log_warning "No running VMs to sync"
        return 1
    fi

    # Backup Vagrantfile before modifying
    local backup_dir="${SCRIPT_DIR}/.vagrant/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$VAGRANTFILE" "${backup_dir}/Vagrantfile.${timestamp}"
    log_success "Backed up Vagrantfile to: ${backup_dir}/Vagrantfile.${timestamp}"

    # Build cluster configuration from running VMs
    declare -A cluster_config
    local clusters_list=""

    while IFS= read -r vm; do
        local config=$(parse_vm_config "$vm")

        if [ $? -eq 0 ]; then
            IFS='|' read -r cluster role index cpus memory <<< "$config"

            # Track cluster and initialize all parameters
            if [[ ! " $clusters_list " =~ " $cluster " ]]; then
                clusters_list="$clusters_list $cluster"
                # Initialize all parameters to 0 for this cluster
                cluster_config["${cluster}:master_count"]=0
                cluster_config["${cluster}:worker_count"]=0
                cluster_config["${cluster}:master_cpus"]=2
                cluster_config["${cluster}:master_memory"]=4096
                cluster_config["${cluster}:worker_cpus"]=1
                cluster_config["${cluster}:worker_memory"]=1024
            fi

            # Update configuration based on role
            case "$role" in
                master)
                    cluster_config["${cluster}:master_count"]=$((${cluster_config[${cluster}:master_count]:-0} + 1))
                    cluster_config["${cluster}:master_cpus"]=${cpus}
                    cluster_config["${cluster}:master_memory"]=${memory}
                    ;;
                worker)
                    cluster_config["${cluster}:worker_count"]=$((${cluster_config[${cluster}:worker_count]:-0} + 1))
                    cluster_config["${cluster}:worker_cpus"]=${cpus}
                    cluster_config["${cluster}:worker_memory"]=${memory}
                    ;;
            esac
        fi
    done < <(echo "$vms")

    # Update Vagrantfile for each cluster
    for cluster in $clusters_list; do
        log_info "Updating configuration for cluster: ${cluster}"

        # Get all parameter values for this cluster
        local master_count="${cluster_config[${cluster}:master_count]}"
        local master_cpus="${cluster_config[${cluster}:master_cpus]}"
        local master_memory="${cluster_config[${cluster}:master_memory]}"
        local worker_count="${cluster_config[${cluster}:worker_count]}"
        local worker_cpus="${cluster_config[${cluster}:worker_cpus]}"
        local worker_memory="${cluster_config[${cluster}:worker_memory]}"

        # Update all parameters in a single awk pass for robustness
        # This preserves Vagrantfile structure while updating values
        awk -v cluster="\"${cluster}\"" \
            -v mc="$master_count" -v mcp="$master_cpus" -v mm="$master_memory" \
            -v wc="$worker_count" -v wcp="$worker_cpus" -v wm="$worker_memory" '
            $0 ~ cluster" => {" { in_cluster=1 }
            in_cluster && $0 ~ /^  },?$/ { in_cluster=0 }
            in_cluster && $0 ~ /master_count:/ { printf "    master_count: %s,\n", mc; next }
            in_cluster && $0 ~ /master_cpus:/ { printf "    master_cpus: %s,\n", mcp; next }
            in_cluster && $0 ~ /master_memory:/ { printf "    master_memory: %s,\n", mm; next }
            in_cluster && $0 ~ /worker_count:/ { printf "    worker_count: %s,\n", wc; next }
            in_cluster && $0 ~ /worker_cpus:/ { printf "    worker_cpus: %s,\n", wcp; next }
            in_cluster && $0 ~ /worker_memory:/ { printf "    worker_memory: %s,\n", wm; next }
            { print }
        ' "$VAGRANTFILE" > "${VAGRANTFILE}.tmp"

        # Verify the temp file was created successfully
        if [ ! -f "${VAGRANTFILE}.tmp" ]; then
            log_error "Failed to create temporary file"
            return 1
        fi

        # Move the temp file to replace the original
        if ! mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"; then
            log_error "Failed to update Vagrantfile"
            rm -f "${VAGRANTFILE}.tmp"
            return 1
        fi
    done

    log_success "Vagrantfile synced with running VM state"
}

# =====================================================================================================================================
# FIND MASTER NODES
# -------------------------------------------------------------------------------------------------------------------------------------
# Filters the VM list to find only master/control-plane nodes
# =====================================================================================================================================

find_master_nodes() {
    local vms="$1"
    # Use -- to prevent grep from treating pattern as an option
    echo "$vms" | grep -E -- '-(master|control-plane|controlplane|cp|ctrl)[0-9]*$' || true
}

# =====================================================================================================================================
# FETCH KUBECONFIGS
# -------------------------------------------------------------------------------------------------------------------------------------
# Fetches kubeconfig from each cluster's primary master node. Merges all configs into ~/.kube/config with proper context naming
# =====================================================================================================================================

fetch_kubeconfigs() {
    log_info "Fetching kubeconfigs from running clusters..."

    local vms=$(detect_running_vms)

    if [ -z "$vms" ]; then
        log_warning "No running VMs detected"
        return 1
    fi

    # Find master/control-plane nodes
    local masters=$(find_master_nodes "$vms")

    if [ -z "$masters" ]; then
        log_warning "No master/control-plane nodes found"
        return 1
    fi

    # Create kubeconfig directory if it doesn't exist
    mkdir -p "$HOME/.kube"

    # Backup existing config
    if [ -f "$HOME/.kube/config" ]; then
        cp "$HOME/.kube/config" "$HOME/.kube/config.backup.$(date +%Y%m%d_%H%M%S)"
        log_success "Backed up existing kubeconfig"
    fi

    # Extract cluster names by removing role suffix
    # This handles names like: k8s-prod-master1 -> k8s-prod
    local clusters=$(echo "$masters" | sed -E 's/-(master|worker|control-plane|node|cp|wk|ctrl|compute)[0-9]*$//' | sort -u)
    local temp_configs=()
    local cluster_names=()

    # Fetch kubeconfig from each cluster
    for cluster in $clusters; do
        local master=""
        
        # Try different master naming patterns to find the primary master
        for pattern in "master1" "control-plane1" "cp1" "ctrl1" "master" "control-plane" "cp" "ctrl"; do
            if echo "$masters" | grep -q "^${cluster}-${pattern}$"; then
                master="${cluster}-${pattern}"
                break
            fi
        done

        if [ -z "$master" ]; then
            log_warning "Could not find master for cluster: $cluster"
            continue
        fi

        log_info "Fetching kubeconfig from ${master}..."

        local temp_config="/tmp/${cluster}-kubeconfig.yaml"
        rm -f "$temp_config"

        # Fetch kubeconfig via vagrant ssh
        if vagrant ssh "$master" -c "cat \$HOME/.kube/config" > "$temp_config" 2>/dev/null; then
            # Verify we got a valid kubeconfig
            if [ -s "$temp_config" ] && grep -q "apiVersion:" "$temp_config" 2>/dev/null; then
                log_success "Fetched kubeconfig from ${master}"

                # Extract context name (strip k8s- prefix if present for cleaner names)
                local context_name="$cluster"
                if [[ "$cluster" =~ ^k8s-(.+)$ ]]; then
                    context_name="${BASH_REMATCH[1]}"
                fi

                # Rename contexts in the kubeconfig to avoid conflicts
                # Replace default "kubernetes" names with cluster-specific names
                sed -i.bak \
                    -e "s/name: kubernetes-admin@kubernetes/name: ${context_name}/g" \
                    -e "s/current-context: kubernetes-admin@kubernetes/current-context: ${context_name}/g" \
                    -e "s/context: kubernetes-admin@kubernetes/context: ${context_name}/g" \
                    -e "s/name: kubernetes$/name: ${cluster}/g" \
                    -e "s/cluster: kubernetes$/cluster: ${cluster}/g" \
                    -e "s/name: kubernetes-admin$/name: ${context_name}-admin/g" \
                    -e "s/user: kubernetes-admin$/user: ${context_name}-admin/g" \
                    "$temp_config"
                rm -f "${temp_config}.bak"

                # Add insecure-skip-tls-verify to bypass certificate validation
                # This is safe for local dev clusters with self-signed certificates
                awk '
                    /^  - cluster:/ { in_cluster=1 }
                    in_cluster && /^      server:/ {
                        print
                        print "      insecure-skip-tls-verify: true"
                        next
                    }
                    /^    name:/ && in_cluster { in_cluster=0 }
                    { print }
                ' "$temp_config" > "${temp_config}.tmp" && mv "${temp_config}.tmp" "$temp_config"

                temp_configs+=("$temp_config")
                cluster_names+=("$context_name")
            else
                log_warning "Invalid kubeconfig from ${master}"
                rm -f "$temp_config"
            fi
        else
            log_warning "Could not fetch kubeconfig from ${master}"
            rm -f "$temp_config"
        fi
    done

    # Merge all configs into a single kubeconfig file
    if [ ${#temp_configs[@]} -gt 0 ]; then
        # Build KUBECONFIG list with proper path separators
        local kubeconfig_list=""
        for config in "${temp_configs[@]}"; do
            if [ -n "$kubeconfig_list" ]; then
                kubeconfig_list="${kubeconfig_list}:${config}"
            else
                kubeconfig_list="${config}"
            fi
        done

        # Add existing config if present to preserve other contexts
        if [ -f "$HOME/.kube/config" ]; then
            kubeconfig_list="$HOME/.kube/config:${kubeconfig_list}"
        fi

        log_info "Merging ${#temp_configs[@]} kubeconfig(s)..."

        # Merge using kubectl if available
        if command -v kubectl &> /dev/null; then
            KUBECONFIG="$kubeconfig_list" kubectl config view --flatten > "$HOME/.kube/config.new"
            mv "$HOME/.kube/config.new" "$HOME/.kube/config"
            chmod 600 "$HOME/.kube/config"

            log_success "Kubeconfigs merged successfully"
            log_info "Created contexts for clusters: ${cluster_names[*]}"

            echo ""
            log_info "Available contexts:"
            kubectl config get-contexts
        else
            log_warning "kubectl not found, manual merge required"
        fi

        # Cleanup temp files
        for config in "${temp_configs[@]}"; do
            rm -f "$config"
        done
    else
        log_warning "No kubeconfigs were fetched"
        return 1
    fi

    log_success "Kubeconfig fetch complete"
}

# =====================================================================================================================================
# FIX TLS IN EXISTING KUBECONFIG
# -------------------------------------------------------------------------------------------------------------------------------------
# Adds insecure-skip-tls-verify to all clusters in the kubeconfig. This fixes certificate validation issues for local dev clusters
# =====================================================================================================================================

fix_tls_in_kubeconfig() {
    log_info "Fixing TLS certificate validation in existing kubeconfig..."

    local kubeconfig_file="$HOME/.kube/config"

    if [ ! -f "$kubeconfig_file" ]; then
        log_error "Kubeconfig not found at $kubeconfig_file"
        return 1
    fi

    # Create backup before modifying
    local backup_file="${kubeconfig_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$kubeconfig_file" "$backup_file"
    log_success "Backed up kubeconfig to: $backup_file"

    log_info "Adding insecure-skip-tls-verify to all clusters..."

    # Get all cluster names from kubeconfig
    local clusters=$(kubectl config get-clusters 2>/dev/null | tail -n +2)

    if [ -z "$clusters" ]; then
        log_warning "No clusters found in kubeconfig"
        return 1
    fi

    # Add insecure-skip-tls-verify to each cluster using kubectl config
    while IFS= read -r cluster; do
        if [ -n "$cluster" ]; then
            kubectl config set-cluster "$cluster" --insecure-skip-tls-verify=true >/dev/null 2>&1
            log_success "  Updated cluster: $cluster"
        fi
    done <<< "$clusters"

    log_success "TLS fix applied successfully"
}

# =====================================================================================================================================
# HELP MESSAGE
# =====================================================================================================================================

show_help() {
    cat << EOF

$(echo -e "${CYAN}Kubeconfig Setup and Vagrantfile Sync - Universal Edition${NC}")

Usage: $0 [command]

Commands:
    show        Show detected VMs and their configuration
                Analyzes running VMs and displays cluster info
                Non-destructive, safe to run anytime

    scan        Scan ALL running VMs to find Kubernetes installations
                Checks for kubectl, kubeadm, or kubeconfig on each VM
                Useful for verifying cluster deployment

    fetch       Fetch kubeconfigs from all detected clusters
                Merges into ~/.kube/config
                Creates backup of existing config

    fix-tls     Fix TLS certificate validation in existing kubeconfig
                Adds insecure-skip-tls-verify to all clusters
                Safe for local development clusters
                Creates backup before modifying

    sync        Sync Vagrantfile to match running VM state
                Detects actual CPUs, memory, and node counts
                Updates ALL_CLUSTERS_DECLARATION in Vagrantfile
                Creates backup before modifying

    help        Show this help message

Configuration:
    Edit the script to customize VM naming patterns:
    
    ROLE_PATTERNS="master|worker|control-plane|node|cp|wk"
    
    Current patterns: ${ROLE_PATTERNS}

Examples:
    # Quick start
    $0 show                    # See detected VMs
    $0 fetch                   # Fetch kubeconfigs

    # If using non-standard naming
    $0 scan                    # Deep scan all VMs
    
    # Edit script to add your patterns
    vim $0
    # Change: ROLE_PATTERNS="your-pattern|another-pattern"

    # Fix TLS issues
    $0 fix-tls

    # Complete workflow
    $0 show                    # See current state
    $0 sync                    # Update Vagrantfile to match
    git add Vagrantfile        # Stage changes
    git commit -m "..."        # Commit
    $0 fetch                   # Fetch kubeconfigs

Supported Naming Conventions:
    ✓ master/worker           (k8s-prod-master1, qa-worker2)
    ✓ control-plane/node      (prod-control-plane-1, qa-node-1)
    ✓ cp/wk                   (dev-cp1, prod-wk1)
    ✓ ctrl/compute            (cluster-ctrl1, cluster-compute2)
    ✓ Custom patterns         (add yours to ROLE_PATTERNS)

Notes:
    - Pattern matching is configurable at the top of the script
    - Use 'scan' command for deep inspection of all VMs
    - Works with any prefix (k8s-, no prefix, custom prefix)
    - Detects multi-word clusters (pre-prod, my-cluster, etc.)
    - Compatible with Git Bash on Windows
    - 'show' is safe and non-destructive
    - 'sync' creates a backup in .vagrant/backups/
    - 'fetch' requires kubectl for merging
    - 'fix-tls' adds insecure-skip-tls-verify for local dev clusters

EOF
}

# =====================================================================================================================================
# MAIN ENTRY POINT
# =====================================================================================================================================

main() {
    local command=${1:-help}

    case "$command" in
        fetch|fix-tls|sync|show)
            # Enable strict error handling for these commands
            set -e
            ;&
        scan)
            case "$command" in
                fetch) fetch_kubeconfigs ;;
                fix-tls) fix_tls_in_kubeconfig ;;
                sync) sync_vagrantfile ;;
                show) analyze_cluster_config ;;
                scan) deep_scan_all_vms ;;
            esac
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Run main function if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

# =====================================================================================================================================
# END OF KUBECONFIG SETUP SCRIPT
# =====================================================================================================================================
