#!/bin/bash

# ========================================================================================================================
# KUBECONFIG SETUP AND VAGRANTFILE SYNC
# ========================================================================================================================
#
# Purpose: Automatically fetch kubeconfigs from running Kubernetes clusters and sync Vagrantfile
#
# Features:
#   - Auto-detect running VMs from VirtualBox directly (more robust than vagrant status)
#   - Fetch kubeconfigs from all detected clusters
#   - Merge kubeconfigs into ~/.kube/config with proper context naming
#   - Fix TLS certificate validation issues for local dev clusters
#   - Sync Vagrantfile configuration to match running VMs
#   - Supports multi-cluster setups (prod, qa, dev, etc.)
#
# Usage:
#   ./kubeconfig-setup.sh [command] [options]
#
# Commands:
#   show            Show detected VMs and clusters
#   sync            Sync Vagrantfile to match running VM state
#   fetch           Fetch kubeconfigs from all running clusters
#   fix-tls         Fix TLS certificate validation in existing kubeconfig
#   help            Show this help message
#
# Examples:
#   ./kubeconfig-setup.sh show               # Show detected VMs
#   ./kubeconfig-setup.sh sync               # Sync Vagrantfile with reality
#   ./kubeconfig-setup.sh fetch              # Fetch all kubeconfigs
#   ./kubeconfig-setup.sh fix-tls            # Fix TLS errors
#
# ========================================================================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANTFILE="${SCRIPT_DIR}/Vagrantfile"

# Detect OS and set .kube path
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

# ========================================================================================================================
# HELPER FUNCTIONS
# ========================================================================================================================

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

# ========================================================================================================================
# VM DETECTION
# ========================================================================================================================

detect_running_vms() {
    log_info "Detecting running VMs..."

    # Query VirtualBox directly to find ALL running VMs matching our naming pattern
    # This works regardless of what's in the current Vagrantfile
    # Format: "k8s-prod-master" or "prod-master" (we handle both)
    local running_vms=$(VBoxManage list runningvms 2>/dev/null | \
        grep -E "^\"(k8s-)?(prod|qa|dev)-" | \
        sed -E 's/^"(k8s-)?//; s/".*//' || true)

    if [ -z "$running_vms" ]; then
        # Fallback to checking for k8s- prefix format
        running_vms=$(VBoxManage list runningvms 2>/dev/null | \
            grep "^\"k8s-" | \
            sed 's/^"k8s-//; s/".*//' || true)
    fi

    if [ -z "$running_vms" ]; then
        log_warning "No running VMs detected"
        return 1
    fi

    echo "$running_vms"
}

parse_vm_config() {
    local vm_name=$1

    # Parse VM name to extract cluster, role, and index
    # Supports formats:
    #   - prod-master, qa-worker-1 (without k8s- prefix)
    #   - prod-master1, qa-worker2 (with numeric suffix)

    local cluster=""
    local role=""
    local index=""

    # Try format: cluster-role-index (e.g., prod-worker-1)
    if [[ "$vm_name" =~ ^([^-]+)-(master|worker)-([0-9]+)$ ]]; then
        cluster="${BASH_REMATCH[1]}"
        role="${BASH_REMATCH[2]}"
        index="${BASH_REMATCH[3]}"
    # Try format: cluster-role (e.g., prod-master)
    elif [[ "$vm_name" =~ ^([^-]+)-(master|worker)$ ]]; then
        cluster="${BASH_REMATCH[1]}"
        role="${BASH_REMATCH[2]}"
        index="1"
    # Try format with numeric suffix: cluster-roleN (e.g., prod-master1, qa-worker2)
    elif [[ "$vm_name" =~ ^([^-]+)-(master|worker)([0-9]+)$ ]]; then
        cluster="${BASH_REMATCH[1]}"
        role="${BASH_REMATCH[2]}"
        index="${BASH_REMATCH[3]}"
    else
        return 1
    fi

    # Get VM resources directly from VirtualBox
    # Check both with and without k8s- prefix
    local vbox_name=""
    if VBoxManage showvminfo "k8s-${vm_name}" --machinereadable &>/dev/null; then
        vbox_name="k8s-${vm_name}"
    elif VBoxManage showvminfo "${vm_name}" --machinereadable &>/dev/null; then
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

    # Get CPU and memory from VirtualBox
    local cpus=$(VBoxManage showvminfo "$vbox_name" --machinereadable 2>/dev/null | \
        grep "^cpus=" | cut -d'=' -f2 | tr -d '"' || echo "2")
    local memory=$(VBoxManage showvminfo "$vbox_name" --machinereadable 2>/dev/null | \
        grep "^memory=" | cut -d'=' -f2 | tr -d '"' || echo "1024")

    echo "${cluster}|${role}|${index}|${cpus}|${memory}"
}

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

    # Parse each VM (using process substitution to avoid subshell)
    while IFS= read -r vm; do
        local config=$(parse_vm_config "$vm")

        if [ $? -eq 0 ]; then
            IFS='|' read -r cluster role index cpus memory <<< "$config"

            # Track cluster (using string list instead of associative array)
            if [[ ! " $clusters_list " =~ " $cluster " ]]; then
                clusters_list="$clusters_list $cluster"
            fi

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

    # Display detected configuration
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

# ========================================================================================================================
# VAGRANTFILE SYNC
# ========================================================================================================================

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

    # Backup Vagrantfile
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

            # Track cluster and initialize all parameters to 0
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

        log_info "  master_count: ${master_count}"
        log_info "  master_cpus: ${master_cpus}"
        log_info "  master_memory: ${master_memory}"
        log_info "  worker_count: ${worker_count}"
        log_info "  worker_cpus: ${worker_cpus}"
        log_info "  worker_memory: ${worker_memory}"

        # Update all parameters in a single awk pass for robustness
        # This matches both "cluster" and "k8s-cluster" formats
        # ⚠️ FIXED: Escaped { and } characters in regex patterns for proper matching
        awk -v cluster="\"k8s-${cluster}\"" \
            -v mc="$master_count" -v mcp="$master_cpus" -v mm="$master_memory" \
            -v wc="$worker_count" -v wcp="$worker_cpus" -v wm="$worker_memory" '
            $0 ~ cluster" => \\{" { in_cluster=1 }
            in_cluster && $0 ~ /^  \},?$/ { in_cluster=0 }
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

        # Move the temp file to replace the original (with error checking)
        if ! mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"; then
            log_error "Failed to update Vagrantfile"
            rm -f "${VAGRANTFILE}.tmp"
            return 1
        fi
    done

    # Verify changes were applied by checking actual values
    log_info "Verifying changes..."
    local verification_failed=false

    for cluster in $clusters_list; do
        local expected_mc="${cluster_config[${cluster}:master_count]}"
        local expected_mm="${cluster_config[${cluster}:master_memory]}"
        local expected_wc="${cluster_config[${cluster}:worker_count]}"
        local expected_wm="${cluster_config[${cluster}:worker_memory]}"

        # Extract actual values from updated Vagrantfile
        local actual_mc=$(awk -v cluster="\"k8s-${cluster}\"" '
            $0 ~ cluster" => \\{" { in_cluster=1 }
            in_cluster && $0 ~ /^  \},?$/ { in_cluster=0 }
            in_cluster && $0 ~ /master_count:/ { gsub(/[^0-9]/, ""); print; exit }
        ' "$VAGRANTFILE")

        local actual_mm=$(awk -v cluster="\"k8s-${cluster}\"" '
            $0 ~ cluster" => \\{" { in_cluster=1 }
            in_cluster && $0 ~ /^  \},?$/ { in_cluster=0 }
            in_cluster && $0 ~ /master_memory:/ { gsub(/[^0-9]/, ""); print; exit }
        ' "$VAGRANTFILE")

        # Verify master_count and master_memory were updated correctly
        if [ "$actual_mc" != "$expected_mc" ] || [ "$actual_mm" != "$expected_mm" ]; then
            log_warning "  ${cluster}: verification failed (expected mc=$expected_mc mm=$expected_mm, got mc=$actual_mc mm=$actual_mm)"
            verification_failed=true
        fi
    done

    if [ "$verification_failed" = true ]; then
        log_warning "Some values may not have been updated correctly. Check Vagrantfile manually."
    else
        log_success "Vagrantfile synced with running VM state"
    fi

    echo ""
    log_info "Changes made:"
    for cluster in $clusters_list; do
        echo "  ${cluster}:"
        echo "    master_count: ${cluster_config[${cluster}:master_count]:-0}"
        echo "    master_cpus: ${cluster_config[${cluster}:master_cpus]:-2}"
        echo "    master_memory: ${cluster_config[${cluster}:master_memory]:-4096}"
        echo "    worker_count: ${cluster_config[${cluster}:worker_count]:-0}"
        echo "    worker_cpus: ${cluster_config[${cluster}:worker_cpus]:-1}"
        echo "    worker_memory: ${cluster_config[${cluster}:worker_memory]:-1024}"
    done

    echo ""
    log_info "To commit changes:"
    echo "  git add Vagrantfile"
    echo "  git commit -m 'Sync Vagrantfile with running VM state'"
    echo "  git push"
}

# ========================================================================================================================
# KUBECONFIG FETCH
# ========================================================================================================================

fetch_kubeconfigs() {
    log_info "Fetching kubeconfigs from running clusters..."

    local vms=$(detect_running_vms)

    if [ -z "$vms" ]; then
        log_warning "No running VMs detected"
        return 1
    fi

    # Find master nodes
    local masters=$(echo "$vms" | grep "master")

    if [ -z "$masters" ]; then
        log_warning "No master nodes found"
        return 1
    fi

    # Create kubeconfig directory
    mkdir -p "$HOME/.kube"

    # Backup existing config
    if [ -f "$HOME/.kube/config" ]; then
        cp "$HOME/.kube/config" "$HOME/.kube/config.backup.$(date +%Y%m%d_%H%M%S)"
        log_success "Backed up existing kubeconfig"
    fi

    # Fetch from first master of each cluster
    # ⚠️ Strip -master followed by optional digits to correctly extract cluster name
    local clusters=$(echo "$masters" | sed -E 's/-master[0-9]*$//' | sort -u)
    local temp_configs=()
    local cluster_names=()

    for cluster in $clusters; do
        # Find the master for this cluster (try different naming patterns)
        local master=""
        for pattern in "${cluster}-master" "${cluster}-master-1" "${cluster}-master1"; do
            if echo "$masters" | grep -q "^${pattern}$"; then
                master="$pattern"
                break
            fi
        done

        if [ -z "$master" ]; then
            log_warning "Could not find master for cluster: $cluster"
            continue
        fi

        log_info "Fetching kubeconfig from ${master}..."

        # Try to fetch kubeconfig
        local temp_config="/tmp/${cluster}-kubeconfig.yaml"

        # Clean up any existing temp file
        rm -f "$temp_config"

        # Try fetching with vagrant ssh (supports both Windows Git Bash and Linux)
        local fetch_result=1

        # Check if we need k8s- prefix for vagrant
        local vagrant_name=""
        if vagrant status 2>/dev/null | grep -q "k8s-${master}"; then
            vagrant_name="k8s-${master}"
        else
            vagrant_name="${master}"
        fi

        if vagrant ssh "$vagrant_name" -c "cat \$HOME/.kube/config" > "$temp_config" 2>/dev/null; then
            fetch_result=0
        fi

        # Check if we got a valid kubeconfig
        if [ $fetch_result -eq 0 ] && [ -s "$temp_config" ] && grep -q "apiVersion:" "$temp_config" 2>/dev/null; then
            log_success "Fetched kubeconfig from ${master}"

            # Rename context in this config file BEFORE merging to avoid conflicts
            # Use sed to replace kubernetes names with cluster-specific names
            sed -i.bak \
                -e "s/name: kubernetes-admin@kubernetes/name: ${cluster}/g" \
                -e "s/current-context: kubernetes-admin@kubernetes/current-context: ${cluster}/g" \
                -e "s/context: kubernetes-admin@kubernetes/context: ${cluster}/g" \
                -e "s/name: kubernetes$/name: k8s-${cluster}/g" \
                -e "s/cluster: kubernetes$/cluster: k8s-${cluster}/g" \
                -e "s/name: kubernetes-admin$/name: ${cluster}-admin/g" \
                -e "s/user: kubernetes-admin$/user: ${cluster}-admin/g" \
                "$temp_config"
            rm -f "${temp_config}.bak"

            # Add insecure-skip-tls-verify to bypass certificate validation issues
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
            cluster_names+=("$cluster")
        else
            log_warning "Could not fetch valid kubeconfig from ${master}"
            if [ -f "$temp_config" ] && [ -s "$temp_config" ]; then
                log_info "Received data but not a valid kubeconfig. First few lines:"
                head -3 "$temp_config" 2>/dev/null || echo "(empty or unreadable)"
            else
                log_info "No data received or file is empty"
            fi
            rm -f "$temp_config"
        fi
    done

    # Merge all configs
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

        # Add existing config if present
        if [ -f "$HOME/.kube/config" ]; then
            kubeconfig_list="$HOME/.kube/config:${kubeconfig_list}"
        fi

        log_info "Merging ${#temp_configs[@]} kubeconfig(s)..."

        if command -v kubectl &> /dev/null; then
            KUBECONFIG="$kubeconfig_list" kubectl config view --flatten > "$HOME/.kube/config.new"
            mv "$HOME/.kube/config.new" "$HOME/.kube/config"
            chmod 600 "$HOME/.kube/config"

            log_success "Kubeconfigs merged successfully"

            # Contexts were already renamed in temp files before merging
            log_info "Created contexts for clusters: ${cluster_names[*]}"

            # Show available contexts
            echo ""
            log_info "Available contexts:"
            kubectl config get-contexts
        else
            log_warning "kubectl not found, manual merge required"
            for config in "${temp_configs[@]}"; do
                log_info "Kubeconfig saved: $config"
            done
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

# ========================================================================================================================
# FIX TLS IN EXISTING KUBECONFIG
# ========================================================================================================================

fix_tls_in_kubeconfig() {
    log_info "Fixing TLS certificate validation in existing kubeconfig..."

    local kubeconfig_file="$HOME/.kube/config"

    if [ ! -f "$kubeconfig_file" ]; then
        log_error "Kubeconfig not found at $kubeconfig_file"
        log_info "Run './kubeconfig-setup.sh fetch' first to create a kubeconfig"
        return 1
    fi

    # Create backup
    local backup_file="${kubeconfig_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$kubeconfig_file" "$backup_file"
    log_success "Backed up kubeconfig to: $backup_file"

    # Add insecure-skip-tls-verify to all clusters
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

    # Verify changes
    if grep -q "insecure-skip-tls-verify: true" "$kubeconfig_file"; then
        log_success "TLS fix applied successfully"
    else
        # Check if kubectl works without the fix (certificates might be valid)
        log_info "Testing if kubectl works without TLS skip..."
        local contexts=$(kubectl config get-contexts -o name 2>/dev/null | head -1)
        if [ -n "$contexts" ] && kubectl get nodes --context="$contexts" >/dev/null 2>&1; then
            log_success "Kubectl works perfectly! Your certificates are valid - TLS skip not needed"
            return 0
        else
            log_warning "Could not verify TLS fix was applied"
            return 1
        fi
    fi

    echo ""
    log_info "Testing cluster connections..."
    echo ""

    # Get all contexts
    local contexts=$(kubectl config get-contexts -o name 2>/dev/null)

    if [ -z "$contexts" ]; then
        log_warning "No contexts found in kubeconfig"
        return 0
    fi

    local success_count=0
    local total_count=0

    # Test each context
    while IFS= read -r context; do
        total_count=$((total_count + 1))
        if kubectl config use-context "$context" >/dev/null 2>&1; then
            if kubectl get nodes >/dev/null 2>&1; then
                log_success "✓ $context is accessible"
                success_count=$((success_count + 1))
            else
                log_warning "✗ $context connection failed"
            fi
        fi
    done <<< "$contexts"

    echo ""
    log_info "Results: $success_count/$total_count clusters accessible"

    if [ $success_count -eq $total_count ]; then
        log_success "All clusters are now accessible!"
    fi
}

# ========================================================================================================================
# MAIN
# ========================================================================================================================

show_help() {
    cat << EOF

$(echo -e "${CYAN}Kubeconfig Setup and Vagrantfile Sync${NC}")

Usage: $0 [command]

Commands:
    fetch       Fetch kubeconfigs from all running clusters
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

    show        Show detected VMs and their configuration
                Analyzes running VMs and displays cluster info
                Non-destructive, safe to run anytime

    help        Show this help message

Examples:
    # Show what's currently running
    $0 show

    # Fetch all kubeconfigs and merge them
    $0 fetch

    # Fix TLS errors in existing kubeconfig
    $0 fix-tls

    # Sync Vagrantfile with actual VM state
    $0 sync

    # Complete workflow
    $0 show                    # See current state
    $0 sync                    # Update Vagrantfile to match
    git add Vagrantfile        # Stage changes
    git commit -m "..."        # Commit
    $0 fetch                   # Fetch kubeconfigs

    # If you get TLS certificate errors
    $0 fix-tls                 # Fix existing kubeconfig

Notes:
    - 'show' is safe and non-destructive
    - 'sync' creates a backup in .vagrant/backups/
    - 'fetch' requires kubectl for merging
    - 'fix-tls' adds insecure-skip-tls-verify for local dev clusters
    - All operations detect VMs automatically from VirtualBox

EOF
}

main() {
    local command=${1:-help}

    case "$command" in
        fetch)
            fetch_kubeconfigs
            ;;

        fix-tls)
            fix_tls_in_kubeconfig
            ;;

        sync)
            sync_vagrantfile
            ;;

        show)
            analyze_cluster_config
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

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
# ========================================================================================================================
# END OF KUBECONFIG SETUP SCRIPT
# ========================================================================================================================
