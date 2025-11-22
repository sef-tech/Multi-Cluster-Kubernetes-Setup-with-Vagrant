#!/bin/bash

# ========================================================================================================================
# KUBERNETES CLUSTER SCALING AND VM DETECTION SCRIPT
# ========================================================================================================================
#
# Purpose: Automatically detect running VMs and update Vagrantfile to match reality, plus add/remove nodes
#          or scale resources (CPU/Memory) for existing Kubernetes clusters
#
# Features:
#   - Auto-detect all running VMs from VirtualBox
#   - Query VM resources (CPU, memory) directly from VirtualBox
#   - Update Vagrantfile configuration to match actual state
#   - Support for multi-cluster setups (prod, qa, dev, etc.)
#   - Automatic backup before modifications
#   - Git integration for committing changes
#   - Declarative configuration: Edit DESIRED_CLUSTERS and run 'apply'
#   - Imperative commands: Add/remove nodes directly via CLI
#   - Scale CPU and memory resources for existing VMs
#   - Handle Kubernetes node operations (join/drain/remove)
#   - Safety checks and backups before destructive operations
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
#   apply           Apply declarative configuration (edit DESIRED_CLUSTERS in script)
#   show-config     Display current cluster configuration
#   add-worker      Add worker node(s) to a cluster
#   remove-worker   Remove worker node(s) from a cluster
#   add-master      Add master node(s) to a cluster (HA setup)
#   remove-master   Remove master node(s) from a cluster
#   scale-resources Scale CPU/Memory for existing nodes
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
#   # Imperative commands
#   ./cluster-scaler.sh add-worker --cluster k8s-prod --count 2
#   ./cluster-scaler.sh remove-worker --cluster k8s-qa --node k8s-qa-worker2
#   ./cluster-scaler.sh scale-resources --cluster k8s-prod --type worker --cpu 2 --memory 2048
#   ./cluster-scaler.sh show-config
#
# ========================================================================================================================

set -e

# Color codes
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

# ========================================================================================================================
# DESIRED CLUSTER CONFIGURATION
# ========================================================================================================================
# Edit this section to define your desired cluster configuration.
# Run './cluster-scaler.sh apply' to apply changes to the Vagrantfile.
# Comment out clusters (with #) or set enabled to "false" to disable them.
# ========================================================================================================================

# Configuration format matches Vagrantfile structure for easy editing
read -r -d '' CLUSTERS_CONFIG << 'EOF' || true
CLUSTERS = {
  "k8s-prod" => {
    master_count: 1,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 4096,
    worker_cpus: 2,
    worker_memory: 1024,
    metallb_ip_range: "192.168.51.200/27",
    enabled: true
  },
  "k8s-qa" => {
    master_count: 1,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 3072,
    worker_cpus: 1,
    worker_memory: 1024,
    metallb_ip_range: "192.168.52.200/27",
    enabled: true
  },
  # "k8s-dev" => {
    master_count: 1,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 3072,
    worker_cpus: 1,
    worker_memory: 1024,
    metallb_ip_range: "192.168.52.200/27",
  # enabled: false
  # }
}

# CLUSTER_SUBNETS is now extracted from base_subnet in ALL_CLUSTERS_DECLARATION
# CLUSTER_SUBNETS = {
  "k8s-prod" => "192.168.51",
  "k8s-qa" => "192.168.52"
  # "k8s-dev" => "192.168.53"  # Uncomment to add dev cluster
}
EOF

# Parse configuration into Bash associative arrays
declare -A DESIRED_CLUSTERS
declare -A CLUSTER_SUBNETS

parse_config() {
    local in_clusters=false
    local in_subnets=false
    local current_cluster=""

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Detect CLUSTERS section
        if [[ "$line" =~ ^CLUSTERS[[:space:]]*=[[:space:]]*\{ ]]; then
            in_clusters=true
            in_subnets=false
            continue
        fi

        # Detect CLUSTER_SUBNETS section
        if [[ "$line" =~ ^CLUSTER_SUBNETS[[:space:]]*=[[:space:]]*\{ ]]; then
            in_subnets=true
            in_clusters=false
            continue
        fi

        # Parse cluster declaration
        if $in_clusters && [[ "$line" =~ \"([^\"]+)\"[[:space:]]*=\>[[:space:]]*\{ ]]; then
            current_cluster="${BASH_REMATCH[1]}"
            continue
        fi

        # Parse cluster properties
        if $in_clusters && [ -n "$current_cluster" ]; then
            if [[ "$line" =~ ([a-z_]+):[[:space:]]*([^,]+) ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                # Remove quotes and trim whitespace
                value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
                DESIRED_CLUSTERS["${current_cluster}:${key}"]="$value"
            fi

            # Check for end of cluster block
            [[ "$line" =~ ^[[:space:]]*\} ]] && current_cluster=""
        fi

        # Parse subnet entries
        if $in_subnets && [[ "$line" =~ \"([^\"]+)\"[[:space:]]*=\>[[:space:]]*\"([^\"]+)\" ]]; then
            CLUSTER_SUBNETS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        fi

    done <<< "$CLUSTERS_CONFIG"
}

# Parse the configuration
parse_config

# ========================================================================================================================
# HELPER FUNCTIONS
# ========================================================================================================================

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

# ========================================================================================================================
# VM DETECTION FUNCTIONS
# ========================================================================================================================

detect_running_vms() {
    # Query VirtualBox directly to find ALL running VMs matching our naming pattern
    local running_vms=$(VBoxManage list runningvms 2>/dev/null | \
        grep "^\"k8s-" | \
        sed 's/^"k8s-//; s/".*//' | \
        grep -E "^(prod|qa|dev)-" || true)

    if [ -z "$running_vms" ]; then
        return 1
    fi

    echo "$running_vms"
}

parse_vm_config() {
    local vm_name=$1

    # Parse VM name to extract cluster, role, and index
    # Format: cluster-role[index]
    # Examples: prod-master1, qa-worker2, dev-lb

    local cluster=""
    local role=""
    local index=""

    if [[ "$vm_name" =~ ^([^-]+)-([a-z]+)([0-9]*)$ ]]; then
        cluster="k8s-${BASH_REMATCH[1]}"
        role="${BASH_REMATCH[2]}"
        index="${BASH_REMATCH[3]}"
        index=${index:-1}  # Default to 1 if no index

        # Normalize role names
        case "$role" in
            lb) role="load-balancer" ;;
            master) role="master" ;;
            worker) role="worker" ;;
        esac
    else
        return 1
    fi

    # Get VM resources directly from VirtualBox
    local vbox_name="k8s-${vm_name}"

    # Verify VM exists and is running in VirtualBox
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

    # Parse each VM
    while IFS= read -r vm; do
        local config=$(parse_vm_config "$vm")

        if [ $? -eq 0 ]; then
            IFS='|' read -r cluster role index cpus memory <<< "$config"

            # Track cluster
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

sync_vagrantfile_with_vms() {
    log_info "Syncing Vagrantfile with running VM state..."

    # First detect running VMs
    detect_cluster_config

    if [ -z "$DETECTED_CLUSTERS_LIST" ]; then
        log_warning "No running VMs to sync"
        return 1
    fi

    # Backup Vagrantfile
    backup_vagrantfile

    # Update Vagrantfile for each detected cluster
    for cluster in $DETECTED_CLUSTERS_LIST; do
        log_info "Updating configuration for cluster: ${cluster}"

        # Get all parameter values for this cluster
        local master_count="${DETECTED_CLUSTERS[${cluster}:master_count]}"
        local master_cpus="${DETECTED_CLUSTERS[${cluster}:master_cpus]}"
        local master_memory="${DETECTED_CLUSTERS[${cluster}:master_memory]}"
        local worker_count="${DETECTED_CLUSTERS[${cluster}:worker_count]}"
        local worker_cpus="${DETECTED_CLUSTERS[${cluster}:worker_cpus]}"
        local worker_memory="${DETECTED_CLUSTERS[${cluster}:worker_memory]}"

        log_info "  master_count: ${master_count}"
        log_info "  master_cpus: ${master_cpus}"
        log_info "  master_memory: ${master_memory}"
        log_info "  worker_count: ${worker_count}"
        log_info "  worker_cpus: ${worker_cpus}"
        log_info "  worker_memory: ${worker_memory}"

        # Update all parameters in a single awk pass for robustness
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
    echo ""
    log_info "To commit changes:"
    echo "  git add Vagrantfile"
    echo "  git commit -m 'Sync Vagrantfile with running VM state'"
    echo "  git push"
}

show_diff() {
    log_info "Comparing Vagrantfile configuration with running VMs..."
    echo ""

    # Detect running VMs
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

# ========================================================================================================================
# VAGRANTFILE PARSING FUNCTIONS
# ========================================================================================================================

get_cluster_config() {
    local cluster=$1
    local key=$2

    # Extract value from ALL_CLUSTERS_DECLARATION hash
    # Look for the cluster block, then find the key within it
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
    # Extract cluster names from ALL_CLUSTERS_DECLARATION hash
    grep -oP '"(\w+)"\s*=>\s*\{' "$VAGRANTFILE" | grep -oP '"\K\w+(?=")'
}

update_cluster_config() {
    local cluster=$1
    local key=$2
    local value=$3

    log_info "Updating ${cluster}: ${key} = ${value}"

    # Use awk to update the value in place
    awk -v cluster="\"$cluster\"" -v key="$key" -v value="$value" '
        $0 ~ cluster" => {" { in_cluster=1 }
        in_cluster && $0 ~ /^  \}/ { in_cluster=0 }
        in_cluster && $0 ~ key": " {
            # Check if value needs quotes (for metallb_ip_range)
            if (key ~ /metallb_ip_range/) {
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

    # Check if subnet already exists
    if grep -q "\"$cluster\" => \"$subnet\"" "$VAGRANTFILE"; then
        log_info "Subnet already exists for $cluster"
        return
    fi

    # Add subnet to CLUSTER_BASE_SUBNETS
    awk -v cluster="$cluster" -v subnet="$subnet" '
        /^CLUSTER_BASE_SUBNETS = \{/ {
            print
            in_subnets=1
            next
        }
        in_subnets && /^\}/ {
            # Add new subnet before closing brace
            printf "  \"%s\" => \"%s\"\n", cluster, subnet
            in_subnets=0
        }
        in_subnets && /=>/ {
            # Add comma to existing entries
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

    # Get configuration from DESIRED_CLUSTERS
    local master_count="${DESIRED_CLUSTERS[${cluster}:master_count]}"
    local worker_count="${DESIRED_CLUSTERS[${cluster}:worker_count]}"
    local master_cpus="${DESIRED_CLUSTERS[${cluster}:master_cpus]}"
    local master_memory="${DESIRED_CLUSTERS[${cluster}:master_memory]}"
    local worker_cpus="${DESIRED_CLUSTERS[${cluster}:worker_cpus]}"
    local worker_memory="${DESIRED_CLUSTERS[${cluster}:worker_memory]}"
    local metallb_ip_range="${DESIRED_CLUSTERS[${cluster}:metallb_ip_range]}"

    # Add cluster block to ALL_CLUSTERS_DECLARATION
    awk -v cluster="$cluster" \
        -v master_count="$master_count" \
        -v worker_count="$worker_count" \
        -v master_cpus="$master_cpus" \
        -v master_memory="$master_memory" \
        -v worker_cpus="$worker_cpus" \
        -v worker_memory="$worker_memory" \
        -v metallb_ip_range="$metallb_ip_range" '
        /^ALL_CLUSTERS_DECLARATION = \{/ {
            print
            in_declaration=1
            next
        }
        in_declaration && /^\}/ {
            # Add comma to last entry if needed
            if (last_line !~ /,$/) {
                print last_line ","
            } else {
                print last_line
            }
            # Add new cluster
            printf "  \"%s\" => {\n", cluster
            printf "    master_count: %s,\n", master_count
            printf "    worker_count: %s,\n", worker_count
            printf "    master_cpus: %s,\n", master_cpus
            printf "    master_memory: %s,\n", master_memory
            printf "    worker_cpus: %s,\n", worker_cpus
            printf "    worker_memory: %s,\n", worker_memory
            printf "    metallb_ip_range: \"%s\"\n", metallb_ip_range
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

    # Add subnet if configured
    if [ -n "${CLUSTER_SUBNETS[$cluster]}" ]; then
        update_subnet_config "$cluster" "${CLUSTER_SUBNETS[$cluster]}"
    fi

    log_success "Added cluster ${cluster} to Vagrantfile"
}

remove_cluster_from_vagrantfile() {
    local cluster=$1

    log_info "Removing cluster ${cluster} from Vagrantfile..."

    # Remove cluster block from ALL_CLUSTERS_DECLARATION
    awk -v cluster="\"$cluster\"" '
        $0 ~ cluster" => {" {
            in_cluster=1
            next
        }
        in_cluster && /^  \}/ {
            in_cluster=0
            # Skip the closing brace and any trailing comma
            getline
            if ($0 ~ /^  \},?$/) next
            if ($0 ~ /^  "[^"]+/) next
        }
        !in_cluster { print }
    ' "$VAGRANTFILE" > "${VAGRANTFILE}.tmp" && mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"

    # Remove subnet
    awk -v cluster="\"$cluster\"" '
        $0 ~ cluster" => " { next }
        { print }
    ' "$VAGRANTFILE" > "${VAGRANTFILE}.tmp" && mv "${VAGRANTFILE}.tmp" "$VAGRANTFILE"

    log_success "Removed cluster ${cluster} from Vagrantfile"
}

# ========================================================================================================================
# CONFIGURATION DISPLAY
# ========================================================================================================================

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

        # Show running VMs - use temp file to avoid subshell issues
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

# ========================================================================================================================
# NODE MANAGEMENT FUNCTIONS
# ========================================================================================================================

add_worker_nodes() {
    local cluster=$1
    local count=$2

    log_info "Adding ${count} worker node(s) to ${cluster}..."

    # Get current configuration
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

    # Backup Vagrantfile
    backup_vagrantfile

    # Update Vagrantfile
    update_cluster_config "$cluster" "worker_count" "$new_count"
    log_success "Updated Vagrantfile: worker_count = ${new_count}"

    # Bring up new workers
    log_info "Creating new worker nodes..."
    for ((i=current_count+1; i<=new_count; i++)); do
        local worker_name
        if [ "$new_count" -eq 1 ]; then
            worker_name="${cluster}-worker"
        else
            worker_name="${cluster}-worker${i}"
        fi

        log_info "Creating ${worker_name}..."

        # Avoid subshell for Git Bash compatibility
        local old_dir
        old_dir=$(pwd)
        cd "$SCRIPT_DIR"
        if vagrant up "$worker_name" 2>&1 | tee /tmp/vagrant-up-${worker_name}.log; then
            log_success "${worker_name} created and joined cluster"
        else
            log_error "Failed to create ${worker_name}"
            log_info "Check logs: /tmp/vagrant-up-${worker_name}.log"
            cd "$old_dir"
            return 1
        fi
        cd "$old_dir"
    done

    log_success "Successfully added ${count} worker node(s) to ${cluster}"
    echo ""
    log_info "Verify with: vagrant ssh ${cluster}-master1 -c 'kubectl get nodes'"
}

remove_worker_nodes() {
    local cluster=$1
    local node_name=$2

    log_warning "Removing worker node: ${node_name} from ${cluster}"

    # Safety check
    if ! confirm "This will drain and remove ${node_name}. Continue?"; then
        log_info "Aborted"
        return 1
    fi

    # Determine primary master name
    local master_count=$(get_cluster_config "$cluster" "master_count")
    local master_name
    if [ "$master_count" = "1" ]; then
        master_name="${cluster}-master"
    else
        master_name="${cluster}-master1"
    fi

    # Check if master is accessible - use temp file to avoid subshell issues
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
        # Drain the node from Kubernetes
        log_info "Draining node ${node_name} from Kubernetes..."
        cd "$SCRIPT_DIR"
        if vagrant ssh "$master_name" -c "kubectl drain ${node_name} --ignore-daemonsets --delete-emptydir-data --force --timeout=60s" 2>&1; then
            log_success "Node drained successfully"
        else
            log_warning "Failed to drain node (may not be in cluster)"
        fi

        # Delete from Kubernetes
        log_info "Deleting node from Kubernetes..."
        if vagrant ssh "$master_name" -c "kubectl delete node ${node_name}" 2>&1; then
            log_success "Node deleted from Kubernetes"
        else
            log_warning "Failed to delete node from Kubernetes (may not exist)"
        fi
        cd "$old_dir"
    fi

    # Destroy VM
    log_info "Destroying VM ${node_name}..."
    cd "$SCRIPT_DIR"
    vagrant destroy -f "$node_name" 2>&1
    cd "$old_dir"
    log_success "VM ${node_name} destroyed"

    # Extract node number from name
    local node_num=$(echo "$node_name" | grep -oP '\d+$' || echo "1")
    local current_count=$(get_cluster_config "$cluster" "worker_count")

    # Only update count if removing the highest-numbered node
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

    # Get current configuration
    local current_count=$(get_cluster_config "$cluster" "master_count")
    if [ -z "$current_count" ]; then
        log_error "Cluster ${cluster} not found in Vagrantfile"
        return 1
    fi

    local new_count=$((current_count + count))

    log_info "Current masters: ${current_count}, New total: ${new_count}"

    # Check if transitioning to HA
    if [ "$current_count" = "1" ] && [ "$new_count" -gt 1 ]; then
        log_warning "Transitioning to HA setup will create a load balancer"
    fi

    if ! confirm "This will create ${count} new master node(s). Continue?"; then
        log_info "Aborted"
        return 1
    fi

    # Backup Vagrantfile
    backup_vagrantfile

    # Update Vagrantfile
    update_cluster_config "$cluster" "master_count" "$new_count"
    log_success "Updated Vagrantfile: master_count = ${new_count}"

    # Create load balancer if transitioning to HA
    if [ "$current_count" = "1" ] && [ "$new_count" -gt 1 ]; then
        local lb_name="${cluster}-lb"
        log_info "Creating load balancer ${lb_name}..."

        local old_dir
        old_dir=$(pwd)
        cd "$SCRIPT_DIR"
        if vagrant up "$lb_name" 2>&1; then
            log_success "Load balancer created"
        else
            log_error "Failed to create load balancer"
            cd "$old_dir"
            return 1
        fi
        cd "$old_dir"
    fi

    # Bring up new masters
    log_info "Creating new master nodes..."
    for ((i=current_count+1; i<=new_count; i++)); do
        local master_name
        if [ "$new_count" -eq 1 ]; then
            master_name="${cluster}-master"
        else
            master_name="${cluster}-master${i}"
        fi

        log_info "Creating ${master_name}..."

        local old_dir
        old_dir=$(pwd)
        cd "$SCRIPT_DIR"
        if vagrant up "$master_name" 2>&1 | tee /tmp/vagrant-up-${master_name}.log; then
            log_success "${master_name} created and joined cluster"
        else
            log_error "Failed to create ${master_name}"
            log_info "Check logs: /tmp/vagrant-up-${master_name}.log"
            cd "$old_dir"
            return 1
        fi
        cd "$old_dir"
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

    # Safety checks
    if [ "$current_count" -le 1 ]; then
        log_error "Cannot remove the only master node in cluster"
        return 1
    fi

    if ! confirm "This will drain and remove ${node_name}. This is a CRITICAL operation. Continue?"; then
        log_info "Aborted"
        return 1
    fi

    # Determine another master to run commands from
    local other_master="${cluster}-master1"
    if [ "$node_name" = "$other_master" ]; then
        other_master="${cluster}-master2"
    fi

    # Drain the node
    log_info "Draining node ${node_name} from Kubernetes..."
    local old_dir
    old_dir=$(pwd)
    cd "$SCRIPT_DIR"
    if vagrant ssh "$other_master" -c "kubectl drain ${node_name} --ignore-daemonsets --delete-emptydir-data --force --timeout=60s" 2>&1; then
        log_success "Node drained successfully"
    else
        log_warning "Failed to drain node"
    fi

    # Delete from Kubernetes
    log_info "Deleting node from Kubernetes..."
    if vagrant ssh "$other_master" -c "kubectl delete node ${node_name}" 2>&1; then
        log_success "Node deleted from Kubernetes"
    else
        log_warning "Failed to delete node from Kubernetes"
    fi

    # Destroy VM
    log_info "Destroying VM ${node_name}..."
    vagrant destroy -f "$node_name" 2>&1
    cd "$old_dir"
    log_success "VM ${node_name} destroyed"

    # Update Vagrantfile
    local new_count=$((current_count - 1))
    backup_vagrantfile
    update_cluster_config "$cluster" "master_count" "$new_count"
    log_success "Updated Vagrantfile: master_count = ${new_count}"

    # If transitioning from HA to single master, consider removing load balancer
    if [ "$new_count" = "1" ]; then
        log_warning "Cluster now has only 1 master. Consider removing load balancer with:"
        log_info "  vagrant destroy -f ${cluster}-lb"
    fi

    log_success "Successfully removed ${node_name}"
}

# ========================================================================================================================
# RESOURCE SCALING FUNCTIONS
# ========================================================================================================================

scale_resources() {
    local cluster=$1
    local node_type=$2  # master or worker
    local cpu=$3
    local memory=$4

    log_info "Scaling ${node_type} resources for ${cluster}..."
    log_info "New configuration: ${cpu} vCPU, ${memory} MB RAM"

    if ! confirm "This requires VM restart. Continue?"; then
        log_info "Aborted"
        return 1
    fi

    # Backup Vagrantfile
    backup_vagrantfile

    # Update Vagrantfile
    if [ -n "$cpu" ]; then
        update_cluster_config "$cluster" "${node_type}_cpus" "$cpu"
        log_success "Updated Vagrantfile: ${node_type}_cpus = ${cpu}"
    fi

    if [ -n "$memory" ]; then
        update_cluster_config "$cluster" "${node_type}_memory" "$memory"
        log_success "Updated Vagrantfile: ${node_type}_memory = ${memory}"
    fi

    # Get list of nodes to update - use temp file to avoid subshell issues
    local node_pattern="${cluster}-${node_type}"
    local nodes
    local temp_status="/tmp/vagrant-status-$$.txt"

    # Save current directory and change to script directory
    pushd "$SCRIPT_DIR" > /dev/null 2>&1

    # Write vagrant status to temp file to avoid subshell issues on Git Bash
    vagrant status 2>/dev/null > "$temp_status"

    # Read and parse from the file
    nodes=$(grep "^${node_pattern}" "$temp_status" | grep "running" | awk '{print $1}')

    # Clean up
    rm -f "$temp_status"
    popd > /dev/null 2>&1

    if [ -z "$nodes" ]; then
        log_warning "No running ${node_type} nodes found for ${cluster}"
        log_info "Resources will apply when nodes are created"
        return 0
    fi

    # Reload each node
    log_info "Reloading nodes to apply new resources..."
    echo "$nodes" | while read node; do
        log_info "Reloading ${node}..."
        cd "$SCRIPT_DIR"
        if vagrant reload "$node" 2>&1; then
            log_success "${node} reloaded with new resources"
        else
            log_error "Failed to reload ${node}"
        fi
        cd "$old_dir"
    done

    log_success "Resource scaling complete for ${cluster} ${node_type} nodes"
}

# ========================================================================================================================
# DECLARATIVE CONFIGURATION APPLY
# ========================================================================================================================

get_desired_value() {
    local cluster=$1
    local key=$2
    echo "${DESIRED_CLUSTERS[${cluster}:${key}]}"
}

is_cluster_enabled() {
    local cluster=$1
    local enabled=$(get_desired_value "$cluster" "enabled")
    [[ "$enabled" == "true" ]]
}

apply_config() {
    echo ""
    log_info "Applying declarative configuration from script..."
    echo ""

    # Get all enabled clusters from desired config
    local enabled_clusters=()
    for cluster in k8s-prod k8s-qa k8s-dev; do
        if is_cluster_enabled "$cluster"; then
            enabled_clusters+=("$cluster")
        fi
    done

    if [ ${#enabled_clusters[@]} -eq 0 ]; then
        log_warning "No enabled clusters found in configuration"
        return 0
    fi

    # Get current clusters from Vagrantfile
    local current_clusters=($(get_all_clusters))

    # Collect all changes
    local changes=()
    local has_changes=false
    local clusters_to_add=()
    local clusters_to_remove=()

    # Check for new clusters
    for cluster in "${enabled_clusters[@]}"; do
        if [[ ! " ${current_clusters[@]} " =~ " ${cluster} " ]]; then
            clusters_to_add+=("$cluster")
            has_changes=true
        fi
    done

    # Check for removed clusters
    for cluster in "${current_clusters[@]}"; do
        if ! is_cluster_enabled "$cluster"; then
            clusters_to_remove+=("$cluster")
            has_changes=true
        fi
    done

    # Check for configuration changes in existing clusters
    for cluster in "${enabled_clusters[@]}"; do
        if [[ " ${current_clusters[@]} " =~ " ${cluster} " ]]; then
            # Check each configuration parameter
            local params="master_count master_cpus master_memory worker_count worker_cpus worker_memory metallb_ip_range"

            for param in $params; do
                local current=$(get_cluster_config "$cluster" "$param")
                local desired=$(get_desired_value "$cluster" "$param")

                if [ -n "$desired" ] && [ "$current" != "$desired" ]; then
                    changes+=("${cluster}:${param}:${current}:${desired}")
                    has_changes=true
                fi
            done
        fi
    done

    if [ "$has_changes" = false ]; then
        log_success "Configuration is already up to date!"
        return 0
    fi

    # Display changes
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
            IFS=':' read -r cluster param current desired <<< "$change"
            echo -e "  ${cluster} ${param}:"
            echo "    Current: ${current}"
            echo "    Desired: ${GREEN}${desired}${NC}"
        done
        echo ""
    fi

    # Confirm before applying
    if ! confirm "Apply these changes to Vagrantfile?"; then
        log_info "Aborted"
        return 1
    fi

    # Backup Vagrantfile
    backup_vagrantfile

    # Remove clusters first
    for cluster in "${clusters_to_remove[@]}"; do
        remove_cluster_from_vagrantfile "$cluster"

        # Destroy VMs - use temp file to avoid subshell issues
        log_warning "Destroying all VMs for cluster: ${cluster}"
        local vms
        local temp_status="/tmp/vagrant-status-$$.txt"

        pushd "$SCRIPT_DIR" > /dev/null 2>&1
        vagrant status 2>/dev/null > "$temp_status"
        vms=$(grep "^${cluster}-" "$temp_status" | awk '{print $1}')
        if [ -n "$vms" ]; then
            echo "$vms" | while read vm; do
                log_info "Destroying ${vm}..."
                vagrant destroy -f "$vm" 2>&1
            done
        fi
        rm -f "$temp_status"
        popd > /dev/null 2>&1
    done

    # Add new clusters
    for cluster in "${clusters_to_add[@]}"; do
        add_cluster_to_vagrantfile "$cluster"
    done

    # Apply configuration changes
    for change in "${changes[@]}"; do
        IFS=':' read -r cluster param current desired <<< "$change"

        # Format value for Vagrantfile
        local formatted_value="$desired"

        update_cluster_config "$cluster" "$param" "$formatted_value"
        log_success "Updated ${cluster} ${param}: ${current} → ${desired}"
    done

    echo ""
    log_success "Configuration applied successfully!"
    echo ""
    log_info "Next steps:"
    echo "  • For new clusters: Run 'vagrant up' to create VMs"
    echo "  • For resource changes: Run 'vagrant reload <vm-name>'"
    echo "  • For node count changes: Run './cluster-scaler.sh add-worker' or 'remove-worker'"
    echo ""

    # Offer to commit to Git
    if [ -d "$SCRIPT_DIR/.git" ]; then
        if confirm "Commit changes to Git?"; then
            commit_to_git "Apply cluster configuration changes via cluster-scaler.sh"
        fi
    fi
}

# ========================================================================================================================
# GIT OPERATIONS
# ========================================================================================================================

commit_to_git() {
    local message=$1

    log_info "Committing changes to Git..."

    cd "$SCRIPT_DIR"

    # Add Vagrantfile
    git add Vagrantfile

    # Create commit
    if git commit -m "$message" 2>&1; then
        log_success "Changes committed"

        if confirm "Push to GitHub?"; then
            local branch=$(git rev-parse --abbrev-ref HEAD)
            log_info "Pushing to branch: ${branch}"

            # Push with retry logic
            local max_retries=4
            local retry_count=0
            local delay=2

            while [ $retry_count -lt $max_retries ]; do
                if git push -u origin "$branch" 2>&1; then
                    log_success "Changes pushed to GitHub"
                    return 0
                else
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        log_warning "Push failed. Retrying in ${delay} seconds (attempt ${retry_count}/${max_retries})..."
                        sleep $delay
                        delay=$((delay * 2))
                    else
                        log_error "Push failed after ${max_retries} attempts"
                        return 1
                    fi
                fi
            done
        fi
    else
        log_warning "No changes to commit"
    fi
}

# ========================================================================================================================
# COMMAND LINE INTERFACE
# ========================================================================================================================

show_help() {
    cat << EOF

$(echo -e "${CYAN}Kubernetes Cluster Scaling and VM Detection Script${NC}")

Usage: $0 [command] [options]

VM Detection and Sync Commands:
    detect                          Detect running VMs and show configuration
                                    Queries VirtualBox directly for actual VM state

    sync                            Sync Vagrantfile to match running VMs
                                    Updates cluster declarations based on detected state
                                    Creates backup before modifying

    diff                            Show differences between Vagrantfile and reality
                                    Compare Vagrantfile config with running VMs

    backup                          Create timestamped backup of Vagrantfile

    restore [FILENAME]              Restore Vagrantfile from backup
                                    Prompts for selection if filename not provided

Cluster Management Commands:
    show-config                     Display current cluster configuration

    apply                           Apply declarative configuration from script
                                    Edit DESIRED_CLUSTERS in script, then run this

    add-worker                      Add worker node(s) to a cluster
        --cluster CLUSTER           Cluster name (e.g., k8s-prod, k8s-qa, k8s-dev)
        --count COUNT               Number of workers to add (default: 1)

    remove-worker                   Remove worker node from a cluster
        --cluster CLUSTER           Cluster name
        --node NODE_NAME            Node name to remove (e.g., k8s-prod-worker2)

    add-master                      Add master node(s) to a cluster (enables HA)
        --cluster CLUSTER           Cluster name
        --count COUNT               Number of masters to add (default: 1)

    remove-master                   Remove master node from a cluster
        --cluster CLUSTER           Cluster name
        --node NODE_NAME            Node name to remove

    scale-resources                 Scale CPU/Memory for node type
        --cluster CLUSTER           Cluster name
        --type TYPE                 Node type (master or worker)
        [--cpu CPU]                 Number of vCPUs
        [--memory MEMORY]           Memory in MB

Examples:
    # VM Detection and Sync (recommended workflow)
    $0 detect                       # See what's actually running
    $0 diff                         # Check differences
    $0 sync                         # Update Vagrantfile to match reality

    # Backup and Restore
    $0 backup                       # Create backup
    $0 restore                      # Interactive restore

    # Declarative approach (edit DESIRED_CLUSTERS in script, then apply)
    $0 apply

    # Show current configuration
    $0 show-config

    # Add 2 workers to k8s-prod cluster
    $0 add-worker --cluster k8s-prod --count 2

    # Remove specific worker
    $0 remove-worker --cluster k8s-qa --node k8s-qa-worker2

    # Add master for HA (creates load balancer automatically)
    $0 add-master --cluster k8s-prod --count 1

    # Scale worker resources
    $0 scale-resources --cluster k8s-prod --type worker --cpu 2 --memory 2048

    # Scale master resources
    $0 scale-resources --cluster k8s-qa --type master --cpu 4 --memory 4096

EOF
}

# ========================================================================================================================
# MAIN SCRIPT
# ========================================================================================================================

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

        add-worker)
            local cluster=""
            local count=1

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster) cluster=$2; shift 2 ;;
                    --count) count=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ]; then
                log_error "Missing --cluster option"
                exit 1
            fi

            add_worker_nodes "$cluster" "$count"
            ;;

        remove-worker)
            local cluster=""
            local node=""

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster) cluster=$2; shift 2 ;;
                    --node) node=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ] || [ -z "$node" ]; then
                log_error "Missing required options: --cluster and --node"
                exit 1
            fi

            remove_worker_nodes "$cluster" "$node"
            ;;

        add-master)
            local cluster=""
            local count=1

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster) cluster=$2; shift 2 ;;
                    --count) count=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ]; then
                log_error "Missing --cluster option"
                exit 1
            fi

            add_master_nodes "$cluster" "$count"
            ;;

        remove-master)
            local cluster=""
            local node=""

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster) cluster=$2; shift 2 ;;
                    --node) node=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ] || [ -z "$node" ]; then
                log_error "Missing required options: --cluster and --node"
                exit 1
            fi

            remove_master_nodes "$cluster" "$node"
            ;;

        scale-resources)
            local cluster=""
            local node_type=""
            local cpu=""
            local memory=""

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --cluster) cluster=$2; shift 2 ;;
                    --type) node_type=$2; shift 2 ;;
                    --cpu) cpu=$2; shift 2 ;;
                    --memory) memory=$2; shift 2 ;;
                    *) log_error "Unknown option: $1"; exit 1 ;;
                esac
            done

            if [ -z "$cluster" ] || [ -z "$node_type" ]; then
                log_error "Missing required options: --cluster and --type"
                exit 1
            fi

            if [ -z "$cpu" ] && [ -z "$memory" ]; then
                log_error "Must specify at least --cpu or --memory"
                exit 1
            fi

            scale_resources "$cluster" "$node_type" "$cpu" "$memory"
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

# Run main function
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
# ========================================================================================================================
# END OF CLUSTER SCALER SCRIPT
# ========================================================================================================================
