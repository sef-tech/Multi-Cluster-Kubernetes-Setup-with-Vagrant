#!/bin/bash

# =====================================================================================================================================
#                                    KUBERNETES CLUSTER SCALING AND VM DETECTION SCRIPT                                                                      
# =====================================================================================================================================
#
# Purpose: Automatically detect running VMs and update Vagrantfile to match reality, plus ADD/REMOVE nodes or scale resources 
# (CPU/Memory) for existing Kubernetes clusters
#
# Features:
#   - Auto-detect ALL running VMs from VirtualBox with configurable naming patterns
#   - Query VM resources (CPU, memory) directly from VirtualBox
#   - Update Vagrantfile configuration to match actual state
#   - Support for multi-cluster setups (prod, qa, dev, pre-prod, dr, etc.)
#   - Works with ANY naming convention (fully configurable)
#   - Automatic backup before modifications
#   - Git integration for committing changes
#   - Declarative configuration: Edit CLUSTERS_CONFIG and run 'apply'
#   - Imperative commands: Add/remove nodes directly via CLI
#   - Scale CPU and memory resources for all nodes of a type or a specific node
#   - Handle Kubernetes node operations (join/drain/remove)
#   - Safety checks and backups before destructive operations
#   - Compatible with Git Bash on Windows

#
# Usage:
#   ./cluster-scaler.sh [command] [options]
#
# Commands:
#   detect          Detect running VMs and show configuration
#   sync            Sync Vagrantfile to match running VMs
#   diff            Show differences between Vagrantfile and reality
#   backup          Create backup of Vagrantfile
#   restore         Restore Vagrantfile from backup
#   apply           Apply declarative configuration (edit CLUSTERS_CONFIG in script)
#   show-config     Display current cluster configuration
#   add-worker      Add worker node(s) to a cluster
#   remove-worker   Remove worker node(s) from a cluster
#   add-master      Add master node(s) to a cluster (HA setup)
#   remove-master   Remove master node(s) from a cluster
#   scale-resources Scale CPU/Memory for existing nodes (all of a type or a specific node)
#
# Examples:
#   # VM Detection and Sync
#   ./cluster-scaler.sh detect              # Show detected VMs
#   ./cluster-scaler.sh sync                # Sync Vagrantfile with reality
#   ./cluster-scaler.sh diff                # Show what will change
#
#   # Declarative approach
#   ./cluster-scaler.sh apply
#
#   # IMPERATIVE COMMANDS FLAGS
        #   - Supports both long (--cluster) and short (-c) option flags
        #   - Supports both long (--node) and short (-n) option flags
        #   - Supports both long (--type) and short (-t) option flags
        #   - Supports both long (--cpu) and short (-c) option flags
        #   - Supports both long (--memory) and short (-m) option flags
#
#   # Imperative commands (long flags use)
        #   ./cluster-scaler.sh add-worker --cluster k8s-prod --count 2
        #   ./cluster-scaler.sh remove-worker --cluster k8s-qa --node k8s-qa-worker2
        #   ./cluster-scaler.sh scale-resources --cluster k8s-prod --type worker --cpu 2 --memory 2048
        #   ./cluster-scaler.sh scale-resources --cluster k8s-prod --type worker --node k8s-prod-worker1 --cpu 2
#
#   # Imperative commands (short flags use)
        #   ./cluster-scaler.sh add-worker -c k8s-prod -n 2
        #   ./cluster-scaler.sh remove-worker -c k8s-qa -n k8s-qa-worker2
        #   ./cluster-scaler.sh scale-resources -c k8s-prod -t worker --cpu 2 -m 2048
        #   ./cluster-scaler.sh scale-resources -c k8s-prod -t worker -n k8s-prod-worker1 --cpu 2
        #   ./cluster-scaler.sh show-config
#
# =====================================================================================================================================

set -e

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
#   ROLE_PATTERNS="master|worker|control-plane|node|cp|wk|lb"
#
ROLE_PATTERNS="master|worker|control-plane|node|cp|wk|ctrl|compute|lb"

# =====================================================================================================================================

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANTFILE="${SCRIPT_DIR}/Vagrantfile"
BACKUP_DIR="${SCRIPT_DIR}/.vagrant/backups"

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# =====================================================================================================================================
# DESIRED CLUSTER CONFIGURATION
# =====================================================================================================================================
# Edit this section to define your desired cluster configuration.
# Run './cluster-scaler.sh apply' to apply changes to the Vagrantfile.
# All clusters defined here are treated as enabled.
# Remove a cluster block entirely to disable it.
# =====================================================================================================================================

# Configuration format matches Vagrantfile structure for easy editing
read -r -d '' CLUSTERS_CONFIG << 'EOF' || true
ALL_CLUSTERS_DECLARATION = {
  "k8s-dr" => {
    base_subnet: "192.168.55",
    master_count: 1,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 4096,
    worker_cpus: 1,
    worker_memory: 1024,
    metallb_ip_range: "192.168.55.200/27",
    context_name: "dr"
  },
  "k8s-prod" => {
    base_subnet: "192.168.54",
    master_count: 3,
    worker_count: 3,
    master_cpus: 2,
    master_memory: 4096,
    worker_cpus: 1,
    worker_memory: 1024,
    metallb_ip_range: "192.168.54.200/27",
    context_name: "prod"
  },
  "k8s-pre-prod" => {
    base_subnet: "192.168.53",
    master_count: 1,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 4096,
    worker_cpus: 1,
    worker_memory: 1024,
    metallb_ip_range: "192.168.53.200/27",
    context_name: "pre-prod"
  },
  "k8s-qa" => {
    base_subnet: "192.168.52",
    master_count: 1,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 4096,
    worker_cpus: 1,
    worker_memory: 1024,
    metallb_ip_range: "192.168.52.200/27",
    context_name: "qa"
  },
  "k8s-dev" => {
    base_subnet: "192.168.51",
    master_count: 1,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 4096,
    worker_cpus: 1,
    worker_memory: 1024,
    metallb_ip_range: "192.168.51.200/27",
    context_name: "dev"
  }
}
EOF

# =====================================================================================================================================
# PARSE CONFIGURATION INTO BASH ASSOCIATIVE ARRAYS
# =====================================================================================================================================

# Parse configuration into Bash associative arrays
declare -A DESIRED_CLUSTERS
declare -A CLUSTER_SUBNETS

parse_config() {
    local in_clusters=false
    local current_cluster=""

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Detect ALL_CLUSTERS_DECLARATION section
        if [[ "$line" =~ ^ALL_CLUSTERS_DECLARATION[[:space:]]*=[[:space:]]*\{ ]]; then
            in_clusters=true
            continue
        fi

        # Detect end of ALL_CLUSTERS_DECLARATION (closing brace at start of line)
        if $in_clusters && [[ "$line" =~ ^\} ]]; then
            in_clusters=false
            continue
        fi

        # Parse cluster declaration (e.g., "k8s-prod" => {)
        if $in_clusters && [[ "$line" =~ \"([^\"]+)\"[[:space:]]*=\>[[:space:]]*\{ ]]; then
            current_cluster="${BASH_REMATCH[1]}"
            continue
        fi

        # Parse cluster properties (e.g., master_count: 3,)
        if $in_clusters && [ -n "$current_cluster" ]; then
            if [[ "$line" =~ ([a-z_]+):[[:space:]]*([^,]+) ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                # Remove quotes and trim whitespace
                value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
                DESIRED_CLUSTERS["${current_cluster}:${key}"]="$value"

                # Also extract base_subnet into CLUSTER_SUBNETS for convenience
                if [ "$key" = "base_subnet" ]; then
                    CLUSTER_SUBNETS["${current_cluster}"]="$value"
                fi
            fi

            # Check for end of cluster block (closing brace with optional comma)
            if [[ "$line" =~ ^[[:space:]]*\} ]]; then
                current_cluster=""
            fi
        fi

    done <<< "$CLUSTERS_CONFIG"
}

# Parse the configuration
parse_config

# =====================================================================================================================================
# HELPER FUNCTIONS
# =====================================================================================================================================

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

confirm() {
    local prompt="$1"
    local response
    read -p "$(echo -e "${YELLOW}❯${NC} ${prompt} [y/N]: ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

backup_vagrantfile() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/Vagrantfile.${timestamp}"
    cp "$VAGRANTFILE" "$backup_file"
    log_success "Backed up Vagrantfile to: $backup_file"
}

restore_vagrantfile() {
    local backup_file=$1

    if [ -z "$backup_file" ]; then
        # List available backups
        log_info "Available backups:"
        ls -1t "$BACKUP_DIR"/Vagrantfile.* 2>/dev/null | head -10 | while read file; do
            echo "  $(basename $file)"
        done
        echo ""
        read -p "Enter backup filename to restore: " backup_file
        backup_file="${BACKUP_DIR}/${backup_file}"
    fi

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    if confirm "Restore from $(basename $backup_file)?"; then
        cp "$backup_file" "$VAGRANTFILE"
        log_success "Vagrantfile restored from: $(basename $backup_file)"
    else
        log_info "Aborted"
    fi
}

# =====================================================================================================================================
# DESIRED CLUSTERS HELPER
# =====================================================================================================================================
# Dynamically extract unique cluster names from the parsed DESIRED_CLUSTERS associative array. This replaces hard-coded cluster lists 
# and the broken "enabled" field check. All clusters present in CLUSTERS_CONFIG are treated as enabled; remove a cluster block from 
# the config to disable it.
# =====================================================================================================================================

get_desired_cluster_names() {
    local clusters=""
    for key in "${!DESIRED_CLUSTERS[@]}"; do
        local cluster="${key%%:*}"
        if [[ ! " $clusters " =~ " $cluster " ]]; then
            clusters="$clusters $cluster"
        fi
    done
    # Trim leading space and echo
    echo "${clusters# }"
}

# =====================================================================================================================================
# VM DETECTION FUNCTIONS - UNIVERSAL PATTERN MATCHING
# -------------------------------------------------------------------------------------------------------------------------------------
# These functions detect ALL running VMs using configurable patterns. Works with any naming convention, any cluster prefix, any number 
# of clusters
# =====================================================================================================================================

detect_running_vms() {
    # Query VirtualBox directly to find ALL running VMs
    # Get all running VMs first
    local all_vms=$(VBoxManage list runningvms 2>/dev/null | sed 's/^"//; s/".*//' || true)
    
    if [ -z "$all_vms" ]; then
        return 1
    fi
    
    # Filter for Kubernetes nodes using configurable pattern
    # Use -- to prevent grep from treating the pattern as an option
    local running_vms=$(echo "$all_vms" | grep -E -- "-(${ROLE_PATTERNS})[0-9]*$" || true)

    if [ -z "$running_vms" ]; then
        log_warning "No running VMs detected matching Kubernetes node patterns"
        log_info "Current patterns: ${ROLE_PATTERNS}"
        return 1
    fi

    echo "$running_vms"
}

parse_vm_config() {
    local vm_name=$1

    # Parse VM name to extract cluster, role, and index
    # Uses GREEDY matching (.+) to capture everything before -(role)
    # This handles multi-word cluster names like: pre-prod, my-cluster, etc.
    # 
    # Examples:
    #   k8s-pre-prod-master1  -> cluster="k8s-pre-prod", role="master", index="1"
    #   prod-worker2          -> cluster="prod", role="worker", index="2"
    #   dr-master             -> cluster="dr", role="master", index="1"
    
    local cluster=""
    local role=""
    local index=""

    # Extract cluster, role, and index using greedy matching. The (.+) matches everything before the last -(role) pattern
    if [[ "$vm_name" =~ ^(.+)-(master|worker|control-plane|node|cp|wk|ctrl|compute|lb)([0-9]*)$ ]]; then
        cluster="${BASH_REMATCH[1]}"
        role="${BASH_REMATCH[2]}"
        index="${BASH_REMATCH[3]}"
        # If no index, default to 1
        index="${index:-1}"
    else
        return 1
    fi

    # Normalize role names to standard types. This allows different naming conventions to be recognized
    case "$role" in
        master|control-plane|controlplane|cp|ctrl)
            role="master"
            ;;
        worker|node|dataplane|wk|compute)
            role="worker"
            ;;
        lb)
            role="load-balancer"
            ;;
    esac

    # Get VM resources directly from VirtualBox
    local vbox_name="${vm_name}"

    # Verify VM exists and is running in VirtualBox
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

detect_cluster_config() {
    log_info "Detecting running VMs from VirtualBox..."
    echo ""

    local vms=$(detect_running_vms)

    if [ -z "$vms" ]; then
        log_warning "No running VMs detected"
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

    # Parse each VM and accumulate statistics
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
    echo -e "${CYAN}Detected Running VM Configuration${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    for cluster in $clusters_list; do
        echo -e "${GREEN}${cluster}${NC}"
        echo "  Masters: ${cluster_master_count[$cluster]:-0} nodes (${cluster_master_cpus[$cluster]:-2} vCPU, ${cluster_master_memory[$cluster]:-3072} MB RAM)"
        echo "  Workers: ${cluster_worker_count[$cluster]:-0} nodes (${cluster_worker_cpus[$cluster]:-1} vCPU, ${cluster_worker_memory[$cluster]:-1024} MB RAM)"
        echo ""
    done

    # Export for use by other functions
    for cluster in $clusters_list; do
        DETECTED_CLUSTERS["${cluster}:master_count"]="${cluster_master_count[$cluster]:-0}"
        DETECTED_CLUSTERS["${cluster}:master_cpus"]="${cluster_master_cpus[$cluster]:-2}"
        DETECTED_CLUSTERS["${cluster}:master_memory"]="${cluster_master_memory[$cluster]:-3072}"
        DETECTED_CLUSTERS["${cluster}:worker_count"]="${cluster_worker_count[$cluster]:-0}"
        DETECTED_CLUSTERS["${cluster}:worker_cpus"]="${cluster_worker_cpus[$cluster]:-1}"
        DETECTED_CLUSTERS["${cluster}:worker_memory"]="${cluster_worker_memory[$cluster]:-1024}"
    done

    DETECTED_CLUSTERS_LIST="$clusters_list"
}

# Declare associative array for detected clusters
declare -A DETECTED_CLUSTERS
DETECTED_CLUSTERS_LIST=""

# =====================================================================================================================================
# VAGRANTFILE SYNC
# -------------------------------------------------------------------------------------------------------------------------------------
# Updates the Vagrantfile to match the actual running VM configuration. 
This is useful when you've manually changed VM resources or node counts
# =====================================================================================================================================

sync_vagrantfile_with_vms() {
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

        awk -v cluster="\"$cluster\"" \
            -v mc="$master_count" -v mcp="$master_cpus" -v mm="$master_memory" \
            -v wc="$worker_count" -v wcp="$worker_cpus" -v wm="$worker_memory" '
            $0 ~ cluster" => {" { in_cluster=1 }
            in_cluster && $0 ~ /^  \}/ { in_cluster=0 }
            in_cluster && $0 ~ /master_count:/ { printf "    master_count: %s,\n", mc; next }
            in_cluster && $0 ~ /master_cpus:/ { printf "    master_cpus: %s,\n", mcp; next }
            in_cluster && $0 ~ /master_memory:/ { printf "    master_memory: %s,\n", mm; next }
            in_cluster && $0 ~ /worker_count:/ { printf "    worker_count: %s,\n", wc; next }
            in_cluster && $0 ~ /worker_cpus:/ { printf "    worker_cpus: %s,\n", wcp; next }
            in_cluster && $0 ~ /worker_memory:/ { printf "    worker_memory: %s,\n", wm; next }
            { print }
        ' "$VAGRANTFILE" > "${VAGRANTFILE}.tmp"

        if [ ! -f "${VAGRANTFILE}.tmp" ]; then
            log_error "Failed to create temporary file"
            return 1
        fi

        if ! mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"; then
            log_error "Failed to update Vagrantfile"
            rm -f "${VAGRANTFILE}.tmp"
            return 1
        fi
    done

    log_success "Vagrantfile synced with running VM state"
    echo ""
    log_info "To commit changes:"
    echo "  git add Vagrantfile"
    echo "  git commit -m 'Sync Vagrantfile with running VM state'"
    echo "  git push"
}

# =====================================================================================================================================
# SHOW DIFFERENCES BETWEEN VAGRANTFILE AND RUNNING VMS
# =====================================================================================================================================

show_diff() {
    log_info "Comparing Vagrantfile configuration with running VMs..."
    echo ""

    detect_cluster_config

    if [ -z "$DETECTED_CLUSTERS_LIST" ]; then
        log_warning "No running VMs detected"
        return 1
    fi

    local has_diff=false

    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Configuration Differences${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    for cluster in $DETECTED_CLUSTERS_LIST; do
        local cluster_has_diff=false
        local params="master_count master_cpus master_memory worker_count worker_cpus worker_memory"

        for param in $params; do
            local vagrantfile_value=$(get_cluster_config "$cluster" "$param")
            local detected_value="${DETECTED_CLUSTERS[${cluster}:${param}]}"

            if [ -n "$detected_value" ] && [ "$vagrantfile_value" != "$detected_value" ]; then
                if [ "$cluster_has_diff" = false ]; then
                    echo -e "${GREEN}${cluster}${NC}"
                    cluster_has_diff=true
                fi

                echo "  ${param}:"
                echo -e "    Vagrantfile: ${RED}${vagrantfile_value}${NC}"
                echo -e "    Running VMs: ${GREEN}${detected_value}${NC}"
                has_diff=true
            fi
        done

        if [ "$cluster_has_diff" = true ]; then
            echo ""
        fi
    done

    if [ "$has_diff" = false ]; then
        log_success "Vagrantfile configuration matches running VMs!"
    else
        echo ""
        log_info "Run './cluster-scaler.sh sync' to update Vagrantfile"
    fi
}

# =====================================================================================================================================
# VAGRANTFILE PARSING FUNCTIONS
# =====================================================================================================================================

get_cluster_config() {
    local cluster=$1
    local key=$2

    awk -v cluster="\"$cluster\"" -v key="$key" '
        $0 ~ cluster" => {" { in_cluster=1; next }
        in_cluster && $0 ~ /^  }/ { in_cluster=0 }
        in_cluster && $0 ~ key": " {
            gsub(/.*: /, "")
            gsub(/,.*/, "")
            gsub(/"/, "")
            print
            exit
        }
    ' "$VAGRANTFILE"
}

get_all_clusters() {
    # Uses [^"]+ to match hyphenated cluster names like "k8s-dr", "k8s-pre-prod"
    grep -oP '"([^"]+)"\s*=>\s*\{' "$VAGRANTFILE" | grep -oP '"\K[^"]+(?=")'
}

update_cluster_config() {
    local cluster=$1
    local key=$2
    local value=$3

    log_info "Updating ${cluster}: ${key} = ${value}"

    awk -v cluster="\"$cluster\"" -v key="$key" -v value="$value" '
        $0 ~ cluster" => {" { in_cluster=1 }
        in_cluster && $0 ~ /^  \}/ { in_cluster=0 }
        in_cluster && $0 ~ key": " {
            if (key ~ /metallb_ip_range|context_name|base_subnet/) {
                printf "    %s: \"%s\",\n", key, value
            } else {
                printf "    %s: %s,\n", key, value
            }
            next
        }
        { print }
    ' "$VAGRANTFILE" > "${VAGRANTFILE}.tmp" && mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"
}

update_subnet_config() {
    local cluster=$1
    local subnet=$2

    log_info "Adding subnet for ${cluster}: ${subnet}"

    if grep -q "\"$cluster\" => \"$subnet\"" "$VAGRANTFILE"; then
        log_info "Subnet already exists for $cluster"
        return
    fi

    awk -v cluster="$cluster" -v subnet="$subnet" '
        /^CLUSTER_BASE_SUBNETS = \{/ {
            print
            in_subnets=1
            next
        }
        in_subnets && /^\}/ {
            printf "  \"%s\" => \"%s\"\n", cluster, subnet
            in_subnets=0
        }
        in_subnets && /=>/ {
            if ($0 !~ /,$/) {
                gsub(/"$/, "\",")
            }
        }
        { print }
    ' "$VAGRANTFILE" > "${VAGRANTFILE}.tmp" && mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"
}

add_cluster_to_vagrantfile() {
    local cluster=$1

    log_info "Adding new cluster ${cluster} to Vagrantfile..."

    local base_subnet="${DESIRED_CLUSTERS[${cluster}:base_subnet]}"
    local master_count="${DESIRED_CLUSTERS[${cluster}:master_count]}"
    local worker_count="${DESIRED_CLUSTERS[${cluster}:worker_count]}"
    local master_cpus="${DESIRED_CLUSTERS[${cluster}:master_cpus]}"
    local master_memory="${DESIRED_CLUSTERS[${cluster}:master_memory]}"
    local worker_cpus="${DESIRED_CLUSTERS[${cluster}:worker_cpus]}"
    local worker_memory="${DESIRED_CLUSTERS[${cluster}:worker_memory]}"
    local metallb_ip_range="${DESIRED_CLUSTERS[${cluster}:metallb_ip_range]}"
    local context_name="${DESIRED_CLUSTERS[${cluster}:context_name]}"

    awk -v cluster="$cluster" \
        -v base_subnet="$base_subnet" \
        -v master_count="$master_count" \
        -v worker_count="$worker_count" \
        -v master_cpus="$master_cpus" \
        -v master_memory="$master_memory" \
        -v worker_cpus="$worker_cpus" \
        -v worker_memory="$worker_memory" \
        -v metallb_ip_range="$metallb_ip_range" \
        -v context_name="$context_name" '
        /^ALL_CLUSTERS_DECLARATION = \{/ {
            print
            in_declaration=1
            next
        }
        in_declaration && /^\}/ {
            if (last_line !~ /,$/) {
                print last_line ","
            } else {
                print last_line
            }
            printf "  \"%s\" => {\n", cluster
            printf "    base_subnet: \"%s\",\n", base_subnet
            printf "    master_count: %s,\n", master_count
            printf "    worker_count: %s,\n", worker_count
            printf "    master_cpus: %s,\n", master_cpus
            printf "    master_memory: %s,\n", master_memory
            printf "    worker_cpus: %s,\n", worker_cpus
            printf "    worker_memory: %s,\n", worker_memory
            printf "    metallb_ip_range: \"%s\",\n", metallb_ip_range
            printf "    context_name: \"%s\"\n", context_name
            printf "  }\n"
            in_declaration=0
            next
        }
        in_declaration {
            if (NR > 1 && last_line != "") {
                print last_line
            }
            last_line=$0
            next
        }
        { print }
    ' "$VAGRANTFILE" > "${VAGRANTFILE}.tmp" && mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"

    log_success "Added cluster ${cluster} to Vagrantfile"
}

remove_cluster_from_vagrantfile() {
    local cluster=$1

    log_info "Removing cluster ${cluster} from Vagrantfile..."

    awk -v cluster="\"$cluster\"" '
        $0 ~ cluster" => {" {
            in_cluster=1
            next
        }
        in_cluster && /^  \},?[[:space:]]*$/ {
            in_cluster=0
            next
        }
        !in_cluster { print }
    ' "$VAGRANTFILE" > "${VAGRANTFILE}.tmp" && mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"

    log_success "Removed cluster ${cluster} from Vagrantfile"
}

# =====================================================================================================================================
# CONFIGURATION DISPLAY
# =====================================================================================================================================

show_config() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Current Cluster Configuration${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    local clusters=$(get_all_clusters)

    if [ -z "$clusters" ]; then
        log_warning "No clusters found in Vagrantfile"
        return
    fi

    for cluster in $clusters; do
        local master_count=$(get_cluster_config "$cluster" "master_count")
        local worker_count=$(get_cluster_config "$cluster" "worker_count")
        local master_cpu=$(get_cluster_config "$cluster" "master_cpus")
        local master_mem=$(get_cluster_config "$cluster" "master_memory")
        local worker_cpu=$(get_cluster_config "$cluster" "worker_cpus")
        local worker_mem=$(get_cluster_config "$cluster" "worker_memory")
        local metallb_range=$(get_cluster_config "$cluster" "metallb_ip_range")

        echo -e "${GREEN}${cluster}${NC}"
        echo "  Masters: ${master_count} nodes (${master_cpu} vCPU, ${master_mem} MB RAM each)"
        echo "  Workers: ${worker_count} nodes (${worker_cpu} vCPU, ${worker_mem} MB RAM each)"
        echo "  MetalLB IP Range: ${metallb_range}"

        local running_vms
        local temp_status="/tmp/vagrant-status-$$.txt"

        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        vagrant status 2>/dev/null > "$temp_status"
        running_vms=$(grep "^${cluster}-" "$temp_status" | grep "running" | awk '{print $1}' || true)
        rm -f "$temp_status"
        popd > /dev/null 2>&1

        if [ -n "$running_vms" ]; then
            echo "  Running VMs:"
            echo "$running_vms" | while read vm; do
                echo "    • $vm"
            done
        fi
        echo ""
    done
}

# =====================================================================================================================================
# NODE MANAGEMENT FUNCTIONS
# =====================================================================================================================================

add_worker_nodes() {
    local cluster=$1
    local count=$2

    log_info "Adding ${count} worker node(s) to ${cluster}..."

    local current_count=$(get_cluster_config "$cluster" "worker_count")
    if [ -z "$current_count" ]; then
        log_error "Cluster ${cluster} not found in Vagrantfile"
        return 1
    fi

    local new_count=$((current_count + count))

    log_info "Current workers: ${current_count}, New total: ${new_count}"

    if ! confirm "This will create ${count} new worker node(s). Continue?"; then
        log_info "Aborted"
        return 1
    fi

    backup_vagrantfile

    update_cluster_config "$cluster" "worker_count" "$new_count"
    log_success "Updated Vagrantfile: worker_count = ${new_count}"

    log_info "Creating new worker nodes..."
    for ((i=current_count+1; i<=new_count; i++)); do
        local worker_name
        if [ "$new_count" -eq 1 ]; then
            worker_name="${cluster}-worker"
        else
            worker_name="${cluster}-worker${i}"
        fi

        log_info "Creating ${worker_name}..."

        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        if vagrant up "$worker_name" 2>&1 | tee /tmp/vagrant-up-${worker_name}.log; then
            log_success "${worker_name} created and joined cluster"
        else
            log_error "Failed to create ${worker_name}"
            log_info "Check logs: /tmp/vagrant-up-${worker_name}.log"
            popd > /dev/null 2>&1
            return 1
        fi
        popd > /dev/null 2>&1
    done

    log_success "Successfully added ${count} worker node(s) to ${cluster}"
    echo ""
    log_info "Verify with: vagrant ssh ${cluster}-master1 -c 'kubectl get nodes'"
}

remove_worker_nodes() {
    local cluster=$1
    local node_name=$2

    log_warning "Removing worker node: ${node_name} from ${cluster}"

    if ! confirm "This will drain and remove ${node_name}. Continue?"; then
        log_info "Aborted"
        return 1
    fi

    local master_count=$(get_cluster_config "$cluster" "master_count")
    local master_name
    if [ "$master_count" = "1" ]; then
        master_name="${cluster}-master"
    else
        master_name="${cluster}-master1"
    fi

    local master_status
    local temp_status="/tmp/vagrant-status-$$.txt"

    pushd "$SCRIPT_DIR" > /dev/null 2>&1
    vagrant status "$master_name" 2>/dev/null > "$temp_status"
    master_status=$(grep "running" "$temp_status" || true)
    rm -f "$temp_status"
    popd > /dev/null 2>&1

    if [ -z "$master_status" ]; then
        log_warning "Master node ${master_name} is not running. Skipping Kubernetes operations."
    else
        log_info "Draining node ${node_name} from Kubernetes..."
        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        if vagrant ssh "$master_name" -c "kubectl drain ${node_name} --ignore-daemonsets --delete-emptydir-data --force --timeout=60s" 2>&1; then
            log_success "Node drained successfully"
        else
            log_warning "Failed to drain node (may not be in cluster)"
        fi

        log_info "Deleting node from Kubernetes..."
        if vagrant ssh "$master_name" -c "kubectl delete node ${node_name}" 2>&1; then
            log_success "Node deleted from Kubernetes"
        else
            log_warning "Failed to delete node from Kubernetes (may not exist)"
        fi
        popd > /dev/null 2>&1
    fi

    log_info "Destroying VM ${node_name}..."
    pushd "$SCRIPT_DIR" > /dev/null 2>&1
    vagrant destroy -f "$node_name" 2>&1
    popd > /dev/null 2>&1
    log_success "VM ${node_name} destroyed"

    local node_num=$(echo "$node_name" | grep -oP '\d+$' || echo "1")
    local current_count=$(get_cluster_config "$cluster" "worker_count")

    if [ "$node_num" = "$current_count" ]; then
        local new_count=$((current_count - 1))

        backup_vagrantfile
        update_cluster_config "$cluster" "worker_count" "$new_count"
        log_success "Updated Vagrantfile: worker_count = ${new_count}"
    else
        log_warning "Removed ${node_name}, but it wasn't the highest-numbered node."
        log_warning "You may need to manually adjust the Vagrantfile or renumber nodes."
    fi

    log_success "Successfully removed ${node_name}"
}

add_master_nodes() {
    local cluster=$1
    local count=$2

    log_info "Adding ${count} master node(s) to ${cluster}..."

    local current_count=$(get_cluster_config "$cluster" "master_count")
    if [ -z "$current_count" ]; then
        log_error "Cluster ${cluster} not found in Vagrantfile"
        return 1
    fi

    local new_count=$((current_count + count))

    log_info "Current masters: ${current_count}, New total: ${new_count}"

    if [ "$current_count" = "1" ] && [ "$new_count" -gt 1 ]; then
        log_warning "Transitioning to HA setup will create a load balancer"
    fi

    if ! confirm "This will create ${count} new master node(s). Continue?"; then
        log_info "Aborted"
        return 1
    fi

    backup_vagrantfile

    update_cluster_config "$cluster" "master_count" "$new_count"
    log_success "Updated Vagrantfile: master_count = ${new_count}"

    if [ "$current_count" = "1" ] && [ "$new_count" -gt 1 ]; then
        local lb_name="${cluster}-lb"
        log_info "Creating load balancer ${lb_name}..."

        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        if vagrant up "$lb_name" 2>&1; then
            log_success "Load balancer created"
        else
            log_error "Failed to create load balancer"
            popd > /dev/null 2>&1
            return 1
        fi
        popd > /dev/null 2>&1
    fi

    log_info "Creating new master nodes..."
    for ((i=current_count+1; i<=new_count; i++)); do
        local master_name
        if [ "$new_count" -eq 1 ]; then
            master_name="${cluster}-master"
        else
            master_name="${cluster}-master${i}"
        fi

        log_info "Creating ${master_name}..."

        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        if vagrant up "$master_name" 2>&1 | tee /tmp/vagrant-up-${master_name}.log; then
            log_success "${master_name} created and joined cluster"
        else
            log_error "Failed to create ${master_name}"
            log_info "Check logs: /tmp/vagrant-up-${master_name}.log"
            popd > /dev/null 2>&1
            return 1
        fi
        popd > /dev/null 2>&1
    done

    log_success "Successfully added ${count} master node(s) to ${cluster}"
    echo ""
    log_info "Verify with: vagrant ssh ${cluster}-master1 -c 'kubectl get nodes'"
}

remove_master_nodes() {
    local cluster=$1
    local node_name=$2

    log_warning "Removing master node: ${node_name} from ${cluster}"

    local current_count=$(get_cluster_config "$cluster" "master_count")

    if [ "$current_count" -le 1 ]; then
        log_error "Cannot remove the only master node in cluster"
        return 1
    fi

    if ! confirm "This will drain and remove ${node_name}. This is a CRITICAL operation. Continue?"; then
        log_info "Aborted"
        return 1
    fi

    local other_master="${cluster}-master1"
    if [ "$node_name" = "$other_master" ]; then
        other_master="${cluster}-master2"
    fi

    log_info "Draining node ${node_name} from Kubernetes..."
    pushd "$SCRIPT_DIR" > /dev/null 2>&1
    if vagrant ssh "$other_master" -c "kubectl drain ${node_name} --ignore-daemonsets --delete-emptydir-data --force --timeout=60s" 2>&1; then
        log_success "Node drained successfully"
    else
        log_warning "Failed to drain node"
    fi

    log_info "Deleting node from Kubernetes..."
    if vagrant ssh "$other_master" -c "kubectl delete node ${node_name}" 2>&1; then
        log_success "Node deleted from Kubernetes"
    else
        log_warning "Failed to delete node from Kubernetes"
    fi

    log_info "Destroying VM ${node_name}..."
    vagrant destroy -f "$node_name" 2>&1
    popd > /dev/null 2>&1
    log_success "VM ${node_name} destroyed"

    local new_count=$((current_count - 1))
    backup_vagrantfile
    update_cluster_config "$cluster" "master_count" "$new_count"
    log_success "Updated Vagrantfile: master_count = ${new_count}"

    if [ "$new_count" = "1" ]; then
        log_warning "Cluster now has only 1 master. Consider removing load balancer with:"
        log_info "  vagrant destroy -f ${cluster}-lb"
    fi

    log_success "Successfully removed ${node_name}"
}

# =====================================================================================================================================
# RESOURCE SCALING FUNCTIONS
# =====================================================================================================================================
# Scales CPU and/or memory for nodes in a cluster.
# Supports two modes:
#   1. All nodes of a type:   -c k8s-prod -t worker --cpu 2 -m 2048
#   2. A specific node:       -c k8s-prod -t worker -n k8s-prod-worker1 --cpu 2
#
# When --node/-n is provided, only that specific VM is reloaded.
# When --node/-n is omitted, ALL running nodes of the specified type are reloaded.
# The Vagrantfile is always updated to reflect the new default for the node type.
# =====================================================================================================================================

scale_resources() {
    local cluster=$1
    local node_type=$2  # master or worker
    local cpu=$3
    local memory=$4
    local target_node=$5  # optional: specific node name

    if [ -n "$target_node" ]; then
        log_info "Scaling resources for specific node: ${target_node}"
    else
        log_info "Scaling ${node_type} resources for all ${node_type} nodes in ${cluster}..."
    fi
    log_info "New configuration: ${cpu:-unchanged} vCPU, ${memory:-unchanged} MB RAM"

    if ! confirm "This requires VM restart. Continue?"; then
        log_info "Aborted"
        return 1
    fi

    backup_vagrantfile

    if [ -n "$cpu" ]; then
        update_cluster_config "$cluster" "${node_type}_cpus" "$cpu"
        log_success "Updated Vagrantfile: ${node_type}_cpus = ${cpu}"
    fi

    if [ -n "$memory" ]; then
        update_cluster_config "$cluster" "${node_type}_memory" "$memory"
        log_success "Updated Vagrantfile: ${node_type}_memory = ${memory}"
    fi

    # Determine which nodes to reload
    local nodes=""

    if [ -n "$target_node" ]; then
        # Target a specific node - verify it is running before reloading
        local temp_status="/tmp/vagrant-status-$$.txt"

        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        vagrant status 2>/dev/null > "$temp_status"

        if grep -q "^${target_node}.*running" "$temp_status"; then
            nodes="$target_node"
        else
            log_warning "Node ${target_node} is not running"
            log_info "Vagrantfile updated. Resources will apply when the node is started."
            rm -f "$temp_status"
            popd > /dev/null 2>&1
            return 0
        fi

        rm -f "$temp_status"
        popd > /dev/null 2>&1
    else
        # Target all running nodes of this type
        local node_pattern="${cluster}-${node_type}"
        local temp_status="/tmp/vagrant-status-$$.txt"

        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        vagrant status 2>/dev/null > "$temp_status"
        nodes=$(grep "^${node_pattern}" "$temp_status" | grep "running" | awk '{print $1}' || true)
        rm -f "$temp_status"
        popd > /dev/null 2>&1
    fi

    if [ -z "$nodes" ]; then
        log_warning "No running ${node_type} nodes found for ${cluster}"
        log_info "Vagrantfile updated. Resources will apply when nodes are created."
        return 0
    fi

    # Reload target node(s) to apply new VirtualBox resource settings
    log_info "Reloading nodes to apply new resources..."
    pushd "$SCRIPT_DIR" > /dev/null 2>&1
    while IFS= read -r node; do
        [ -z "$node" ] && continue
        log_info "Reloading ${node}..."
        if vagrant reload "$node" 2>&1; then
            log_success "${node} reloaded with new resources"
        else
            log_error "Failed to reload ${node}"
        fi
    done <<< "$nodes"
    popd > /dev/null 2>&1

    log_success "Resource scaling complete for ${cluster} ${node_type} nodes"
}

# =====================================================================================================================================
# DECLARATIVE CONFIGURATION APPLY
# =====================================================================================================================================

get_desired_value() {
    local cluster=$1
    local key=$2
    echo "${DESIRED_CLUSTERS[${cluster}:${key}]}"
}

# A cluster is considered enabled if it exists in the parsed CLUSTERS_CONFIG. (i.e., has a master_count value). 
# To disable a cluster, remove its block from CLUSTERS_CONFIG entirely.

is_cluster_in_desired() {
    local cluster=$1
    local master_count="${DESIRED_CLUSTERS[${cluster}:master_count]}"
    [ -n "$master_count" ]
}

apply_config() {
    echo ""
    log_info "Applying declarative configuration from script..."
    echo ""

    local desired_cluster_names
    desired_cluster_names=$(get_desired_cluster_names)

    if [ -z "$desired_cluster_names" ]; then
        log_warning "No clusters found in CLUSTERS_CONFIG configuration"
        return 0
    fi

    local current_clusters
    current_clusters=$(get_all_clusters)

    local changes=()
    local has_changes=false
    local clusters_to_add=()
    local clusters_to_remove=()

    for cluster in $desired_cluster_names; do
        local found=false
        for current in $current_clusters; do
            if [ "$cluster" = "$current" ]; then
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            clusters_to_add+=("$cluster")
            has_changes=true
        fi
    done

    for cluster in $current_clusters; do
        if ! is_cluster_in_desired "$cluster"; then
            clusters_to_remove+=("$cluster")
            has_changes=true
        fi
    done

    for cluster in $desired_cluster_names; do
        local found=false
        for current in $current_clusters; do
            if [ "$cluster" = "$current" ]; then
                found=true
                break
            fi
        done

        if [ "$found" = true ]; then
            local params="base_subnet master_count master_cpus master_memory worker_count worker_cpus worker_memory metallb_ip_range context_name"

            for param in $params; do
                local current_val=$(get_cluster_config "$cluster" "$param")
                local desired_val=$(get_desired_value "$cluster" "$param")

                if [ -n "$desired_val" ] && [ "$current_val" != "$desired_val" ]; then
                    changes+=("${cluster}:${param}:${current_val}:${desired_val}")
                    has_changes=true
                fi
            done
        fi
    done

    if [ "$has_changes" = false ]; then
        log_success "Configuration is already up to date!"
        return 0
    fi

    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Configuration Changes${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    if [ ${#clusters_to_add[@]} -gt 0 ]; then
        echo -e "${GREEN}Clusters to ADD:${NC}"
        for cluster in "${clusters_to_add[@]}"; do
            echo "  • $cluster"
        done
        echo ""
    fi

    if [ ${#clusters_to_remove[@]} -gt 0 ]; then
        echo -e "${RED}Clusters to REMOVE:${NC}"
        for cluster in "${clusters_to_remove[@]}"; do
            echo "  • $cluster"
        done
        echo ""
    fi

    if [ ${#changes[@]} -gt 0 ]; then
        echo -e "${YELLOW}Configuration Updates:${NC}"
        for change in "${changes[@]}"; do
            IFS=':' read -r cluster param current_val desired_val <<< "$change"
            echo -e "  ${cluster} ${param}:"
            echo "    Current: ${current_val}"
            echo -e "    Desired: ${GREEN}${desired_val}${NC}"
        done
        echo ""
    fi

    if ! confirm "Apply these changes to Vagrantfile?"; then
        log_info "Aborted"
        return 1
    fi

    backup_vagrantfile

    for cluster in "${clusters_to_remove[@]}"; do
        remove_cluster_from_vagrantfile "$cluster"

        log_warning "Destroying all VMs for cluster: ${cluster}"
        local vms
        local temp_status="/tmp/vagrant-status-$$.txt"

        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        vagrant status 2>/dev/null > "$temp_status"
        vms=$(grep "^${cluster}-" "$temp_status" | awk '{print $1}' || true)
        if [ -n "$vms" ]; then
            while IFS= read -r vm; do
                [ -z "$vm" ] && continue
                log_info "Destroying ${vm}..."
                vagrant destroy -f "$vm" 2>&1
            done <<< "$vms"
        fi
        rm -f "$temp_status"
        popd > /dev/null 2>&1
    done

    for cluster in "${clusters_to_add[@]}"; do
        add_cluster_to_vagrantfile "$cluster"
    done

    for change in "${changes[@]}"; do
        IFS=':' read -r cluster param current_val desired_val <<< "$change"

        update_cluster_config "$cluster" "$param" "$desired_val"
        log_success "Updated ${cluster} ${param}: ${current_val} → ${desired_val}"
    done

    echo ""
    log_success "Configuration applied successfully!"
    echo ""
    log_info "Next steps:"
    echo "  • For new clusters: Run 'vagrant up' to create VMs"
    echo "  • For resource changes: Run 'vagrant reload <vm-name>'"
    echo "  • For node count changes: Run './cluster-scaler.sh add-worker' or 'remove-worker'"
    echo ""

    if [ -d "$SCRIPT_DIR/.git" ]; then
        if confirm "Commit changes to Git?"; then
            commit_to_git "Apply cluster configuration changes via cluster-scaler.sh"
        fi
    fi
}

# =====================================================================================================================================
# GIT OPERATIONS
# =====================================================================================================================================

commit_to_git() {
    local message=$1

    log_info "Committing changes to Git..."

    pushd "$SCRIPT_DIR" > /dev/null 2>&1

    git add Vagrantfile

    if git commit -m "$message" 2>&1; then
        log_success "Changes committed"

        if confirm "Push to GitHub?"; then
            local branch=$(git rev-parse --abbrev-ref HEAD)
            log_info "Pushing to branch: ${branch}"

            local max_retries=4
            local retry_count=0
            local delay=2

            while [ $retry_count -lt $max_retries ]; do
                if git push -u origin "$branch" 2>&1; then
                    log_success "Changes pushed to GitHub"
                    popd > /dev/null 2>&1
                    return 0
                else
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        log_warning "Push failed. Retrying in ${delay} seconds (attempt ${retry_count}/${max_retries})..."
                        sleep $delay
                        delay=$((delay * 2))
                    else
                        log_error "Push failed after ${max_retries} attempts"
                        popd > /dev/null 2>&1
                        return 1
                    fi
                fi
            done
        fi
    else
        log_warning "No changes to commit"
    fi

    popd > /dev/null 2>&1
}

# =====================================================================================================================================
# COMMAND LINE INTERFACE
# =====================================================================================================================================
# All commands support both long and short option flags:
#   --cluster / -c      Cluster name
#   --count   / -n      Number of nodes (for add-worker, add-master)
#   --node    / -n      Node name (for remove-worker, remove-master, scale-resources)
#   --type    / -t      Node type: master or worker
#   --cpu               Number of vCPUs
#   --memory  / -m      Memory in MB
#
# Note on -n ambiguity:
#   - For add-worker / add-master: -n means --count (number to add)
#   - For remove-worker / remove-master / scale-resources: -n means --node (node name)
#     Context determines the meaning, matching natural CLI expectations.
# =====================================================================================================================================

show_help() {
    cat << EOF

$(echo -e "${CYAN}Kubernetes Cluster Scaling and VM Detection Script - Universal Edition${NC}")

Usage: $0 [command] [options]

VM Detection and Sync Commands:
    detect                          Detect running VMs and show configuration
    sync                            Sync Vagrantfile to match running VMs
    diff                            Show differences between Vagrantfile and reality
    backup                          Create timestamped backup of Vagrantfile
    restore [FILENAME]              Restore Vagrantfile from backup

Cluster Management Commands:
    show-config                     Display current cluster configuration

    apply                           Apply declarative configuration from script
                                    Edit CLUSTERS_CONFIG in script, then run this

    add-worker                      Add worker node(s) to a cluster
        --cluster, -c CLUSTER       Cluster name (e.g., k8s-prod)
        --count, -n COUNT           Number of workers to add (default: 1)

    remove-worker                   Remove worker node from a cluster
        --cluster, -c CLUSTER       Cluster name
        --node, -n NODE_NAME        Node name to remove (e.g., k8s-prod-worker2)

    add-master                      Add master node(s) to a cluster (enables HA)
        --cluster, -c CLUSTER       Cluster name
        --count, -n COUNT           Number of masters to add (default: 1)

    remove-master                   Remove master node from a cluster
        --cluster, -c CLUSTER       Cluster name
        --node, -n NODE_NAME        Node name to remove

    scale-resources                 Scale CPU/Memory for node type (all or specific node)
        --cluster, -c CLUSTER       Cluster name
        --type, -t TYPE             Node type (master or worker)
        [--node, -n NODE_NAME]      Optional: specific node to reload (default: all of type)
        [--cpu CPU]                 Number of vCPUs
        [--memory, -m MEMORY]       Memory in MB

Examples:
    # Scale ALL workers in a cluster
    $0 scale-resources -c k8s-prod -t worker --cpu 2 -m 2048

    # Scale a SPECIFIC worker node
    $0 scale-resources -c k8s-prod -t worker -n k8s-prod-worker1 --cpu 2

    # Add 2 workers (short flags)
    $0 add-worker -c k8s-prod -n 2

    # Remove specific worker
    $0 remove-worker -c k8s-qa -n k8s-qa-worker2

    # Other examples
    $0 detect                       # See what's actually running
    $0 diff                         # Check differences
    $0 sync                         # Update Vagrantfile to match reality
    $0 apply                        # Apply declarative config
    $0 show-config                  # Show current config

EOF
}

# =====================================================================================================================================
# MAIN SCRIPT
# =====================================================================================================================================

main() {
    if [ ! -f "$VAGRANTFILE" ]; then
        log_error "Vagrantfile not found in ${SCRIPT_DIR}"
        exit 1
    fi

    local command=$1
    shift || true

    case "$command" in
        detect)
            detect_cluster_config
            ;;

        sync)
            sync_vagrantfile_with_vms
            ;;

        diff)
            show_diff
            ;;

        backup)
            backup_vagrantfile
            ;;

        restore)
            local backup_file=""
            if [ $# -gt 0 ]; then
                backup_file="$1"
            fi
            restore_vagrantfile "$backup_file"
            ;;

        show-config)
            show_config
            ;;

        apply)
            apply_config
            ;;

        # add-worker: -n means --count (number of workers to add)
        add-worker)
            local cluster=""
            local count=1

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster|-c) cluster=$2; shift 2 ;;
                    --count|-n)   count=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; show_help; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ]; then
                log_error "Missing --cluster / -c option"
                exit 1
            fi

            add_worker_nodes "$cluster" "$count"
            ;;

        # remove-worker: -n means --node (specific node name to remove)
        remove-worker)
            local cluster=""
            local node=""

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster|-c) cluster=$2; shift 2 ;;
                    --node|-n)    node=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; show_help; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ] || [ -z "$node" ]; then
                log_error "Missing required options: --cluster / -c and --node / -n"
                exit 1
            fi

            remove_worker_nodes "$cluster" "$node"
            ;;

        # add-master: -n means --count (number of masters to add)
        add-master)
            local cluster=""
            local count=1

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster|-c) cluster=$2; shift 2 ;;
                    --count|-n)   count=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; show_help; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ]; then
                log_error "Missing --cluster / -c option"
                exit 1
            fi

            add_master_nodes "$cluster" "$count"
            ;;

        # remove-master: -n means --node (specific node name to remove)
        remove-master)
            local cluster=""
            local node=""

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster|-c) cluster=$2; shift 2 ;;
                    --node|-n)    node=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; show_help; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ] || [ -z "$node" ]; then
                log_error "Missing required options: --cluster / -c and --node / -n"
                exit 1
            fi

            remove_master_nodes "$cluster" "$node"
            ;;

        # scale-resources: -n means --node (optional specific node to reload)
        #   When --node/-n is provided, only that node is reloaded.
        #   When omitted, ALL running nodes of --type are reloaded.
        #   The Vagrantfile is always updated regardless.
        scale-resources)
            local cluster=""
            local node_type=""
            local cpu=""
            local memory=""
            local target_node=""

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster|-c) cluster=$2; shift 2 ;;
                    --type|-t)    node_type=$2; shift 2 ;;
                    --cpu)        cpu=$2; shift 2 ;;
                    --memory|-m)  memory=$2; shift 2 ;;
                    --node|-n)    target_node=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; show_help; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ] || [ -z "$node_type" ]; then
                log_error "Missing required options: --cluster / -c and --type / -t"
                exit 1
            fi

            if [ -z "$cpu" ] && [ -z "$memory" ]; then
                log_error "Must specify at least --cpu or --memory / -m"
                exit 1
            fi

            scale_resources "$cluster" "$node_type" "$cpu" "$memory" "$target_node"
            ;;

        -h|--help|help|"")
            show_help
            ;;

        *)
            log_error "Unknown command: $command"
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
# END OF CLUSTER SCALER SCRIPT
# =====================================================================================================================================
