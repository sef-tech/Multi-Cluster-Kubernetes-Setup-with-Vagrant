# -*- mode: ruby -*-
# vi: set ft=ruby :

# =====================================================================================================================================
#                                   MULTI-CLUSTER KUBERNETES SETUP WITH PASSWORDLESS SSH
# -------------------------------------------------------------------------------------------------------------------------------------
#             FOR DEVELOPMENT, TESTING, AND LEARNING PURPOSES ONLY .. FOR DEVELOPMENT, TESTING, AND LEARNING PURPOSES ONLY                        
# =====================================================================================================================================
#
# This Vagrantfile creates multiple high-availability Kubernetes clusters with:
#   • Multiple master nodes (configurable per cluster)
#   • Multiple worker nodes (configurable per cluster)
#   • HAProxy load balancer for HA setups (automatically created when master_count > 1)
#   • Calico CNI for pod networking
#   • MetalLB for LoadBalancer service type
#   • Headlamp Kubernetes UI (SIG-UI successor to archived kubernetes-dashboard), deployed via Helm
#   • Passwordless SSH between all VMs (within and across clusters)
#
# IMPORTANT - WINDOWS UAC PERMISSIONS:
#   • VirtualBox requires administrator privileges to create network adapters
#   • To avoid UAC prompts, you MUST run your terminal as Administrator
#   • Navigate to project directory
#   • Run: vagrant up
#
#   NOTE: If you see UAC prompts, click "Yes" - the setting will be remembered for future runs
#
# SSH Configuration:
#   • Each VM generates its own SSH key pair during provisioning
#   • Public keys are shared via /vagrant/.vagrant/ssh-keys/ directory
#   • Progressive key distribution allows nodes to SSH immediately as they provision
#   • Continuous background sync process imports new keys automatically every 3 seconds
#   • Result: Any VM can SSH to any other VM without password or "yes" prompt
#   • Ensure that the script "distribute-ssh-keys-dynamic-vm.sh" is in same directory as the Vagrantfile
#
# Clusters Configuration:
#   • dr:       Disaster Recovery cluster
#   • prod:     Production cluster
#   • pre-prod: Pre-production cluster
#   • qa:       QA/Testing cluster
#   • dev:      Development cluster
#
#   • Each cluster is independent but VMs can communicate with and across clusters via passwordless SSH
#
# Resource Recommendations (per VM):
#   • Master Nodes:  2 vCPU, 4GB RAM minimum
#   • Worker Nodes:  1 vCPU, 2GB RAM minimum
#   • Load Balancer: 1 vCPU, 1GB RAM minimum recommended for Ubuntu 24.04 to prevent OOM errors
#
# Kubernetes Dashboard Access:
#   • Headlamp (official kubernetes-sigs successor to the archived kubernetes-dashboard) is deployed via Helm
#   • Helm repo: https://kubernetes-sigs.github.io/headlamp/
#   • Installed into the 'headlamp' namespace with service type NodePort
#   • Access URL: http://<primary-master-ip>:<nodeport>  (HTTP — no cert warning)
#   • Login token stored as a long-lived Secret (admin-user-token) — printed at end of provisioning
#   • HAProxy stats page: http://<lb-ip>:8404/stats (for HA clusters)
#
# Note: Adjust the CLUSTERS hash in the "ALL_CLUSTERS_DECLARATION" below to customize cluster sizes and resources.
# =====================================================================================================================================
#
# Example AWS EC2 t2 Instance Types for Reference
# -----------------------------------------------
# Instance Type                     Family                    vCPU      CPU Cores        Threads/Core       Memory (GiB)    Memory (GB)
#   t2.micro              General Purpose (burstable)           1          ~1                ~1                  1              1.1
#   t2.medium             General Purpose (burstable)           2          ~2                ~1                  4              4.3
#   t2.large              General Purpose (burstable)           2          ~2                ~1                  8              8.6
#   t2.xlarge             General Purpose (burstable)           4          ~4                ~1                 16            17.20
#   t2.2xlarge            General Purpose (burstable)           8          ~8                ~1                 32            34.40
#
# --------------------------------------------------------------
# Tested on HP OmniStudio X 31.5 inch All-in-One Desktop System
# --------------------------------------------------------------
# Specifications:
    # Intel Core Ultra 7 155H
    #     16 Cores (Worker)
    #     22 Threads (Task Handling)
    #             1 Core handles 2 threads
    #             Up to 4.8 GHz with Intel Turbo Boost Technology
    #             24 MB L3 cache
    #             Intel Arc Graphics
    #     64GB RAM - Kingston FURY Impact 64GB (2x32GB) 5600MT/s DDR5 CL40
    #     4TB PCIe 4.0 NVMe SSD Storage (7,400 MB/s read, 6,500 MB/s write)
# -------------------------------------------------------------------------------------------------------------------------------------

# =====================================================================================================================================
# 🧩 CLUSTER DEFINITIONS
# =====================================================================================================================================

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

# -------------------------------------------------------------
# 🔢 CENTRALIZED IP OFFSET & GLOBAL LB HARDWARE CONFIGURATION
# -------------------------------------------------------------

# IP Offsets for each node type/index
IP_OFFSETS = {
  'lb_vip'  => 10,
  'lb'      => 20,
  'master'  => { 1 => 11, 2 => 12, 3 => 13, 4 => 14, 5 => 15, 6 => 16, 7 => 17, 8 => 18, 9 => 19, 10 => 20, 11 => 31, 12 => 33},
  'worker'  => { 1 => 21, 2 => 22, 3 => 23, 4 => 24, 5 => 25, 6 => 26, 7 => 27, 8 => 28, 9 => 29, 10 => 30, 11 => 32, 12 => 34}
}

# =====================================================================================================================================
# 🌍 LOAD BALANCER CONFIGURATION - GLOBAL Load Balancer Hardware
# =====================================================================================================================================
# Minimum LB memory to prevent OOM errors on Ubuntu 24.04 should be 1024MB (1GB)

LB_CPUS   = 1
LB_MEMORY = 1024

# =====================================================================================================================================
# BASE BOX & VERSION CONFIGURATION
# =====================================================================================================================================
# Supported boxes (uncomment ONE set):

# Boxes Repo: https://portal.cloud.hashicorp.com/vagrant/discover

# Option 1: Bento Ubuntu 24.04 (Recommended - uses password auth)
BOX_IMAGE         = "bento/ubuntu-24.04"
BOX_VERSION       = "202510.26.0"

# Option 2: Ubuntu 22.04 LTS Jammy (Alternative - uses insecure key)
# BOX_IMAGE         = "ubuntu/jammy64"
# BOX_VERSION       = "20241002.0.0"

# Option 3: Generic Ubuntu 22.04 (Fallback - uses insecure key)
# BOX_IMAGE         = "generic/ubuntu2204"
# BOX_VERSION       = nil

BOX_CHECK_UPDATES = false

# =====================================================================================================================================
# KUBERNETES & CONTAINER RUNTIME VERSIONS
# =====================================================================================================================================

K8S_VERSION             = "1.32"                        # Check latest version: https://github.com/kubernetes/kubernetes/releases
CRI_DOCKERD_VERSION     = "v0.3.24"                     # Check latest version: https://github.com/Mirantis/cri-dockerd

# =====================================================================================================================================
# CNI & LOAD BALANCER VERSIONS
# =====================================================================================================================================

CALICO_VERSION          = "v3.31.3"                     # Check latest version: https://github.com/projectcalico/calico/releases
METALLB_VERSION         = "v0.15.3"                     # Check latest version: https://github.com/metallb/metallb/releases
METRICS_SERVER_REPLICAS = 2                             # Number of Metrics Server replicas for high availability
HEADLAMP_VERSION        = "0.40.0"                      # Check latest version: https://artifacthub.io/packages/helm/headlamp/headlamp
HELM_VERSION            = "4.1.1"                       # Check latest version: https://github.com/helm/helm/releases

# =====================================================================================================================================
# NETWORK & SSH CONFIGURATION
# =====================================================================================================================================

INTER_CLUSTER_NETWORK   = "k8s-multi-cluster-intranet"
VAGRANT_DEFAULT_KEY     = "~/.vagrant.d/insecure_private_key"

# =====================================================================================================================================
# 📜 INLINE PROVISIONING SCRIPTS
# =====================================================================================================================================

# Hostname Resolution Setup
HOSTS_SETUP_SCRIPT = <<-'SHELL'
#!/bin/bash
HOSTS_CONFIG="$1"
echo "Configuring /etc/hosts for inter-node communication..."
# Append static host entries to /etc/hosts, ignoring local entries
echo -e "\n# VAGRANT K8S CLUSTER NODES\n$HOSTS_CONFIG" | sudo tee -a /etc/hosts > /dev/null
SHELL

# =====================================================================================================================================
# 📜 SSH CONFIGURATION SETUP
# =====================================================================================================================================

SSH_SETUP_SCRIPT = <<-'SHELL'
#!/bin/bash
set +x
echo "================================================================================================"
echo "SSH KEY SETUP - GENERATING AND SHARING KEYS"
echo "================================================================================================"
set -x

echo "Node: $(hostname)"

# Create SSH directory structure
SSH_DIR="/home/vagrant/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown vagrant:vagrant "$SSH_DIR"

# Generate new SSH key pair
if [ ! -f "$SSH_DIR/id_rsa" ]; then
  echo "Generating SSH key pair for $(hostname)..."
  sudo -u vagrant ssh-keygen -t rsa -b 2048 -f "$SSH_DIR/id_rsa" -N "" -C "vagrant@$(hostname)"
  echo "✓ SSH key pair generated"
else
  echo "SSH key already exists, skipping generation"
fi

# Create shared SSH keys directory
mkdir -p /vagrant/.vagrant/ssh-keys
chmod 755 /vagrant/.vagrant/ssh-keys

# Copy public key to shared directory with hostname
cp "$SSH_DIR/id_rsa.pub" "/vagrant/.vagrant/ssh-keys/$(hostname).pub"
echo "✓ Public key copied to shared directory"

# PROGRESSIVE KEY DISTRIBUTION: Import all existing keys from shared directory
# This allows nodes to SSH to each other as they provision, without waiting for the final trigger
touch "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chown vagrant:vagrant "$SSH_DIR/authorized_keys"

echo "Importing existing SSH keys from shared directory..."
KEY_COUNT=0
if ls /vagrant/.vagrant/ssh-keys/*.pub 1> /dev/null 2>&1; then
  for key_file in /vagrant/.vagrant/ssh-keys/*.pub; do
    if [ -f "$key_file" ]; then
      key_content=$(cat "$key_file")
      if ! grep -qF "$key_content" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        echo "$key_content" >> "$SSH_DIR/authorized_keys"
        KEY_COUNT=$((KEY_COUNT + 1))
      fi
    fi
  done
fi
echo "✓ Imported $KEY_COUNT public key(s) to authorized_keys"

# Set final permissions
chmod 600 "$SSH_DIR/authorized_keys"
chown vagrant:vagrant "$SSH_DIR/authorized_keys"

# Configure SSH client to prevent host key checking prompts
cat > "$SSH_DIR/config" <<'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
    LogLevel ERROR
    ServerAliveInterval 60
    ServerAliveCountMax 3
    IdentityFile ~/.ssh/id_rsa
    User vagrant
EOF

chmod 600 "$SSH_DIR/config"
chown vagrant:vagrant "$SSH_DIR/config"
echo "✓ SSH client configured (host key checking disabled)"

# ⚠️ Configure SSH server for key authentication with sudo
sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Ensure password authentication is temporarily enabled for initial setup
sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

sudo systemctl restart ssh

# Wait for SSH to fully restart
sleep 3

# RE-IMPORT: Check for any new keys that were added while we were setting up SSH
# This catches keys from VMs that provisioned in parallel
echo "Re-checking for new SSH keys..."
NEW_KEY_COUNT=0
if ls /vagrant/.vagrant/ssh-keys/*.pub 1> /dev/null 2>&1; then
  for key_file in /vagrant/.vagrant/ssh-keys/*.pub; do
    if [ -f "$key_file" ]; then
      key_content=$(cat "$key_file")
      if ! grep -qF "$key_content" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        echo "$key_content" >> "$SSH_DIR/authorized_keys"
        NEW_KEY_COUNT=$((NEW_KEY_COUNT + 1))
      fi
    fi
  done
fi

if [ $NEW_KEY_COUNT -gt 0 ]; then
  echo "✓ Imported $NEW_KEY_COUNT additional key(s)"
  chmod 600 "$SSH_DIR/authorized_keys"
  chown vagrant:vagrant "$SSH_DIR/authorized_keys"
fi

# Display final authorized_keys count
TOTAL_KEYS=$(grep -c "^ssh-rsa" "$SSH_DIR/authorized_keys" 2>/dev/null || echo 0)
echo "✓ Total SSH keys in authorized_keys: $TOTAL_KEYS"

# ⚠️ Start continuous SSH key sync background process
# This ensures that keys from nodes provisioning later are automatically imported
echo "Starting continuous SSH key sync process..."
cat > /tmp/ssh-key-sync-loop.sh <<'SYNCLOOP'
#!/bin/bash
# Continuous SSH key synchronization loop
# Watches the shared directory and imports new keys as they appear

while true; do
  SSH_DIR="/home/vagrant/.ssh"
  AUTH_KEYS="$SSH_DIR/authorized_keys"
  SSH_KEYS_DIR="/vagrant/.vagrant/ssh-keys"

  # Only proceed if authorized_keys exists and there are key files
  if [ -f "$AUTH_KEYS" ] && ls "$SSH_KEYS_DIR"/*.pub 1> /dev/null 2>&1; then
    CHANGED=0
    for key_file in "$SSH_KEYS_DIR"/*.pub; do
      if [ -f "$key_file" ]; then
        key_content=$(cat "$key_file")
        if ! grep -qF "$key_content" "$AUTH_KEYS" 2>/dev/null; then
          echo "$key_content" >> "$AUTH_KEYS"
          CHANGED=1
        fi
      fi
    done

    # If keys were added, clean up duplicates and fix permissions
    if [ $CHANGED -eq 1 ]; then
      sort -u "$AUTH_KEYS" > "$AUTH_KEYS.tmp" && mv "$AUTH_KEYS.tmp" "$AUTH_KEYS"
      chmod 600 "$AUTH_KEYS"
      chown vagrant:vagrant "$AUTH_KEYS"
    fi
  fi

  # Check every 3 seconds
  sleep 3
done
SYNCLOOP

chmod +x /tmp/ssh-key-sync-loop.sh

# Start sync loop in background, redirect all output to prevent clutter
nohup /tmp/ssh-key-sync-loop.sh &> /dev/null &
SYNC_PID=$!
echo "✓ SSH key sync process started (PID: $SYNC_PID)"

set +x
echo "================================================================================================"
echo "✓ SSH key setup complete for $(hostname)"
echo "================================================================================================"
set -x
SHELL

# =====================================================================================================================================
# LOAD BALANCER BASE SETUP (System Configuration ONLY - no Kubernetes/Docker)
# =====================================================================================================================================

LB_BASE_SETUP_SCRIPT = <<-'SHELL'
#!/bin/bash
LB_IP="$1"
NODE_HOSTNAME="$2"
set -e
echo "Starting Load Balancer base setup on ${NODE_HOSTNAME}..."

# ⚠️ Auto-detect private network interface by IP (supports eth1, enp0s8, etc.)
echo "Detecting private network interface configuration..."
echo "  Target IP: ${LB_IP}"

# Auto-detect the private network interface by finding which one has/will have our IP
PRIVATE_IFACE=""
for i in {1..30}; do
    # Get all non-loopback interfaces
    ALL_IFACES=$(ip link show | grep -E "^[0-9]+: " | awk -F': ' '{print $2}' | grep -v "lo" | grep -v "@")

    for iface in $ALL_IFACES; do
        # Check if this interface already has our target IP
        IFACE_IP=$(ip addr show $iface 2>/dev/null | grep "inet " | grep -v "inet6" | awk '{print $2}' | cut -d/ -f1)

        if [ "$IFACE_IP" = "$LB_IP" ]; then
            PRIVATE_IFACE="$iface"
            echo "  ✓ Found interface $PRIVATE_IFACE with IP $LB_IP"
            break 2
        fi
    done

    # If not found yet, check for newly attached interfaces
    if [ $i -eq 30 ]; then
        echo "  ⚠️  Could not find interface with IP $LB_IP"
        echo "  Available interfaces and IPs:"
        ip addr show | grep -E "^[0-9]+: |inet " | grep -v "inet6"

        # Try to find an interface without an IP yet (likely the one waiting for configuration)
        for iface in $ALL_IFACES; do
            IFACE_IP=$(ip addr show $iface 2>/dev/null | grep "inet " | grep -v "inet6" | awk '{print $2}' | cut -d/ -f1)
            IFACE_STATE=$(ip link show $iface 2>/dev/null | grep "state UP" || true)

            # If interface is up and has an IP in our subnet range, use it
            if [ -n "$IFACE_STATE" ] && [[ "$IFACE_IP" =~ ^192\.168\. ]]; then
                PRIVATE_IFACE="$iface"
                echo "  ✓ Using interface $PRIVATE_IFACE (detected from subnet match)"
                break
            fi
        done

        if [ -z "$PRIVATE_IFACE" ]; then
            echo "  ✗ ERROR: Could not auto-detect private network interface"
            exit 1
        fi
        break
    fi

    sleep 1
done

# Ensure the interface is up
sudo ip link set $PRIVATE_IFACE up

# Wait for the IP address to be configured correctly
for i in {1..60}; do
    CURRENT_IP=$(ip addr show $PRIVATE_IFACE 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)

    if [ "$CURRENT_IP" = "$LB_IP" ]; then
        echo "  ✓ Interface $PRIVATE_IFACE has correct IP: $LB_IP"
        break
    elif [ -n "$CURRENT_IP" ]; then
        echo "  ⚠️  Interface $PRIVATE_IFACE has IP $CURRENT_IP but expected $LB_IP"
    fi

    if [ $i -eq 60 ]; then
        echo "  ✗ ERROR: Failed to configure IP $LB_IP on $PRIVATE_IFACE after 60 seconds"
        echo "  Current configuration:"
        ip addr show $PRIVATE_IFACE
        echo ""
        echo "  Attempting manual configuration..."
        sudo ip addr flush dev $PRIVATE_IFACE
        sudo ip addr add ${LB_IP}/24 dev $PRIVATE_IFACE
        sudo ip link set $PRIVATE_IFACE up
        sleep 2

        # Verify manual configuration
        CURRENT_IP=$(ip addr show $PRIVATE_IFACE 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        if [ "$CURRENT_IP" = "$LB_IP" ]; then
            echo "  ✓ Manual configuration successful: $LB_IP"
            break
        else
            echo "  ✗ Manual configuration failed"
            exit 1
        fi
    fi

    sleep 1
done

# Test connectivity on the private network by pinging the subnet's gateway IP
GATEWAY_IP=$(echo ${LB_IP} | cut -d. -f1-3).1
echo "  Testing network connectivity to gateway ${GATEWAY_IP}..."
if ping -c 2 -W 2 ${GATEWAY_IP} >/dev/null 2>&1; then
    echo "  ✓ Network connectivity verified"
else
    echo "  ⚠️  Cannot ping gateway, but continuing (may be firewall)"
fi

echo "✓ Network interface configuration complete"

# 🟢 Install General Utility Packages
echo "Installing essential utilities..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential net-tools util-linux software-properties-common \
  curl wget unzip zip tar vim nano htop tree jq dnsutils iputils-ping \
  traceroute nmap lsof psmisc sysstat screen tmux parted ncal rsync whois \
  ca-certificates gnupg lsb-release strace tcpdump netcat-openbsd proot \
  unrar p7zip-full exfatprogs ntfs-3g cloud-utils e2fsprogs xfsprogs nfs-common socat \
  || true

# ⚠️ Disable systemd-resolved to prevent DNS conflicts
echo "Disabling systemd-resolved to prevent DNS conflicts..."
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved

# ⚠️ Create static /etc/resolv.conf
echo "Creating static DNS configuration..."
# Remove immutable attribute if set (from previous provisioning)
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /etc/resolv.conf
cat <<EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
sudo chattr +i /etc/resolv.conf

# Ensure SSH service is running and enabled
echo "Ensuring SSH service is running..."
sudo systemctl enable ssh
sudo systemctl restart ssh

echo "✅ Load balancer base setup complete for ${NODE_HOSTNAME}"
SHELL

# =====================================================================================================================================
# BASE SETUP (Control Plane and Worker Nodes ONLY)
# =====================================================================================================================================

BASE_SETUP_SCRIPT = <<-'SHELL'
#!/bin/bash
CRI_DOCKERD_VERSION="$1"
K8S_VERSION="$2"
NODE_IP="$3"
NODE_HOSTNAME="$4"
set -e
echo "Starting K8s base setup (Docker, Kubeadm) on ${NODE_HOSTNAME}..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# ⚠️ Mask swap.img service to prevent re-enabling (Ubuntu 24.04)
echo "Masking swap file service..."
sudo systemctl mask swap.img.swap 2>/dev/null || true

# ⚠️ Auto-detect private network interface by IP (supports eth1, enp0s8, etc.)
echo "Detecting private network interface configuration..."
echo "  Target IP: ${NODE_IP}"

# Auto-detect the private network interface by finding which one has/will have our IP
PRIVATE_IFACE=""
for i in {1..30}; do
    # Get all non-loopback interfaces
    ALL_IFACES=$(ip link show | grep -E "^[0-9]+: " | awk -F': ' '{print $2}' | grep -v "lo" | grep -v "@")

    for iface in $ALL_IFACES; do
        # Check if this interface already has our target IP
        IFACE_IP=$(ip addr show $iface 2>/dev/null | grep "inet " | grep -v "inet6" | awk '{print $2}' | cut -d/ -f1)

        if [ "$IFACE_IP" = "$NODE_IP" ]; then
            PRIVATE_IFACE="$iface"
            echo "  ✓ Found interface $PRIVATE_IFACE with IP $NODE_IP"
            break 2
        fi
    done

    # If not found yet, check for newly attached interfaces
    # VirtualBox may still be attaching the private network adapter
    if [ $i -eq 30 ]; then
        echo "  ⚠️  Could not find interface with IP $NODE_IP"
        echo "  Available interfaces and IPs:"
        ip addr show | grep -E "^[0-9]+: |inet " | grep -v "inet6"

        # Try to find an interface without an IP yet (likely the one waiting for configuration)
        # Look for interfaces that are UP but don't have an IP in the 192.168 range yet
        for iface in $ALL_IFACES; do
            IFACE_IP=$(ip addr show $iface 2>/dev/null | grep "inet " | grep -v "inet6" | awk '{print $2}' | cut -d/ -f1)
            IFACE_STATE=$(ip link show $iface 2>/dev/null | grep "state UP" || true)

            # If interface is up and has an IP in our subnet range, use it
            if [ -n "$IFACE_STATE" ] && [[ "$IFACE_IP" =~ ^192\.168\. ]]; then
                PRIVATE_IFACE="$iface"
                echo "  ✓ Using interface $PRIVATE_IFACE (detected from subnet match)"
                break
            fi
        done

        if [ -z "$PRIVATE_IFACE" ]; then
            echo "  ✗ ERROR: Could not auto-detect private network interface"
            exit 1
        fi
        break
    fi

    sleep 1
done

# Ensure the interface is up
sudo ip link set $PRIVATE_IFACE up

# Wait for the IP address to be configured correctly
for i in {1..60}; do
    CURRENT_IP=$(ip addr show $PRIVATE_IFACE 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)

    if [ "$CURRENT_IP" = "$NODE_IP" ]; then
        echo "  ✓ Interface $PRIVATE_IFACE has correct IP: $NODE_IP"
        break
    elif [ -n "$CURRENT_IP" ]; then
        echo "  ⚠️  Interface $PRIVATE_IFACE has IP $CURRENT_IP but expected $NODE_IP"
    fi

    if [ $i -eq 60 ]; then
        echo "  ✗ ERROR: Failed to configure IP $NODE_IP on $PRIVATE_IFACE after 60 seconds"
        echo "  Current configuration:"
        ip addr show $PRIVATE_IFACE
        echo ""
        echo "  Attempting manual configuration..."
        sudo ip addr flush dev $PRIVATE_IFACE
        sudo ip addr add ${NODE_IP}/24 dev $PRIVATE_IFACE
        sudo ip link set $PRIVATE_IFACE up
        sleep 2

        # Verify manual configuration
        CURRENT_IP=$(ip addr show $PRIVATE_IFACE 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        if [ "$CURRENT_IP" = "$NODE_IP" ]; then
            echo "  ✓ Manual configuration successful: $NODE_IP"
            break
        else
            echo "  ✗ Manual configuration failed"
            exit 1
        fi
    fi

    sleep 1
done

# Test connectivity on the private network by pinging the subnet's gateway IP
GATEWAY_IP=$(echo ${NODE_IP} | cut -d. -f1-3).1
echo "  Testing network connectivity to gateway ${GATEWAY_IP}..."
if ping -c 2 -W 2 ${GATEWAY_IP} >/dev/null 2>&1; then
    echo "  ✓ Network connectivity verified"
else
    echo "  ⚠️  Cannot ping gateway, but continuing (may be firewall)"
fi

echo "✓ Network interface configuration complete"

# 🟢 Install General Utility Packages
echo "Installing essential utilities..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential net-tools util-linux software-properties-common \
  curl wget unzip zip tar vim nano htop tree jq dnsutils iputils-ping \
  traceroute nmap lsof psmisc sysstat screen tmux parted ncal rsync whois \
  ca-certificates gnupg lsb-release strace tcpdump netcat-openbsd proot \
  unrar p7zip-full exfatprogs ntfs-3g cloud-utils e2fsprogs xfsprogs nfs-common socat \
  || true

# ⚠️ Install IPVS requirements for Kube-proxy and CNI
sudo apt-get install -y ipset ipvsadm

# ⚠️ Disable systemd-resolved to prevent DNS conflicts
echo "Disabling systemd-resolved to prevent DNS conflicts..."
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved

# ⚠️ Create static /etc/resolv.conf
echo "Creating static DNS configuration..."
# Remove immutable attribute if set (from previous provisioning)
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /etc/resolv.conf
cat <<EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
sudo chattr +i /etc/resolv.conf

# 🐳 Install Docker + Containerd
echo "Installing Docker (version ${CRI_DOCKERD_VERSION})..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ⚠️ Configure Containerd for Kubernetes compatibility
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# ⚠️ Enable SystemdCgroup for runc
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Restart containerd to apply configuration
sudo systemctl restart containerd

# Ensure Docker starts on boot
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# Add vagrant user to docker group
sudo usermod -aG docker vagrant
newgrp docker $USER

# 📦 Install Kubernetes Tools (kubelet, kubeadm, kubectl)
echo "Installing Kubernetes components (version ${K8S_VERSION})..."

# Add Kubernetes Repository GPG Key and APT Source
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl

# Prevent accidental upgrades
sudo apt-mark hold kubelet kubeadm kubectl

# ⚠️ Configure kubelet to use the correct node IP (prevents IP mismatch issues)
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" | sudo tee /etc/default/kubelet

# Restart kubelet to apply the node IP configuration
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Wait for kubelet to stabilize with new configuration
echo "Waiting for kubelet to stabilize..."
sleep 15
echo "✓ Kubelet configured with node IP: ${NODE_IP}"
SHELL

# =====================================================================================================================================
# PRIMARY MASTER INITIALIZATION SCRIPT
# =====================================================================================================================================

MASTER_INIT_SCRIPT = <<-'SHELL'
#!/bin/bash
CLUSTER_NAME="$1"
K8S_API_ENDPOINT="$2"
CALICO_VERSION="$3"
K8S_VERSION="$4"
NODE_IP="$5"
CONTEXT_NAME="$6"

echo "📦 Initializing Kubernetes PRIMARY master for cluster: ${CLUSTER_NAME}..."

# Wait for kubelet to be ready
echo "Waiting for kubelet to be ready..."
for i in {1..30}; do
    if sudo systemctl is-active --quiet kubelet; then
        echo "✅ Kubelet is active"
        break
    fi
    echo "Waiting for kubelet (attempt $i/30)..."
    sleep 2
done

# Determine the correct pod network CIDR based on cluster
if [[ "$CLUSTER_NAME" == "k8s-dev" ]]; then
    POD_NETWORK_CIDR="10.244.0.0/16"
elif [[ "$CLUSTER_NAME" == "k8s-qa" ]]; then
    POD_NETWORK_CIDR="10.245.0.0/16"
elif [[ "$CLUSTER_NAME" == "k8s-pre-prod" ]]; then
    POD_NETWORK_CIDR="10.246.0.0/16"
elif [[ "$CLUSTER_NAME" == "k8s-prod" ]]; then
    POD_NETWORK_CIDR="10.247.0.0/16"
elif [[ "$CLUSTER_NAME" == "k8s-dr" ]]; then
    POD_NETWORK_CIDR="10.248.0.0/16"
else
    echo "❌ Unknown cluster: ${CLUSTER_NAME}"
    exit 1
fi

# Initialize the cluster
echo "Initializing Kubernetes cluster with API endpoint: ${K8S_API_ENDPOINT}"
sudo kubeadm init \
  --control-plane-endpoint="${K8S_API_ENDPOINT}" \
  --apiserver-advertise-address="${NODE_IP}" \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --upload-certs

# Configure kubectl for vagrant user
mkdir -p $HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify the config file exists and is readable
if [ ! -f "$HOME/.kube/config" ]; then
    echo "❌ ERROR: kubeconfig file not found at $HOME/.kube/config"
    exit 1
fi

# Export KUBECONFIG to ensure all kubectl commands use the correct config
export KUBECONFIG=$HOME/.kube/config
echo "✅ KUBECONFIG set to: $KUBECONFIG"
ls -lh $KUBECONFIG

# Configure kubectl context with proper naming by editing the kubeconfig file
# Replace cluster name: "kubernetes" -> "${CLUSTER_NAME}" (e.g., "k8s-prod")
sed -i "s/name: kubernetes$/name: ${CLUSTER_NAME}/" $HOME/.kube/config
# Replace user name: "kubernetes-admin" -> "${CONTEXT_NAME}-admin" (e.g., "prod-admin")
sed -i "s/name: kubernetes-admin$/name: ${CONTEXT_NAME}-admin/" $HOME/.kube/config
# Replace context cluster reference
sed -i "s/cluster: kubernetes$/cluster: ${CLUSTER_NAME}/" $HOME/.kube/config
# Replace context user reference
sed -i "s/user: kubernetes-admin$/user: ${CONTEXT_NAME}-admin/" $HOME/.kube/config
# Replace context name
sed -i "s/name: kubernetes-admin@kubernetes$/name: ${CONTEXT_NAME}/" $HOME/.kube/config
# Set current context
sed -i "s/current-context: kubernetes-admin@kubernetes$/current-context: ${CONTEXT_NAME}/" $HOME/.kube/config

echo "✅ Kubectl context configured as '${CONTEXT_NAME}' with cluster '${CLUSTER_NAME}'"

# Verify cluster is running
echo "Waiting for API server to be ready..."
for i in {1..60}; do
    if KUBECONFIG=$HOME/.kube/config kubectl get nodes 2>&1; then
        echo "✅ API server is responding"
        break
    fi
    echo "Waiting for API server (attempt $i/60)..."
    sleep 2
done

set +x
echo "================================================================================================"
echo "INSTALLING CNI (CALICO)"
echo "================================================================================================"
set -x

echo "Deploying Calico CNI (version ${CALICO_VERSION})..."
KUBECONFIG=$HOME/.kube/config kubectl create --validate=false -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml || true

# Wait for tigera-operator to be ready
echo "Waiting for tigera-operator to be ready..."
KUBECONFIG=$HOME/.kube/config kubectl wait --for=condition=available --timeout=120s deployment/tigera-operator -n tigera-operator 2>/dev/null || {
    echo "Waiting for tigera-operator deployment to exist..."
    for i in {1..30}; do
        if KUBECONFIG=$HOME/.kube/config kubectl get deployment tigera-operator -n tigera-operator 2>/dev/null; then
            KUBECONFIG=$HOME/.kube/config kubectl wait --for=condition=available --timeout=120s deployment/tigera-operator -n tigera-operator
            break
        fi
        echo "  Attempt $i/30: tigera-operator not found yet..."
        sleep 2
    done
}

# ⚠️ Wait for Calico CRDs to be established AND API server to register them
echo "Waiting for Calico CRDs to be established and registered..."
for i in {1..60}; do
    if KUBECONFIG=$HOME/.kube/config kubectl get crd installations.operator.tigera.io 2>/dev/null && \
       KUBECONFIG=$HOME/.kube/config kubectl get crd apiservers.operator.tigera.io 2>/dev/null; then
        echo "✅ Calico CRDs exist"
        # ⚠️ Critical - wait for API server to fully register CRDs before using them
        echo "Waiting for API server to register CRDs (10s)..."
        sleep 10
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for CRDs (attempt $i/60)..."
    sleep 2
done

# ⚠️ Apply custom Calico resource with retry logic and exponential backoff
echo "Configuring Calico with CIDR ${POD_NETWORK_CIDR}..."
MAX_RETRIES=5
RETRY_DELAY=5

for attempt in $(seq 1 $MAX_RETRIES); do
    if cat <<EOF | KUBECONFIG=$HOME/.kube/config kubectl apply --validate=false -f - 2>&1
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_NETWORK_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF
    then
        echo "✅ Calico Installation applied successfully"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "⚠️  Attempt $attempt failed, retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
            RETRY_DELAY=$((RETRY_DELAY * 2))
        else
            echo "❌ Failed to apply Calico Installation after $MAX_RETRIES attempts"
            exit 1
        fi
    fi
done

# ⚠️ Optimized wait loop - check less frequently, longer intervals, less verbose | Wait for Calico pods to become ready.
echo "Waiting for Calico pods to become ready..."
for i in {1..40}; do
    READY_CALICO=$(KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system 2>/dev/null | grep -c "Running" || echo "0")
    TOTAL_CALICO=$(KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l || echo "0")

    if [ "$READY_CALICO" -ge 2 ] && [ "$TOTAL_CALICO" -ge 2 ]; then
        echo "✅ Calico pods are ready ($READY_CALICO/$TOTAL_CALICO running)"
        KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system
        break
    fi

    # Only show progress every 5th iteration to reduce verbosity
    if [ $((i % 5)) -eq 0 ]; then
        echo "  Calico pods: $READY_CALICO/$TOTAL_CALICO running (check $i/40)"
    fi
    sleep 10
done

# ⚠️ Generate join commands for BOTH control-plane and worker nodes
echo "Generating join commands..."

# Control plane join command (with certificate key)
CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs 2>&1 | tail -1)
echo "Certificate key: ${CERT_KEY:0:20}..."       # Show first 20 chars for verification
sudo kubeadm token create --print-join-command --certificate-key $CERT_KEY > /tmp/master-join-command.sh 2>&1
if [ $? -eq 0 ] && [ -s /tmp/master-join-command.sh ]; then
    chmod 644 /tmp/master-join-command.sh
    echo "✅ Master join command saved to /tmp/master-join-command.sh"
else
    echo "❌ Failed to generate master join command"
    cat /tmp/master-join-command.sh
    exit 1
fi

# Worker join command
sudo kubeadm token create --print-join-command > /tmp/worker-join-command.sh 2>&1
if [ $? -eq 0 ] && [ -s /tmp/worker-join-command.sh ]; then
    chmod 644 /tmp/worker-join-command.sh
    echo "✅ Worker join command saved to /tmp/worker-join-command.sh"
    echo "Join command preview: $(head -c 50 /tmp/worker-join-command.sh)..."
else
    echo "❌ Failed to generate worker join command"
    cat /tmp/worker-join-command.sh
    exit 1
fi

# Create marker file to signal initialization completion
touch /vagrant/.vagrant/master-init-complete-marker
echo "✓ Created initialization completion marker"

# Display cluster status
echo "📊 Initial cluster status:"
KUBECONFIG=$HOME/.kube/config kubectl get nodes -o wide
KUBECONFIG=$HOME/.kube/config kubectl get pods -o wide --all-namespaces

echo "✅ Primary master initialization complete for cluster: ${CLUSTER_NAME}"
SHELL

# =====================================================================================================================================
# CALICO VALIDATION
# =====================================================================================================================================

CALICO_VALIDATION_SCRIPT = <<-'SHELL'
#!/bin/bash
CLUSTER_NAME="$1"
CALICO_VERSION="$2"

echo "🔍 Validating Calico CNI installation for cluster: ${CLUSTER_NAME}..."

# Determine the correct pod network CIDR based on cluster
if [[ "$CLUSTER_NAME" == "k8s-dev" ]]; then
    POD_NETWORK_CIDR="10.244.0.0/16"
elif [[ "$CLUSTER_NAME" == "k8s-qa" ]]; then
    POD_NETWORK_CIDR="10.245.0.0/16"
elif [[ "$CLUSTER_NAME" == "k8s-pre-prod" ]]; then
    POD_NETWORK_CIDR="10.246.0.0/16"
elif [[ "$CLUSTER_NAME" == "k8s-prod" ]]; then
    POD_NETWORK_CIDR="10.247.0.0/16"
elif [[ "$CLUSTER_NAME" == "k8s-dr" ]]; then
    POD_NETWORK_CIDR="10.248.0.0/16"
else
    echo "❌ Unknown cluster: ${CLUSTER_NAME}"
    exit 1
fi

# Set KUBECONFIG
export KUBECONFIG=$HOME/.kube/config
if [ ! -f "$KUBECONFIG" ]; then
    echo "ℹ️  Kubeconfig not found, skipping Calico validation."
    exit 0
fi

# Check if calico-system namespace exists and has running pods
echo "Checking if Calico is already installed..."
CALICO_PODS=$(KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")
CALICO_NS=$(KUBECONFIG=$HOME/.kube/config kubectl get namespace calico-system 2>/dev/null)

if [[ "$CALICO_PODS" -ge 2 ]] && [[ -n "$CALICO_NS" ]]; then
    echo "✅ Calico is already installed and running ($CALICO_PODS pods running)"
    KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system
    exit 0
fi

echo "⚠️  Calico is not properly installed. Installing now..."

# Install Calico operator
echo "Installing Calico operator (version ${CALICO_VERSION})..."
KUBECONFIG=$HOME/.kube/config kubectl create --validate=false -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml 2>&1 || {
    echo "ℹ️  Operator may already exist, continuing..."
}
# Wait for tigera-operator namespace to be created
echo "Waiting for tigera-operator namespace..."
for i in {1..30}; do
    if KUBECONFIG=$HOME/.kube/config kubectl get namespace tigera-operator 2>/dev/null; then
        echo "✅ tigera-operator namespace exists"
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for namespace (attempt $i/30)..."
    sleep 2
done

# Wait for tigera-operator deployment
echo "Waiting for tigera-operator deployment..."
for i in {1..30}; do
    if KUBECONFIG=$HOME/.kube/config kubectl get deployment tigera-operator -n tigera-operator 2>/dev/null; then
        echo "✅ tigera-operator deployment exists"
        KUBECONFIG=$HOME/.kube/config kubectl wait --for=condition=available --timeout=120s deployment/tigera-operator -n tigera-operator 2>/dev/null || true
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for deployment (attempt $i/30)..."
    sleep 2
done

# ⚠️ Wait for Calico CRDs to be established and API server to register them
echo "Waiting for Calico CRDs..."
for i in {1..60}; do
    if KUBECONFIG=$HOME/.kube/config kubectl get crd installations.operator.tigera.io 2>/dev/null; then
        echo "✅ Calico CRDs are ready"
        # ⚠️ Critical - wait for API server to fully register CRDs
        echo "Waiting for API server to register CRDs (10s)..."
        sleep 10
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for CRDs (attempt $i/60)..."
    sleep 2
done

# ⚠️ Configure Calico with retry logic
echo "Configuring Calico with CIDR ${POD_NETWORK_CIDR}..."
MAX_RETRIES=5
RETRY_DELAY=5

for attempt in $(seq 1 $MAX_RETRIES); do
    if cat <<EOF | KUBECONFIG=$HOME/.kube/config kubectl apply --validate=false -f - 2>&1
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_NETWORK_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF
    then
        echo "✅ Calico Installation applied successfully"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "⚠️  Attempt $attempt failed, retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
            RETRY_DELAY=$((RETRY_DELAY * 2))
        else
            echo "❌ Failed to apply Calico Installation after $MAX_RETRIES attempts"
            exit 1
        fi
    fi
done

# ⚠️ Wait loop - check every 10s, less verbose
echo "Waiting for Calico pods to become ready..."
for i in {1..40}; do
    READY_CALICO=$(KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system 2>/dev/null | grep -c "Running" || echo "0")
    TOTAL_CALICO=$(KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l || echo "0")

    if [ "$READY_CALICO" -ge 2 ] && [ "$TOTAL_CALICO" -ge 2 ]; then
        echo "✅ Calico pods are ready ($READY_CALICO/$TOTAL_CALICO running)"
        KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system
        break
    fi

    # Only show progress every 5th check
    if [ $((i % 5)) -eq 0 ]; then
        echo "  Calico pods: $READY_CALICO/$TOTAL_CALICO running (check $i/40)"
    fi
    sleep 10
done

# Wait for nodes to become Ready
echo "Waiting for nodes to become Ready..."
for i in {1..30}; do
    NOT_READY=$(KUBECONFIG=$HOME/.kube/config kubectl get nodes 2>/dev/null | grep -c "NotReady" || echo "0")
    if [ "$NOT_READY" -eq 0 ]; then
        echo "✅ All nodes are Ready"
        KUBECONFIG=$HOME/.kube/config kubectl get nodes
        break
    fi
    [ $((i % 5)) -eq 0 ] && echo "  Waiting for nodes (attempt $i/30)..."
    sleep 5
done

echo "✅ Calico validation and installation complete for cluster: ${CLUSTER_NAME}"
SHELL

# =====================================================================================================================================
# SECONDARY MASTER JOIN SCRIPT (API VALIDATION AND RETRY LOGIC)
# =====================================================================================================================================

MASTER_JOIN_SCRIPT = <<-'SHELL'
#!/bin/bash
PRIMARY_MASTER="$1"
NODE_IP="$2"

echo "🔗 Joining as secondary control plane node..."
echo "  Primary master: ${PRIMARY_MASTER}"
echo "  This node's advertise address: ${NODE_IP}"

# Wait for primary master to complete initialization. Check for join command file which indicates initialization is complete
echo "Waiting for primary master to complete initialization..."
for i in {1..120}; do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o LogLevel=ERROR \
     -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER "test -f /tmp/master-join-command.sh" 2>/dev/null; then
    echo "✅ Primary master initialization complete (join command exists)"
    break
  fi

  # Also check via shared folder if SSH doesn't work yet
  if [ -f /vagrant/.vagrant/master-init-complete-marker ]; then
    echo "✅ Primary master initialization complete (marker file exists)"
    break
  fi

  if [ $((i % 20)) -eq 0 ]; then
    echo "  Waiting for primary master initialization (attempt $i/120)..."
  fi
  sleep 3
done

# SSH options for connecting to primary master
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Function to test SSH connectivity
test_ssh() {
    ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER "echo 'SSH OK'" 2>&1 | grep -q "SSH OK"
}

# Wait for primary master to be SSH accessible. The continuous key sync process should import our key automatically
echo "Waiting for SSH access to primary master..."
echo "  (The continuous key sync process will import keys automatically)"
for i in {1..120}; do
    if test_ssh; then
        echo "✅ SSH connection to primary master established"
        break
    fi

    if [ $((i % 20)) -eq 0 ]; then
        echo "  Still waiting for SSH access (attempt $i/120)..."
        echo "  Testing connection: ssh -i ~/.ssh/id_rsa vagrant@$PRIMARY_MASTER"
    fi
    sleep 3
done

# Verify SSH connectivity one more time
if ! test_ssh; then
    echo "❌ Failed to establish SSH connection to primary master"
    echo "  Diagnostic: Attempting SSH with verbose output..."
    ssh -v $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER "echo 'SSH OK'" 2>&1 | tail -20
    echo "  Checking if primary master SSH port is open..."
    nc -zv $PRIMARY_MASTER 22 2>&1 || echo "  Port 22 not accessible"
    exit 1
fi

# Wait for join command file to be available (better indicator than kubectl check)
echo "Waiting for master join command to be generated on primary master..."
JOIN_COMMAND=""
for i in {1..180}; do
    # Try to retrieve the join command
    JOIN_COMMAND=$(ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa \
        vagrant@$PRIMARY_MASTER "cat /tmp/master-join-command.sh" 2>/dev/null)

    if [ -n "$JOIN_COMMAND" ]; then
        echo "✅ Master join command retrieved successfully"
        break
    fi

    if [ $((i % 30)) -eq 0 ]; then
        echo "  Still waiting for join command (attempt $i/180)..."
        # Show diagnostics
        echo "  Checking master initialization status..."
        ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER \
            "ls -la /tmp/master-join-command.sh /vagrant/.vagrant/master-init-complete-marker 2>&1 | head -5" 2>/dev/null || echo "  Cannot check files yet"
    fi
    sleep 3
done

if [ -z "$JOIN_COMMAND" ]; then
    echo "❌ Failed to retrieve master join command after 540 seconds"
    echo ""
    echo "Diagnostics:"
    echo "  Checking if master initialization completed..."
    ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER \
        "ls -la /tmp/ /vagrant/.vagrant/ 2>&1 | grep -E '(master-join|master-init)'" 2>/dev/null || echo "  Cannot access master"
    echo ""
    echo "  Checking master kubectl status..."
    ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER \
        "KUBECONFIG=/home/vagrant/.kube/config kubectl get nodes 2>&1 | head -10" 2>/dev/null || echo "  kubectl not accessible"
    echo ""
    exit 1
fi

JOIN_COMMAND="${JOIN_COMMAND} --apiserver-advertise-address=${NODE_IP}"
echo "  Join command augmented with --apiserver-advertise-address=${NODE_IP}"

# Extract API server endpoint from join command (format: IP:PORT)
API_ENDPOINT=$(echo "$JOIN_COMMAND" | awk '/kubeadm join/ {print $3}')
echo "API endpoint from join command: $API_ENDPOINT"

if [ -z "$API_ENDPOINT" ]; then
    echo "⚠️  Warning: Could not extract API endpoint from join command"
    echo "  Join command: $JOIN_COMMAND"
    echo "  Proceeding without API validation..."
else
    # Verify API server is accessible via the endpoint (load balancer VIP)
    echo "Verifying API server accessibility via https://$API_ENDPOINT..."
    for i in {1..60}; do
        if curl -k -s --connect-timeout 5 --max-time 10 "https://$API_ENDPOINT/livez" >/dev/null 2>&1; then
            echo "✅ API server is accessible via https://$API_ENDPOINT"
            break
        fi

        if [ $((i % 10)) -eq 0 ]; then
            echo "  Still waiting for API server (attempt $i/60)..."
        fi
        sleep 5
    done
fi

# Execute join command with retries
echo "Executing join command..."
MAX_RETRIES=3
RETRY_DELAY=30

for attempt in $(seq 1 $MAX_RETRIES); do
    echo "Join attempt $attempt/$MAX_RETRIES..."

    if sudo bash -c "$JOIN_COMMAND"; then
        echo "✅ Secondary master successfully joined the cluster!"
        break
    else
        EXIT_CODE=$?

        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "⚠️  Join attempt $attempt failed (exit code: $EXIT_CODE)"

            echo "  Cleaning up failed join artifacts with kubeadm reset..."
            sudo kubeadm reset -f 2>/dev/null || true
            # Also remove any residual etcd data that kubeadm reset might miss
            sudo rm -rf /var/lib/etcd/member 2>/dev/null || true

            echo "  Waiting ${RETRY_DELAY} seconds before retry..."
            sleep $RETRY_DELAY

            # Increase delay for next retry
            RETRY_DELAY=$((RETRY_DELAY * 2))
        else
            echo "❌ Failed to join cluster after $MAX_RETRIES attempts"
            exit 1
        fi
    fi
done

# Configure kubectl for vagrant user
mkdir -p /home/vagrant/.kube
ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa \
    vagrant@$PRIMARY_MASTER "sudo cat /etc/kubernetes/admin.conf" > /home/vagrant/.kube/config 2>/dev/null
chown vagrant:vagrant /home/vagrant/.kube/config

echo "✅ Secondary master join complete!"
SHELL

# =====================================================================================================================================
# WORKER JOIN SCRIPT
# =====================================================================================================================================

WORKER_JOIN_SCRIPT = <<-'SHELL'
#!/bin/bash
PRIMARY_MASTER="$1"

echo "👷 Joining as worker node..."

# Wait for primary master initialization | Give it some time to start up and begin the key sync process
sleep 15

# SSH options
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Function to test SSH connectivity
test_ssh() {
    ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER "echo 'SSH OK'" 2>&1 | grep -q "SSH OK"
}

# Wait for primary master to be accessible
# The continuous key sync process on the primary master will automatically import our key
echo "Waiting for primary master to be accessible..."
echo "  (The continuous key sync process will import keys automatically)"
for i in {1..180}; do
    if test_ssh; then
        echo "✅ SSH connection established"
        break
    fi

    if [ $((i % 30)) -eq 0 ]; then
        echo "  Still waiting (attempt $i/180)..."
        echo "  Testing connection: ssh -i ~/.ssh/id_rsa vagrant@$PRIMARY_MASTER"
    fi
    sleep 3
done

# Verify connection
if ! test_ssh; then
    echo "❌ Failed to connect to primary master"
    echo "  Diagnostic: Attempting SSH with verbose output..."
    ssh -v $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER "echo 'SSH OK'" 2>&1 | tail -20
    echo "  Checking if primary master SSH port is open..."
    nc -zv $PRIMARY_MASTER 22 2>&1 || echo "  Port 22 not accessible"
    exit 1
fi

# Wait for join command file to be available (better indicator than kubectl check)
echo "Waiting for join command to be generated on primary master..."
JOIN_COMMAND=""
for i in {1..180}; do
    # Try to retrieve the join command
    JOIN_COMMAND=$(ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa \
        vagrant@$PRIMARY_MASTER "cat /tmp/worker-join-command.sh" 2>/dev/null)

    if [ -n "$JOIN_COMMAND" ]; then
        echo "✅ Join command retrieved successfully"
        break
    fi

    if [ $((i % 30)) -eq 0 ]; then
        echo "  Still waiting for join command (attempt $i/180)..."
        # Show diagnostics
        echo "  Checking master initialization status..."
        ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER \
            "ls -la /tmp/worker-join-command.sh /vagrant/.vagrant/master-init-complete-marker 2>&1 | head -5" 2>/dev/null || echo "  Cannot check files yet"
    fi
    sleep 3
done

if [ -z "$JOIN_COMMAND" ]; then
    echo "❌ Failed to retrieve join command after 540 seconds"
    echo ""
    echo "Diagnostics:"
    echo "  Checking if master initialization completed..."
    ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER \
        "ls -la /tmp/ /vagrant/.vagrant/ 2>&1 | grep -E '(worker-join|master-init)'" 2>/dev/null || echo "  Cannot access master"
    echo ""
    echo "  Checking master kubectl status..."
    ssh $SSH_OPTIONS -i /home/vagrant/.ssh/id_rsa vagrant@$PRIMARY_MASTER \
        "KUBECONFIG=/home/vagrant/.kube/config kubectl get nodes 2>&1 | head -10" 2>/dev/null || echo "  kubectl not accessible"
    echo ""
    exit 1
fi

# Extract API server endpoint from join command (format: IP:PORT)
API_ENDPOINT=$(echo "$JOIN_COMMAND" | awk '/kubeadm join/ {print $3}')
echo "API endpoint from join command: $API_ENDPOINT"

if [ -z "$API_ENDPOINT" ]; then
    echo "⚠️  Warning: Could not extract API endpoint from join command"
    echo "  Join command: $JOIN_COMMAND"
    echo "  Proceeding without API validation..."
else
    # Verify API server is accessible via the endpoint (load balancer VIP or master IP)
    echo "Verifying API server accessibility via https://$API_ENDPOINT..."
    for i in {1..60}; do
        # Try to connect to the API server
        if curl -k -s --connect-timeout 5 --max-time 10 "https://$API_ENDPOINT/livez" >/dev/null 2>&1; then
            echo "✅ API server is accessible via https://$API_ENDPOINT"
            break
        fi

        if [ $((i % 10)) -eq 0 ]; then
            echo "  Still waiting for API server (attempt $i/60)..."
        fi
        sleep 5
    done

    # Final verification before join
    echo "Final API server verification..."
    if ! curl -k -s --connect-timeout 5 --max-time 10 "https://$API_ENDPOINT/livez" >/dev/null 2>&1; then
        echo "⚠️  Warning: API server not responding via https://$API_ENDPOINT"
        echo "  Checking load balancer and API server status..."

        # Extract IP and port
        API_IP=$(echo "$API_ENDPOINT" | cut -d: -f1)
        API_PORT=$(echo "$API_ENDPOINT" | cut -d: -f2)

        echo "  Testing TCP connectivity to ${API_IP}:${API_PORT}..."
        if nc -zv -w5 "$API_IP" "$API_PORT" 2>&1 | grep -q "succeeded"; then
            echo "  ✓ TCP port is open, but API server may not be ready"
        else
            echo "  ✗ TCP port is not accessible"
        fi

        echo "  Proceeding with join attempt anyway (kubeadm will retry)..."
    fi
fi

# Execute join command with retries
echo "Executing worker join command..."
MAX_RETRIES=3
RETRY_DELAY=30

for attempt in $(seq 1 $MAX_RETRIES); do
    echo "Join attempt $attempt/$MAX_RETRIES..."

    if sudo bash -c "$JOIN_COMMAND"; then
        echo "✅ Worker successfully joined the cluster!"
        break
    else
        EXIT_CODE=$?

        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "⚠️  Join attempt $attempt failed (exit code: $EXIT_CODE)"

            # Clean up failed join artifacts before retrying
            echo "  Cleaning up failed join artifacts with kubeadm reset..."
            sudo kubeadm reset -f 2>/dev/null || true

            echo "  Waiting ${RETRY_DELAY} seconds before retry..."
            sleep $RETRY_DELAY

            # Increase delay for next retry
            RETRY_DELAY=$((RETRY_DELAY * 2))
        else
            echo "❌ Failed to join cluster after $MAX_RETRIES attempts"
            echo ""
            echo "Diagnostics:"
            echo "  1. Check API server status:"
            echo "     vagrant ssh $PRIMARY_MASTER -c 'kubectl get nodes'"
            echo ""
            echo "  2. Check API server logs:"
            echo "     vagrant ssh $PRIMARY_MASTER -c 'sudo journalctl -u kubelet -n 100'"
            echo ""
            echo "  3. Verify load balancer (if using HA):"
            echo "     Check if HAProxy/Keepalived are running"
            echo ""
            exit 1
        fi
    fi
done

echo "✅ Worker join complete!"
SHELL

# =====================================================================================================================================
# POST-DEPLOYMENT SCRIPT
# =====================================================================================================================================

POST_DEPLOY_SCRIPT = <<-'SHELL'
#!/bin/bash
PRIMARY_MASTER="$1"
METALLB_VERSION="$2"
METALLB_IP_RANGE="$3"
METRICS_SERVER_REPLICAS="$4"
HEADLAMP_VERSION="$5"
MASTER_IP="$6"
HELM_VERSION="$7"

echo "🎯 Running post-deployment tasks..."

# Wait for cluster to stabilize (longer for HA setups)
echo "Waiting for cluster to stabilize (60 seconds)..."
sleep 60

# SSH options
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ⚠️ Configure kubectl by copying from primary master with correct permissions
mkdir -p $HOME/.kube
echo "Fetching kubeconfig from primary master..."
for i in {1..10}; do
    if ssh $SSH_OPTIONS -i ~/.ssh/id_rsa \
        vagrant@$PRIMARY_MASTER "sudo cat /etc/kubernetes/admin.conf" > $HOME/.kube/config 2>/dev/null; then
        echo "✅ Kubeconfig retrieved successfully"
        break
    fi
    echo "  Retry $i/10: Failed to fetch kubeconfig"
    sleep 5
done

# Set correct ownership (run as vagrant user, so chown to vagrant)
chown $(id -u):$(id -g) $HOME/.kube/config
chmod 600 $HOME/.kube/config

# Export KUBECONFIG
export KUBECONFIG=$HOME/.kube/config
echo "✅ KUBECONFIG set to: $KUBECONFIG"

# ⚠️ Verify kubectl access and RBAC is working
echo "Verifying API server access and permissions..."
for i in {1..30}; do
    if KUBECONFIG=$HOME/.kube/config kubectl auth can-i get nodes --all-namespaces 2>/dev/null | grep -q "yes"; then
        echo "✅ API server is accessible and RBAC is working"
        break
    fi

    if [ $((i % 10)) -eq 0 ]; then
        echo "  Attempt $i/30: Waiting for API server to accept admin credentials..."
        # Show what error we're getting for debugging
        KUBECONFIG=$HOME/.kube/config kubectl get nodes 2>&1 | head -3 || true
    fi
    sleep 10
done

# Final verification - if this fails, we have a serious problem
if ! KUBECONFIG=$HOME/.kube/config kubectl get nodes >/dev/null 2>&1; then
    echo "❌ ERROR: Cannot access cluster after 300 seconds of waiting"
    echo "Diagnostics:"
    echo "  Kubeconfig file: $(ls -lh $HOME/.kube/config)"
    echo "  API server test: $(KUBECONFIG=$HOME/.kube/config kubectl cluster-info 2>&1 | head -5)"
    echo ""
    echo "⚠️  Skipping post-deployment tasks due to API access issues"
    echo "  You can manually deploy MetalLB and Metrics Server later"
    exit 1
fi

# Wait for all nodes to be ready
echo "Waiting for all nodes to be ready..."
for i in {1..60}; do
    READY_NODES=$(KUBECONFIG=$HOME/.kube/config kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
    TOTAL_NODES=$(KUBECONFIG=$HOME/.kube/config kubectl get nodes --no-headers 2>/dev/null | wc -l || echo 0)

    if [ "$READY_NODES" -eq "$TOTAL_NODES" ] && [ "$TOTAL_NODES" -gt 0 ]; then
        echo "✅ All $TOTAL_NODES nodes are ready"
        KUBECONFIG=$HOME/.kube/config kubectl get nodes
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for nodes: $READY_NODES/$TOTAL_NODES ready (check $i/60)..."
    sleep 5
done

# =====================================================================================================================================
# ⚠️ DEPLOY METALLB WITH --validate=false TO AVOID OPENAPI ERRORS
# =====================================================================================================================================

echo "Deploying MetalLB (version ${METALLB_VERSION})..."
MAX_RETRIES=3
for attempt in $(seq 1 $MAX_RETRIES); do
    echo "  MetalLB deployment attempt $attempt/$MAX_RETRIES..."
    if KUBECONFIG=$HOME/.kube/config kubectl apply --validate=false -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml 2>&1; then
        echo "✅ MetalLB deployed successfully"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "  ⚠️  Failed, retrying in 30 seconds..."
            sleep 30
        else
            echo "  ❌ MetalLB deployment failed after $MAX_RETRIES attempts"
        fi
    fi
done

# Wait for MetalLB namespace
echo "Waiting for metallb-system namespace..."
for i in {1..30}; do
    if KUBECONFIG=$HOME/.kube/config kubectl get namespace metallb-system >/dev/null 2>&1; then
        echo "✅ metallb-system namespace exists"
        break
    fi
    sleep 2
done

# ⚠️ Wait for MetalLB webhook pods to be ready before configuration
echo "Waiting for MetalLB controller deployment..."
for i in {1..60}; do
    if KUBECONFIG=$HOME/.kube/config kubectl get deployment controller -n metallb-system >/dev/null 2>&1; then
        KUBECONFIG=$HOME/.kube/config kubectl wait --for=condition=available --timeout=120s deployment/controller -n metallb-system 2>/dev/null && {
            echo "✅ MetalLB controller is ready"
            break
        }
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for controller deployment (attempt $i/60)..."
    sleep 2
done

echo "Waiting for MetalLB speaker daemonset..."
for i in {1..60}; do
    SPEAKER_DESIRED=$(KUBECONFIG=$HOME/.kube/config kubectl get daemonset speaker -n metallb-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    SPEAKER_READY=$(KUBECONFIG=$HOME/.kube/config kubectl get daemonset speaker -n metallb-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

    if [ "$SPEAKER_DESIRED" -gt 0 ] && [ "$SPEAKER_READY" -eq "$SPEAKER_DESIRED" ]; then
        echo "✅ MetalLB speaker is ready ($SPEAKER_READY/$SPEAKER_DESIRED pods)"
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for speaker pods: $SPEAKER_READY/$SPEAKER_DESIRED ready (attempt $i/60)..."
    sleep 2
done

# ⚠️ CRITICAL: Wait for webhook service endpoints to be available
echo "Waiting for MetalLB webhook service to be ready..."
for i in {1..60}; do
    # Check if webhook service has endpoints
    WEBHOOK_ENDPOINTS=$(KUBECONFIG=$HOME/.kube/config kubectl get endpoints metallb-webhook-service -n metallb-system -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")

    if [ -n "$WEBHOOK_ENDPOINTS" ]; then
        echo "✅ MetalLB webhook service is ready (endpoint: $WEBHOOK_ENDPOINTS)"
        # Additional safety: wait 10 more seconds for webhook to fully stabilize
        echo "  Waiting 10s for webhook to stabilize..."
        sleep 10
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for webhook service endpoints (attempt $i/60)..."
    sleep 3
done

# ⚠️ Configure MetalLB IP pool with --validate=false (with retries)
echo "Configuring MetalLB with IP range: ${METALLB_IP_RANGE}"
for attempt in $(seq 1 $MAX_RETRIES); do
    echo "  MetalLB configuration attempt $attempt/$MAX_RETRIES..."
    if cat <<EOF | KUBECONFIG=$HOME/.kube/config kubectl apply --validate=false -f - 2>&1
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
    then
        echo "✅ MetalLB configured successfully"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "  ⚠️  Failed, retrying in 30 seconds..."
            sleep 30
        else
            echo "  ❌ MetalLB configuration failed after $MAX_RETRIES attempts"
        fi
    fi
done

# =====================================================================================================================================
# ⚠️ DEPLOY METRICS SERVER WITH --validate=false & PATCH METRICS SERVER FOR INSECURE TLS (REQUIRED FOR SELF-SIGNED CERTS)
# =====================================================================================================================================

echo "Deploying Metrics Server..."
for attempt in $(seq 1 $MAX_RETRIES); do
    echo "  Metrics Server deployment attempt $attempt/$MAX_RETRIES..."
    if KUBECONFIG=$HOME/.kube/config kubectl apply --validate=false -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>&1; then
        echo "✅ Metrics Server deployed successfully"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "  ⚠️  Failed, retrying in 30 seconds..."
            sleep 30
        else
            echo "  ❌ Metrics Server deployment failed after $MAX_RETRIES attempts"
        fi
    fi
done

# Wait for Metrics Server deployment to exist
echo "Waiting for Metrics Server deployment..."
for i in {1..30}; do
    if KUBECONFIG=$HOME/.kube/config kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
        echo "✅ Metrics Server deployment exists"
        break
    fi
    sleep 2
done

# Patch Metrics Server for insecure TLS
echo "Patching Metrics Server for insecure TLS..."
for attempt in $(seq 1 $MAX_RETRIES); do
    if KUBECONFIG=$HOME/.kube/config kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' 2>&1; then
        echo "✅ Metrics Server patched successfully"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "  ⚠️  Patch failed, retrying in 10 seconds..."
            sleep 10
        else
            echo "  ⚠️  Patch failed (metrics-server may already be patched)"
        fi
    fi
done

# Scale Metrics Server replicas
echo "Scaling Metrics Server to ${METRICS_SERVER_REPLICAS} replicas..."
for attempt in $(seq 1 $MAX_RETRIES); do
    if KUBECONFIG=$HOME/.kube/config kubectl scale deployment metrics-server -n kube-system --replicas=${METRICS_SERVER_REPLICAS} 2>&1; then
        echo "✅ Metrics Server scaled to ${METRICS_SERVER_REPLICAS} replicas"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "  ⚠️  Scaling failed, retrying in 10 seconds..."
            sleep 10
        else
            echo "  ⚠️  Scaling failed"
        fi
    fi
done

# Wait for Metrics Server pods to be ready
echo "Waiting for Metrics Server pods to be ready..."
for i in {1..60}; do
    READY_PODS=$(KUBECONFIG=$HOME/.kube/config kubectl get pods -n kube-system -l k8s-app=metrics-server 2>/dev/null | grep "Running" | grep "1/1" | wc -l || echo "0")
    
    if [ "$READY_PODS" -eq "$METRICS_SERVER_REPLICAS" ]; then
        echo "✅ All ${METRICS_SERVER_REPLICAS} Metrics Server pods are ready"
        break
    fi
    
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Waiting for pods: $READY_PODS/${METRICS_SERVER_REPLICAS} ready (check $i/60)..."
    fi
    sleep 5
done

# =====================================================================================================================================
# 🖥️ INSTALL HELM
# =====================================================================================================================================

echo ""
echo "================================================================================================"
echo "INSTALLING HELM (version ${HELM_VERSION})"
echo "================================================================================================"

# Check if Helm is already installed and at the correct version
if command -v helm &>/dev/null; then
    INSTALLED_HELM=$(helm version --short 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    if [ "$INSTALLED_HELM" = "$HELM_VERSION" ]; then
        echo "✅ Helm v${HELM_VERSION} is already installed"
    else
        echo "⚠️  Helm v${INSTALLED_HELM} found but v${HELM_VERSION} required — reinstalling..."
        sudo rm -f /usr/local/bin/helm
    fi
fi

if ! command -v helm &>/dev/null; then
    echo "Downloading Helm v${HELM_VERSION}..."
    HELM_ARCH="amd64"
    HELM_OS="linux"
    HELM_TAR="helm-v${HELM_VERSION}-${HELM_OS}-${HELM_ARCH}.tar.gz"
    HELM_URL="https://get.helm.sh/${HELM_TAR}"

    for attempt in $(seq 1 $MAX_RETRIES); do
        echo "  Download attempt $attempt/$MAX_RETRIES..."
        if curl -fsSL "$HELM_URL" -o /tmp/${HELM_TAR}; then
            echo "✅ Helm archive downloaded"
            break
        else
            if [ $attempt -lt $MAX_RETRIES ]; then
                echo "  ⚠️  Download failed, retrying in 10 seconds..."
                sleep 10
            else
                echo "  ❌ Failed to download Helm after $MAX_RETRIES attempts"
                exit 1
            fi
        fi
    done

    echo "Installing Helm binary..."
    tar -zxf /tmp/${HELM_TAR} -C /tmp
    sudo mv /tmp/${HELM_OS}-${HELM_ARCH}/helm /usr/local/bin/helm
    sudo chmod +x /usr/local/bin/helm
    rm -rf /tmp/${HELM_TAR} /tmp/${HELM_OS}-${HELM_ARCH}

    # Verify installation
    if helm version --short &>/dev/null; then
        echo "✅ Helm installed: $(helm version --short)"
    else
        echo "❌ Helm installation failed"
        exit 1
    fi
fi

# =====================================================================================================================================
# 🖥️ DEPLOY HEADLAMP VIA HELM (KUBERNETES DASHBOARD)
# =====================================================================================================================================

echo ""
echo "================================================================================================"
echo "DEPLOYING HEADLAMP KUBERNETES UI via Helm (chart v${HEADLAMP_VERSION})"
echo "================================================================================================"

# Add the Headlamp Helm repo
echo "Adding Headlamp Helm repository..."
for attempt in $(seq 1 $MAX_RETRIES); do
    if helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ 2>&1; then
        echo "✅ Headlamp Helm repo added"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "  ⚠️  Failed, retrying in 10 seconds..."
            sleep 10
        else
            echo "  ❌ Failed to add Headlamp Helm repo after $MAX_RETRIES attempts"
            exit 1
        fi
    fi
done

echo "Updating Helm repositories..."
helm repo update 2>&1

# Create namespace and RBAC first so the token Secret populates before we need it
KUBECONFIG=$HOME/.kube/config kubectl create namespace headlamp 2>/dev/null || true

echo "Creating Headlamp admin ServiceAccount, token Secret, and ClusterRoleBinding..."
cat <<EOF | KUBECONFIG=$HOME/.kube/config kubectl apply --validate=false -f - 2>&1
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: headlamp
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-user-token
  namespace: headlamp
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: headlamp
EOF
echo "✅ Headlamp admin ServiceAccount and long-lived token Secret created"

# Install Headlamp via Helm
# service.type=NodePort exposes it directly on the master node — no ingress required
echo "Installing Headlamp Helm chart v${HEADLAMP_VERSION}..."
for attempt in $(seq 1 $MAX_RETRIES); do
    if KUBECONFIG=$HOME/.kube/config helm upgrade --install headlamp \
        headlamp/headlamp \
        --version "${HEADLAMP_VERSION}" \
        --namespace headlamp \
        --set service.type=NodePort \
        --set replicaCount=1 \
        --wait \
        --timeout 5m 2>&1; then
        echo "✅ Headlamp installed successfully"
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "  ⚠️  Helm install failed, retrying in 30 seconds..."
            KUBECONFIG=$HOME/.kube/config helm uninstall headlamp -n headlamp 2>/dev/null || true
            sleep 30
        else
            echo "  ❌ Headlamp Helm install failed after $MAX_RETRIES attempts"
            KUBECONFIG=$HOME/.kube/config kubectl get pods -n headlamp 2>&1 || true
        fi
    fi
done

# Wait for Headlamp pod to be Running
echo "Waiting for Headlamp pod to become ready..."
for i in {1..60}; do
    READY=$(KUBECONFIG=$HOME/.kube/config kubectl get pods -n headlamp \
        --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$READY" -ge 1 ]; then
        echo "✅ Headlamp is running"
        KUBECONFIG=$HOME/.kube/config kubectl get pods -n headlamp
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting for Headlamp pod (check $i/60)..."
    sleep 5
done

# Get the NodePort
echo "Retrieving Headlamp NodePort..."
HEADLAMP_PORT=""
for i in {1..20}; do
    HEADLAMP_PORT=$(KUBECONFIG=$HOME/.kube/config kubectl get svc headlamp \
        -n headlamp \
        -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    if [ -n "$HEADLAMP_PORT" ] && [ "$HEADLAMP_PORT" != "0" ]; then
        echo "✅ Headlamp NodePort: ${HEADLAMP_PORT}"
        break
    fi
    [ $((i % 5)) -eq 0 ] && echo "  Waiting for NodePort (attempt $i/20)..."
    sleep 3
done
HEADLAMP_PORT="${HEADLAMP_PORT:-UNKNOWN}"

# Retrieve the long-lived token from the Secret
echo "Retrieving Headlamp login token..."
HEADLAMP_TOKEN=""
for i in {1..20}; do
    HEADLAMP_TOKEN=$(KUBECONFIG=$HOME/.kube/config kubectl get secret admin-user-token \
        -n headlamp \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")
    if [ -n "$HEADLAMP_TOKEN" ]; then
        echo "✅ Headlamp token retrieved"
        break
    fi
    [ $((i % 5)) -eq 0 ] && echo "  Waiting for token Secret to populate (attempt $i/20)..."
    sleep 3
done
HEADLAMP_TOKEN="${HEADLAMP_TOKEN:-TOKEN_NOT_YET_AVAILABLE}"

# =====================================================================================================================================
# 📋 FINAL SUMMARY - POST DEPLOYMENT STATUS
# =====================================================================================================================================

echo ""
echo "================================================================================"
echo "✅ POST-DEPLOYMENT COMPLETE"
echo "================================================================================"
echo ""
echo "📊 Node status:"
KUBECONFIG=$HOME/.kube/config kubectl get nodes 2>&1 || echo "  ⚠️  Could not retrieve nodes"
echo ""
echo "📦 System pods:"
KUBECONFIG=$HOME/.kube/config kubectl get pods -n kube-system 2>&1 | head -20 || echo "  ⚠️  Could not retrieve pods"
echo ""
echo "🌐 MetalLB status:"
KUBECONFIG=$HOME/.kube/config kubectl get pods -n metallb-system 2>&1 || echo "  ⚠️  MetalLB not yet ready"
echo ""
echo "🎯 Calico status:"
KUBECONFIG=$HOME/.kube/config kubectl get pods -n calico-system 2>&1 || echo "  ⚠️  Calico not yet ready"
echo ""
echo "⚙️  Helm releases:"
KUBECONFIG=$HOME/.kube/config helm list -A 2>&1 || echo "  ⚠️  Could not list Helm releases"
echo ""
echo "================================================================================"
echo "🖥️  HEADLAMP KUBERNETES UI  (Helm chart v${HEADLAMP_VERSION})"
echo "================================================================================"
echo ""
echo "  🌐 URL:   http://${MASTER_IP}:${HEADLAMP_PORT}"
echo ""
echo "  📋 On the Headlamp login screen, paste the token below:"
echo ""
echo "  🔑 TOKEN:"
echo "  ────────────────────────────────────────────────────────────"
echo "  ${HEADLAMP_TOKEN}"
echo "  ────────────────────────────────────────────────────────────"
echo ""
echo "  💡 To retrieve the token anytime:"
echo "     vagrant ssh $(hostname) -c \\"
echo "       'kubectl get secret admin-user-token -n headlamp -o jsonpath={.data.token} | base64 --decode && echo'"
echo ""
echo "  💡 To get the NodePort anytime:"
echo "     vagrant ssh $(hostname) -c 'kubectl get svc headlamp -n headlamp'"
echo ""
echo "  💡 Helm release status:"
echo "     vagrant ssh $(hostname) -c 'helm list -n headlamp'"
echo ""
echo "  ℹ️  NOTE: kubernetes-retired/dashboard was archived Jan 21 2026."
echo "  Headlamp (https://github.com/kubernetes-sigs/headlamp) is the official successor."
echo ""
echo "================================================================================"
SHELL

# =====================================================================================================================================
# HAPROXY CONFIGURATION TEMPLATE
# =====================================================================================================================================

HAPROXY_CONFIG = <<-'HAPROXY'
global
    log /dev/log local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http

frontend kubernetes-api
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-masters

backend kubernetes-masters
    mode tcp
    balance roundrobin
    option tcp-check
NODES_TO_INSERT

listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 5s
    stats show-legends
    stats show-node
    stats admin if TRUE
    stats auth admin:yourpassword
HAPROXY

# Keepalived Configuration Template
KEEPALIVED_CONFIG = <<-'KEEPALIVED'
vrrp_instance VI_1 {
    state MASTER
    interface INTERFACE_TO_INSERT
    virtual_router_id 51
    priority PRIORITY_TO_INSERT
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass CLUSTER_AUTH_PASS
    }
    virtual_ipaddress {
        VIP_TO_INSERT
    }
}
KEEPALIVED

# =====================================================================================================================================
# LOAD BALANCER SETUP
# =====================================================================================================================================

LB_SETUP_SCRIPT = <<-'SHELL'
#!/bin/bash
HAPROXY_CFG="$1"
KEEPALIVED_CFG="$2"
LB_IP="$3"

echo "⚖️  Setting up Load Balancer with HAProxy + Keepalived..."

# Auto-detect the private network interface by IP
echo "Detecting private network interface..."
PRIVATE_IFACE=""
for i in {1..30}; do
    # Get all non-loopback interfaces
    ALL_IFACES=$(ip link show | grep -E "^[0-9]+: " | awk -F': ' '{print $2}' | grep -v "lo" | grep -v "@")

    for iface in $ALL_IFACES; do
        # Check if this interface has the LB IP
        IFACE_IP=$(ip addr show $iface 2>/dev/null | grep "inet " | grep -v "inet6" | awk '{print $2}' | cut -d/ -f1)

        if [ "$IFACE_IP" = "$LB_IP" ]; then
            PRIVATE_IFACE="$iface"
            echo "  ✓ Found interface $PRIVATE_IFACE with IP $LB_IP"
            break 2
        fi
    done

    if [ $i -eq 30 ]; then
        echo "  ⚠️  Could not find interface with IP $LB_IP"
        echo "  Available interfaces and IPs:"
        ip addr show | grep -E "^[0-9]+: |inet " | grep -v "inet6"

        # Fallback: use first interface with 192.168 IP
        for iface in $ALL_IFACES; do
            IFACE_IP=$(ip addr show $iface 2>/dev/null | grep "inet " | grep -v "inet6" | awk '{print $2}' | cut -d/ -f1)
            if [[ "$IFACE_IP" =~ ^192\.168\. ]]; then
                PRIVATE_IFACE="$iface"
                echo "  ✓ Using interface $PRIVATE_IFACE (detected from subnet match)"
                break
            fi
        done

        if [ -z "$PRIVATE_IFACE" ]; then
            echo "  ✗ ERROR: Could not auto-detect private network interface"
            exit 1
        fi
        break
    fi

    sleep 1
done

echo "  Using interface: $PRIVATE_IFACE"

# Install HAProxy and Keepalived
sudo apt-get update
sudo apt-get install -y haproxy keepalived

# Configure HAProxy
echo "$HAPROXY_CFG" | sudo tee /etc/haproxy/haproxy.cfg > /dev/null

# Configure Keepalived with detected interface
echo "$KEEPALIVED_CFG" | sed "s/INTERFACE_TO_INSERT/$PRIVATE_IFACE/g" | sudo tee /etc/keepalived/keepalived.conf > /dev/null

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.ip_nonlocal_bind=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Start services
sudo systemctl enable haproxy keepalived
sudo systemctl restart haproxy keepalived

echo "✅ Load balancer setup complete"
echo "  HAProxy status: $(sudo systemctl is-active haproxy)"
echo "  Keepalived status: $(sudo systemctl is-active keepalived)"
echo ""
echo "📊 HAProxy Stats Page:"
LB_SUBNET=$(echo $LB_IP | cut -d. -f1-3)
echo "  http://${LB_IP}:8404/stats"
SHELL

# =====================================================================================================================================
# 🧮 HELPER FUNCTIONS
# =====================================================================================================================================

# Generates a flat list of node definitions based on the declarative map
def generate_node_list(declaration, ip_offsets, lb_cpus, lb_memory)
  all_nodes = {}
  hosts_config_list = []
  cluster_last_nodes = {}
  cluster_primary_masters = {}
  all_vm_names = []

  declaration.each do |cluster_name, config|
    base_ip = config[:base_subnet]
    single_master = config[:master_count] == 1
    single_worker = config[:worker_count] == 1

    # ⚠️ Only create Load Balancer if master_count > 1
    if config[:master_count] > 1
      lb_name = "#{cluster_name}-lb"
      lb_ip = "#{base_ip}.#{ip_offsets['lb']}"
      hosts_config_list << "#{lb_ip}\t#{lb_name}"
      all_vm_names << lb_name

      all_nodes[lb_name] = {
        role: 'load-balancer', base_ip: base_ip, index: 1, ip: lb_ip,
        cpus: lb_cpus, memory: lb_memory,
        metallb_ip_range: config[:metallb_ip_range], master_count: config[:master_count],
        cluster_name: cluster_name
      }
    end

    # Control Plane nodes
    (1..config[:master_count]).each do |i|
      master_name = single_master ? "#{cluster_name}-master" : "#{cluster_name}-master#{i}"
      master_ip = "#{base_ip}.#{ip_offsets['master'][i]}"
      hosts_config_list << "#{master_ip}\t#{master_name}"
      all_vm_names << master_name

      all_nodes[master_name] = {
        role: 'control-plane', base_ip: base_ip, index: i, ip: master_ip,
        primary_master: (i == 1),
        cpus: config[:master_cpus], memory: config[:master_memory],
        metallb_ip_range: config[:metallb_ip_range],
        master_count: config[:master_count],
        cluster_name: cluster_name,
        context_name: config[:context_name]
      }

      # Track primary master for each cluster
      if i == 1
        cluster_primary_masters[cluster_name] = master_name
      end
    end

    # Worker nodes
    (1..config[:worker_count]).each do |i|
      worker_name = single_worker ? "#{cluster_name}-worker" : "#{cluster_name}-worker#{i}"
      worker_ip = "#{base_ip}.#{ip_offsets['worker'][i]}"
      hosts_config_list << "#{worker_ip}\t#{worker_name}"
      all_vm_names << worker_name

      all_nodes[worker_name] = {
        role: 'worker', base_ip: base_ip, index: i, ip: worker_ip,
        cpus: config[:worker_cpus], memory: config[:worker_memory],
        metallb_ip_range: config[:metallb_ip_range],
        master_count: config[:master_count],
        cluster_name: cluster_name,
        context_name: config[:context_name]
      }

      # Track the last worker node of each cluster
      cluster_last_nodes[cluster_name] = worker_name
    end
  end

  return all_nodes, hosts_config_list.join("\n"), cluster_last_nodes, cluster_primary_masters, all_vm_names
end

# Generates the HAProxy backend list for a specific cluster
def get_cluster_master_nodes(cluster_name, master_count, base_ip, ip_offsets)

  nodes_list = []
  single_master = master_count == 1
  (1..master_count).each do |i|
    ip = "#{base_ip}.#{ip_offsets['master'][i]}"
    node_name_for_haproxy = single_master ?
    "#{cluster_name}-master" : "#{cluster_name}-master#{i}"
    nodes_list << "    server #{node_name_for_haproxy} #{ip}:6443 check"
  end
  return nodes_list.join("\n")
end

ALL_NODES_FLAT, HOSTS_CONTENT, CLUSTER_LAST_NODES, CLUSTER_PRIMARY_MASTERS, ALL_VM_NAMES = generate_node_list(ALL_CLUSTERS_DECLARATION, IP_OFFSETS, LB_CPUS, LB_MEMORY)

# =====================================================================================================================================
# 🚀 VAGRANT CONFIGURATION/SETUP AND PROVISIONING
# =====================================================================================================================================

Vagrant.configure("2") do |config|
  # =====================================================================================================================================
  # VIRTUALBOX PROVIDER CONFIGURATION - OPTIMIZED FOR MINIMAL UAC PROMPTS
  # -------------------------------------------------------------------------------------------------------------------------------------
  # The following VirtualBox customizations help reduce Windows UAC prompts by:
  #   • Configuring DNS settings to avoid network adapter reconfigurations
  #   • Enabling NAT DNS proxy to handle DNS resolution within VirtualBox
  #   • Setting proper network adapter modes to minimize Windows security warnings
  # These settings work across PowerShell, CMD, GitBash, and VS Code integrated terminals
  # =====================================================================================================================================
  config.vm.provider "virtualbox" do |vb|
    # Disable GUI by default for headless operation (set from false to true to see console)
    vb.gui = false
    
    # VirtualBox customizations to minimize UAC prompts and network warnings
    # These settings help VirtualBox handle networking without triggering Windows security prompts
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
    vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
    vb.customize ["modifyvm", :id, "--nictype2", "virtio"]
  end

  # Set boot timeout for reliability when provisioning multiple VMs simultaneously
  config.vm.boot_timeout = 600

  # Ensure .vagrant directory exists for storing SSH keys
  require 'fileutils'
  FileUtils.mkdir_p('.vagrant/ssh-keys')

  config.vm.box = BOX_IMAGE
  config.vm.box_version = BOX_VERSION
  config.vm.box_check_update = BOX_CHECK_UPDATES

  config.ssh.insert_key = false
  config.ssh.private_key_path = VAGRANT_DEFAULT_KEY

  ALL_NODE_HOSTNAMES = ALL_NODES_FLAT.keys.map(&:to_s).join(" ")

  first_cluster_name = ALL_CLUSTERS_DECLARATION.keys.first
  master_count = ALL_CLUSTERS_DECLARATION[first_cluster_name][:master_count]
  primary_master_suffix = (master_count == 1) ? "" : "1"
  FIRST_CLUSTER_PRIMARY_MASTER = first_cluster_name + "-master" + primary_master_suffix

  # =====================================================================================================================================
  # PRE-FLIGHT CHECK - ADMINISTRATOR PRIVILEGES DETECTION (CROSS-TERMINAL SUPPORT)
  # -------------------------------------------------------------------------------------------------------------------------------------
  # This trigger checks for administrator privileges across all Windows terminal types:
  #   • PowerShell (native Windows terminal)
  #   • Command Prompt / CMD (classic Windows shell)
  #   • GitBash (MINGW64/MSYS2 Unix-like environment)
  #   • VS Code Integrated Terminal (inherits VS Code's privileges)
  #
  # VirtualBox requires admin rights to create network adapters without UAC prompts.
  # The check uses 'net session' command which works universally across all shells.
  # =====================================================================================================================================
  config.trigger.before :up, type: :command do |trigger|
    trigger.name = "Check Administrator Privileges"
    trigger.ruby do |env, machine|
      # Only check on Windows systems
      if Vagrant::Util::Platform.windows?
        puts "\n" + "="*80
        puts "CHECKING WINDOWS ADMINISTRATOR PRIVILEGES"
        puts "="*80
        
        # Universal admin check using 'net session' command
        # This command works in PowerShell, CMD, GitBash, and VS Code terminals
        # It returns errorlevel 0 if admin, non-zero otherwise
        is_admin = system('net session >NUL 2>&1')
        
        # Detect current shell environment for user guidance
        shell_type = "terminal"
        if ENV['SHELL'] && ENV['SHELL'].include?('bash')
          shell_type = "GitBash"
        elsif ENV['PSModulePath']
          shell_type = "PowerShell"
        elsif ENV['PROMPT']
          shell_type = "Command Prompt"
        end
        
        # Check if running in VS Code
        in_vscode = ENV['TERM_PROGRAM'] == 'vscode' || ENV['VSCODE_PID']
        
        if !is_admin
          puts ""
          puts "⚠️  WARNING: Not running with Administrator privileges!"
          puts ""
          puts "VirtualBox requires Administrator rights to create network adapters."
          puts "You may see UAC prompts asking for permission."
          puts ""
          
          if in_vscode
            puts "🔷 DETECTED: VS Code Integrated Terminal"
            puts ""
            puts "To avoid UAC prompts in VS Code:"
            puts "  1. Close VS Code completely"
            puts "  2. Right-click on 'Visual Studio Code' shortcut"
            puts "  3. Select 'Run as Administrator'"
            puts "  4. Open your project folder"
            puts "  5. Open integrated terminal (Ctrl+`)"
            puts "  6. Run: vagrant up"
          elsif shell_type == "GitBash"
            puts "🔷 DETECTED: GitBash Terminal"
            puts ""
            puts "To avoid UAC prompts in GitBash:"
            puts "  1. Close this GitBash window"
            puts "  2. Right-click on 'Git Bash' shortcut"
            puts "  3. Select 'Run as Administrator'"
            puts "  4. Navigate to: cd /c#{Dir.pwd.gsub(':', '').gsub('\\', '/')}"
            puts "  5. Run: vagrant up"
          elsif shell_type == "PowerShell"
            puts "🔷 DETECTED: PowerShell Terminal"
            puts ""
            puts "To avoid UAC prompts in PowerShell:"
            puts "  1. Close this PowerShell window"
            puts "  2. Right-click on PowerShell shortcut"
            puts "  3. Select 'Run as Administrator'"
            puts "  4. Navigate to this directory"
            puts "  5. Run: vagrant up"
          else
            puts "🔷 DETECTED: Command Prompt / CMD"
            puts ""
            puts "To avoid UAC prompts:"
            puts "  1. Close this terminal"
            puts "  2. Right-click on Command Prompt shortcut"
            puts "  3. Select 'Run as Administrator'"
            puts "  4. Navigate to this directory"
            puts "  5. Run: vagrant up"
          end
          
          puts ""
          puts "Alternative: Click 'Yes' on UAC prompts when they appear."
          puts "The setting will be remembered for future runs."
          puts ""
          puts "Press Ctrl+C NOW to cancel and restart as Administrator,"
          puts "or press Enter to continue (you'll need to approve UAC prompts)..."
          puts "="*80
          
          # Wait for user input (10 seconds timeout)
          begin
            require 'timeout'
            Timeout::timeout(10) do
              STDIN.gets
            end
          rescue Timeout::Error
            puts "\nContinuing with provisioning..."
          end
        else
          puts "✅ Running with Administrator privileges (#{shell_type})"
          puts "="*80
        end
      end
    end
  end

  # Provision all nodes
  ALL_NODES_FLAT.each do |node_name, node_data|
    node_role = node_data[:role]
    node_base_ip = node_data[:base_ip]
    node_index = node_data[:index]
    cluster_name = node_data[:cluster_name]
    master_count_for_cluster = node_data[:master_count]
    context_name = node_data[:context_name] || cluster_name

    cpus   = node_data[:cpus]
    memory = node_data[:memory]

    if node_role == 'load-balancer'
      offset = IP_OFFSETS['lb']
      master_count = node_data[:master_count]
      lb_priority = (cluster_name == ALL_CLUSTERS_DECLARATION.keys.first) ? 101 : 100

      haproxy_cfg = HAPROXY_CONFIG.sub('NODES_TO_INSERT', get_cluster_master_nodes(cluster_name, master_count, node_base_ip, IP_OFFSETS))
      keepalived_cfg = KEEPALIVED_CONFIG.sub('PRIORITY_TO_INSERT', lb_priority.to_s)
                                        .sub('VIP_TO_INSERT', "#{node_base_ip}.#{IP_OFFSETS['lb_vip']}")
                                        .sub('CLUSTER_AUTH_PASS', "#{cluster_name}pass")
    elsif node_role == 'control-plane'
      offset = IP_OFFSETS['master'][node_index]
    elsif node_role == 'worker'
      offset = IP_OFFSETS['worker'][node_index]
    else
      raise "Unknown node role: #{node_role}"
    end

    node_ip = "#{node_base_ip}.#{offset}"

    if node_role == 'control-plane'
      if master_count_for_cluster > 1
        k8s_api_endpoint = "#{node_base_ip}.#{IP_OFFSETS['lb_vip']}:6443"
      else
        k8s_api_endpoint = "#{node_base_ip}.#{offset}:6443"
      end
    end

    cluster_primary_master = (master_count_for_cluster == 1) ? "#{cluster_name}-master" : "#{cluster_name}-master1"

    # Derive the primary master IP for this cluster (used for Dashboard URL)
    cluster_primary_master_ip = "#{node_base_ip}.#{IP_OFFSETS['master'][1]}"

    config.vm.define node_name do |node|
      node.vm.hostname = node_name
      node.vm.network "private_network", ip: node_ip
      node.vm.network "private_network", virtualbox__intnet: INTER_CLUSTER_NETWORK, auto_config: false

      node.vm.provider "virtualbox" do |v|
        v.name = "#{node_name}"
        v.cpus   = cpus
        v.memory = memory
        v.customize ["modifyvm", :id, "--groups", "/Main-Multi-Cluster"]
        
        # Additional VirtualBox customizations per-VM to reduce UAC prompts
        # These ensure each VM's network adapters are configured optimally
        v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
        v.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
      end

      # ====================== BASE SETUP FOR ALL NODES ======================
      node.vm.provision "shell", run: "always", inline: HOSTS_SETUP_SCRIPT, args: [HOSTS_CONTENT]
      node.vm.provision "ssh-setup", type: "shell", privileged: false, inline: SSH_SETUP_SCRIPT

      if node_role == 'load-balancer'
        # ⚠️ Load balancers now get base system setup before HAProxy/Keepalived
        node.vm.provision "shell", inline: LB_BASE_SETUP_SCRIPT, args: [node_ip, node_name]
        node.vm.provision "shell", inline: LB_SETUP_SCRIPT, args: [haproxy_cfg, keepalived_cfg, node_ip]
      elsif node_role != 'load-balancer'
        node.vm.provision "shell", inline: BASE_SETUP_SCRIPT, args: [CRI_DOCKERD_VERSION, K8S_VERSION, node_ip, node_name]
      end

      # ================== KUBERNETES-SPECIFIC PROVISIONING ==================
      if node_data[:primary_master]
        node.vm.provision "shell", privileged: false, inline: MASTER_INIT_SCRIPT,
          args: [cluster_name, k8s_api_endpoint, CALICO_VERSION, K8S_VERSION, node_ip, context_name]

        # Validate Calico installation
        node.vm.provision "shell", privileged: false, inline: CALICO_VALIDATION_SCRIPT,
          args: [cluster_name, CALICO_VERSION]
      elsif node_role == 'control-plane'
        node.vm.provision "shell", privileged: false, inline: MASTER_JOIN_SCRIPT,
          args: [cluster_primary_master, node_ip]
      elsif node_role == 'worker'
        node.vm.provision "shell", privileged: false, inline: WORKER_JOIN_SCRIPT,
          args: [cluster_primary_master]

        # Deploy MetalLB + Metrics Server + Dashboard on the LAST WORKER of each cluster
        if node_name == CLUSTER_LAST_NODES[cluster_name]
          node.vm.provision "shell", privileged: false, inline: POST_DEPLOY_SCRIPT,
            args: [
              cluster_primary_master,
              METALLB_VERSION,
              node_data[:metallb_ip_range],
              METRICS_SERVER_REPLICAS,
              HEADLAMP_VERSION,
              cluster_primary_master_ip,
              HELM_VERSION
            ]
        end
      end
    end
  end

  # =====================================================================================================================================
  # POST-UP TRIGGER - SSH Key Distribution
  # =====================================================================================================================================

  config.trigger.after :up do |trigger|
    trigger.name = "SSH Key Distribution"
    trigger.only_on = ALL_VM_NAMES.last
    trigger.info = "Distributing SSH keys across all VMs..."
    trigger.ruby do |env, machine|
      puts "\n" + "="*80
      puts "WAITING FOR VMS TO STABILIZE"
      puts "="*80
      30.times do |i|
        print "\rTime remaining: #{30 - i} seconds "
        $stdout.flush
        sleep 1
      end

      puts "\n\n" + "="*80
      puts "DISTRIBUTING SSH KEYS"
      puts "="*80
      puts ""

      # Get all VM names
      vms = ALL_VM_NAMES
      puts "Distributing SSH keys to #{vms.length} VMs..."
      puts ""

      success_count = 0
      failed_vms = []

      vms.each do |vm_name|
        print "  Configuring #{vm_name}... "

        # Enhanced SSH key distribution script
        ssh_script = <<-'SSHSCRIPT'
#!/bin/bash
SSH_DIR="/home/vagrant/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
SSH_KEYS_DIR="/vagrant/.vagrant/ssh-keys"

# Ensure SSH directory exists with correct permissions
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown vagrant:vagrant "$SSH_DIR"

# Backup original authorized_keys if not already backed up
if [ -f "$AUTH_KEYS" ] && [ ! -f "$AUTH_KEYS.original" ]; then
  cp "$AUTH_KEYS" "$AUTH_KEYS.original"
fi

# Start with original or create new
if [ -f "$AUTH_KEYS.original" ]; then
  cp "$AUTH_KEYS.original" "$AUTH_KEYS"
else
  touch "$AUTH_KEYS"
fi

# Add all public keys from shared directory
if ls "$SSH_KEYS_DIR"/*.pub 1> /dev/null 2>&1; then
  for key_file in "$SSH_KEYS_DIR"/*.pub; do
    if [ -f "$key_file" ]; then
      # Add key if not already present
      key_content=$(cat "$key_file")
      if ! grep -qF "$key_content" "$AUTH_KEYS" 2>/dev/null; then
        cat "$key_file" >> "$AUTH_KEYS"
      fi
    fi
  done
fi

# Set correct permissions
chmod 600 "$AUTH_KEYS"
chown vagrant:vagrant "$AUTH_KEYS"

# Clear and regenerate known_hosts to prevent conflicts
rm -f "$SSH_DIR/known_hosts"
touch "$SSH_DIR/known_hosts"
chmod 600 "$SSH_DIR/known_hosts"
chown vagrant:vagrant "$SSH_DIR/known_hosts"

# Ensure SSH service is configured correctly
if ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
  echo "PubkeyAuthentication yes" | sudo tee -a /etc/ssh/sshd_config
fi

# Restart SSH service
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null

# Test that we have the private key
if [ -f "$SSH_DIR/id_rsa" ]; then
  chmod 600 "$SSH_DIR/id_rsa"
  chown vagrant:vagrant "$SSH_DIR/id_rsa"
fi
SSHSCRIPT

        # Get the Vagrant project directory
        vagrant_dir = env.root_path
        script_dir = File.join(vagrant_dir, ".vagrant")

        # Ensure .vagrant directory exists
        FileUtils.mkdir_p(script_dir)

        # Write script to .vagrant directory
        script_path = File.join(script_dir, "ssh-setup-#{vm_name}.sh")

        begin
          # Write script with Unix LF line endings (not Windows CRLF)
          File.open(script_path, 'wb') do |f|
            f.write(ssh_script.gsub(/\r\n/, "\n"))
          end

          result = system("vagrant ssh #{vm_name} -c 'bash /vagrant/.vagrant/ssh-setup-#{vm_name}.sh' 2>&1")
          File.delete(script_path) if File.exist?(script_path)

          if result
            puts "✓"
            success_count += 1
          else
            puts "✗"
            failed_vms << vm_name
          end
        rescue => e
          puts "✗ (#{e.message})"
          failed_vms << vm_name
          File.delete(script_path) if File.exist?(script_path)
        end
      end

      puts ""
      puts "="*80
      puts "SSH KEY DISTRIBUTION SUMMARY"
      puts "="*80
      puts "Success: #{success_count}/#{vms.length} VMs"

      if failed_vms.empty?
        puts "✓ All VMs configured successfully!"
        puts ""
        puts "="*80
        puts "MULTI-CLUSTER SETUP COMPLETE"
        puts "="*80
        puts ""
        puts "SSH is configured for passwordless access:"
        puts "  • No password required"
        puts "  • No 'yes/no' prompt (StrictHostKeyChecking disabled)"
        puts "  • Host key verification disabled"
        puts ""
        puts "Test SSH access between nodes:"
        puts "  1. Login to any node: vagrant ssh #{ALL_VM_NAMES.first}"
        puts "  2. SSH to another node: ssh vagrant@<node-name> or ssh vagrant@<node-ip>"
        puts ""

        # ======================================================================
        # Print Dashboard access info for each cluster
        # ======================================================================
        puts "="*80
        puts "🖥️  HEADLAMP KUBERNETES UI (Helm chart v#{HEADLAMP_VERSION})"
        puts "="*80
        puts ""
        puts "  ⚠️  NOTE: kubernetes-retired/dashboard was archived Jan 21, 2026."
        puts "  Headlamp is the official SIG-UI successor."
        puts ""
        puts "  📋 On the Headlamp login screen, paste the token shown at end of provisioning,"
        puts "     OR run the commands below."
        puts ""
        ALL_CLUSTERS_DECLARATION.each do |cluster_name, config|
          primary_master_ip = "#{config[:base_subnet]}.#{IP_OFFSETS['master'][1]}"
          primary_master_vm = config[:master_count] == 1 ? "#{cluster_name}-master" : "#{cluster_name}-master1"
          puts "  ── #{cluster_name} ──"
          puts "  URL:   http://#{primary_master_ip}:<nodeport>  (NodePort shown in provisioning output)"
          puts "  Token: vagrant ssh #{primary_master_vm} -c \\"
          puts "           'kubectl get secret admin-user-token -n headlamp -o jsonpath={.data.token} | base64 --decode && echo'"
          puts "  Port:  vagrant ssh #{primary_master_vm} -c 'kubectl get svc headlamp -n headlamp'"
          puts "  Helm:  vagrant ssh #{primary_master_vm} -c 'helm list -n headlamp'"
          puts ""
        end

        puts "="*80
        puts ""
        puts "Kubernetes clusters are ready!"
        ALL_CLUSTERS_DECLARATION.each do |cluster_name, config|
          primary_master = config[:master_count] == 1 ? "#{cluster_name}-master" : "#{cluster_name}-master1"
          puts "  • #{cluster_name}: vagrant ssh #{primary_master} -c 'kubectl get nodes'"
        end

        # Print HAProxy stats URLs for HA clusters
        ha_clusters = ALL_CLUSTERS_DECLARATION.select { |_, c| c[:master_count] > 1 }
        unless ha_clusters.empty?
          puts ""
          puts "📊 HAProxy Stats Pages (HA clusters):"
          ha_clusters.each do |cluster_name, config|
            lb_ip = "#{config[:base_subnet]}.#{IP_OFFSETS['lb']}"
            puts "  • #{cluster_name}: http://#{lb_ip}:8404/stats"
            puts "  • Username: admin, Password: yourpassword"
          end
        end

      else
        puts "⚠ Failed VMs: #{failed_vms.join(', ')}"
        puts ""
        puts "To retry failed VMs manually, run:"
        failed_vms.each do |vm|
          puts "  vagrant provision #{vm} --provision-with ssh-setup"
        end
      end

      puts "="*80
      puts ""
    end
  end
end
# =====================================================================================================================================
# END OF VAGRANTFILE
# =====================================================================================================================================
