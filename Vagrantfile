# -*- mode: ruby -*-
# vi: set ft=ruby :

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#                                           MULTI-CLUSTER KUBERNETES SETUP WITH PASSWORDLESS SSH                                 
# ----------------------------------------------------------------------------------------------------------------------------------------
#               FOR DEVELOPMENT, TESTING, AND LEARNING PURPOSES ONLY .. FOR DEVELOPMENT, TESTING, AND LEARNING PURPOSES ONLY                                     
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#
# This Vagrantfile creates multiple high-availability independent Kubernetes clusters with:
#   • Multiple master nodes (configurable per cluster)
#   • Multiple worker nodes (configurable per cluster)
#   • HAProxy load balancer for HA setups (automatically created when master_count > 1)
#   • Calico CNI for pod networking
#   • MetalLB for LoadBalancer service type
#   • Headlamp Kubernetes UI (SIG-UI successor to archived kubernetes-dashboard), deployed via Helm
#   • Metrics Server for cluster monitoring
#   • Passwordless SSH between all VMs (within and across clusters)
#
# Prerequisites:
#   • VirtualBox  >= 7.0   — https://www.virtualbox.org/wiki/Downloads
#   • Vagrant     >= 2.4   — https://www.vagrantup.com/downloads
#
# SSH Configuration:
#   • Each VM generates its own SSH key pair during provisioning
#   • Public keys are shared via /vagrant/.vagrant/ssh-keys/ directory
#   • Progressive key distribution allows nodes to SSH immediately as they provision
#   • Continuous background sync process imports new keys automatically every 3 seconds
#   • VM can SSH into each other without password or "yes" prompt
#   • Ensure that the script "distribute-ssh-keys-dynamic-vm.sh" is in same directory as the Vagrantfile
#
# Clusters Configuration:
#   • dr:         Disaster Recovery cluster
#   • prod:       Production cluster
#   • pre-prod:   Pre-production cluster
#   • qa:         QA/Testing cluster
#   • dev:        Development cluster
#
#   • Each cluster is independent but VMs can communicate with and across clusters via passwordless SSH
#
# Resource Recommendations (per VM):
#   • Master Nodes:  2 vCPU, 4GB RAM minimum
#   • Worker Nodes:  1 vCPU, 2GB RAM minimum
#   • Load Balancer: 1 vCPU, 1GB RAM minimum recommended to prevent OOM errors
#
# Usage:
#    vagrant up                  # Create and provision all clusters
#    vagrant up k8s-qa-master    # Create and provision specific VM    
#    vagrant halt                # Shut down all VMs (<30s per VM)
#    vagrant reload              # Restart all VMs quickly
#    vagrant provision           # Re-provision (e.g. after version changes)
#    vagrant destroy -f          # Tear down all VMs
#    vagrant status              # List and Show VM states
#    vagrant ssh <vm-name>       # SSH into a specific VM
#
#    Version Upgrades / Downgrades (for Kubernetes, cri-dockerd, Calico, MetalLB, Helm, etc.) found in KUBERNETES & TOOL VERSIONS section:
#         1. Edit the version constant in the KUBERNETES & TOOL VERSIONS section below (e.g. K8S_VERSION = "1.32")
#         2. Run: vagrant provision or vagrant reload --provision
#            The idempotent scripts detect the installed version vs. declared version and will upgrade or downgrade automatically.
#            
#         NOTES:
#             • K8S_VERSION can be upgraded across minor versions (e.g. 1.32 → 1.33) but not downgraded across minor versions.
#             • cri-dockerd, Calico, MetalLB, Helm, etc. can be upgraded or downgraded across any version.
#
#    Adding/Removing Clusters:
#         Edit ALL_CLUSTERS_DECLARATION section. Comment out a cluster to disable it. Run "vagrant up" — only new VMs are created;
#         existing VMs are left untouched (idempotent).
#
# Idempotency:
#    Running "vagrant up" multiple times is safe. Provisioners check whether each component is already installed/configured before acting.
#    kubeadm join checks for /etc/kubernetes/kubelet.conf; kubectl apply is naturally idempotent; Helm checks helm list before installing.
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
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#
# Example AWS EC2 t2 Instance Types for Reference
# -----------------------------------------------
# Instance Type                     Family                    vCPU       CPU Cores       Threads/Core       Memory (GiB)      Memory (GB)
#   t2.micro              General Purpose (burstable)           1           ~1               ~1                  1                1.1
#   t2.medium             General Purpose (burstable)           2           ~2               ~1                  4                4.3
#   t2.large              General Purpose (burstable)           2           ~2               ~1                  8                8.6
#   t2.xlarge             General Purpose (burstable)           4           ~4               ~1                 16              17.20
#   t2.2xlarge            General Purpose (burstable)           8           ~8               ~1                 32              34.40
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
# ----------------------------------------------------------------------------------------------------------------------------------------

require 'fileutils'

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  CLUSTER DEFINITIONS
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Add additional clusters by appending entries.  Each cluster gets its own isolated K8S control plane, workers, and (optionally) LB.

ALL_CLUSTERS_DECLARATION = {
  "k8s-dr" => {
    base_subnet: "192.168.55",
    master_count: 2,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 4096,
    worker_cpus: 2,
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
    worker_count: 3,
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

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  LOAD BALANCER DEFAULTS (only created when master_count > 1)
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
LB_CPUS                     = 1
LB_MEMORY                   = 1024

# VirtualBox group (hierarchical groups per cluster will be under this)
VB_MAIN_GROUP               = "/Main-Multi-Cluster"

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  BASE BOX & VERSION CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Supported boxes (uncomment your desired set):                            Boxes Repo: https://portal.cloud.hashicorp.com/vagrant/discover

# Option 1: Bento Ubuntu 25.04 (Recommended - uses password auth)
BOX_IMAGE                   = "bento/ubuntu-25.04"
BOX_VERSION                 = "202510.26.0"

# Option 2: Ubuntu 24.04 (Fallback - uses insecure key)
# BOX_IMAGE                   = "kdq/ubuntu-24.04"
# BOX_VERSION                 = "1.0"

# Option 3: Ubuntu 22.04 LTS Jammy (Alternative - uses insecure key)
# BOX_IMAGE                   = "ubuntu/jammy64"
# BOX_VERSION                 = "20241002.0.0"

# Option 4: Generic Ubuntu 22.04 (Alternative - requires SYNCED_FOLDER_TYPE = "rsync")
# BOX_IMAGE                   = "generic/ubuntu2204"
# BOX_VERSION                 = nil

BOX_CHECK_UPDATES           = false
SYNCED_FOLDER_TYPE          = nil

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  KUBERNETES & CONTAINER RUNTIME VERSIONS
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# To upgrade or downgrade, change the version here and run `vagrant provision` or `vagrant reload --provision`.

K8S_VERSION                 = "1.33"                        # Check latest version: https://github.com/kubernetes/kubernetes/releases
CRI_DOCKERD_VERSION         = "v0.3.24"                     # Check latest version: https://github.com/Mirantis/cri-dockerd

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  CNI & LOAD BALANCER VERSIONS
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# To upgrade or downgrade, change the version here and run `vagrant provision` or `vagrant reload --provision`.

CALICO_VERSION              = "v3.31.4"                     # Check latest version: https://github.com/projectcalico/calico/releases
METALLB_VERSION             = "v0.15.3"                     # Check latest version: https://github.com/metallb/metallb/releases
HEADLAMP_VERSION            = "0.40.0"                      # Check latest version: https://artifacthub.io/packages/helm/headlamp/headlamp
HELM_VERSION                = "4.1.1"                       # Check latest version: https://github.com/helm/helm/releases
METRICS_SERVER_REPLICAS     = 2                             # Metrics Server HA replicas

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  UTILITY PACKAGES (installed on ALL VMs including LB)
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Defined once here, passed as a variable to the base setup provisioner. Edit this list to add/remove packages for all VMs.

UTILITY_PACKAGES = %w[
  build-essential net-tools util-linux software-properties-common curl wget unzip zip tar nano htop tree jq dnsutils iputils-ping ntfs-3g
  traceroute nmap lsof psmisc sysstat screen tmux parted ncal rsync whois ca-certificates gnupg lsb-release strace tcpdump netcat-openbsd 
  vim proot unrar p7zip-full exfatprogs cloud-utils e2fsprogs xfsprogs nfs-common socat
].join(' ')

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  CENTRALIZED IP OFFSET MAP & GLOBAL LB HARDWARE CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Maps node role + index to the last octet of the private IP address.
#
# NOTE on lb vs lb_vip:
#   'lb'        →   The HAProxy VM's actual IP. This is also used as the Kubernetes control-plane endpoint when master_count > 1.
#   'lb_vip'    →   Reserved for a future keepalived virtual IP. Not currently used.

IP_OFFSETS = {
  'lb_vip'  => 10,
  'lb'      => 20,
  'master'  => { 1 => 11, 2 => 12, 3 => 13, 4 => 14, 5 => 15, 6 => 16, 7 => 17, 8 => 18, 9 => 19, 10 => 20, 11 => 31, 12 => 33, 13 => 35},
  'worker'  => { 1 => 21, 2 => 22, 3 => 23, 4 => 24, 5 => 25, 6 => 26, 7 => 27, 8 => 28, 9 => 29, 10 => 30, 11 => 32, 12 => 34, 13 => 36}
}

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  IRTUALBOX GROUPS  (single source of truth for all VM grouping)
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Each cluster is placed in its own VirtualBox group for clear organisation.
#   Cluster 1   →   /Main-Multi-Cluster-1
#   Cluster 2   →   /Main-Multi-Cluster-2   …and so on.

cluster_count = ALL_CLUSTERS_DECLARATION.size

CLUSTER_GROUPS = {}
ALL_CLUSTERS_DECLARATION.each_with_index do |(cname, _cfg), idx|
  suffix = cluster_count > 1 ? "-#{idx + 1}" : ""
  CLUSTER_GROUPS[cname] = "#{VB_MAIN_GROUP}#{suffix}/#{cname}"
end

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  POD NETWORK CIDR
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

POD_NETWORK_CIDR            = "10.244.0.0/16"

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  HELPER METHODS
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def node_ip(base_subnet, role, index)
  "#{base_subnet}.#{IP_OFFSETS[role][index]}"
end

def lb_ip(base_subnet)
  "#{base_subnet}.#{IP_OFFSETS['lb']}"
end

def lb_vip_ip(base_subnet)
  "#{base_subnet}.#{IP_OFFSETS['lb_vip']}"
end

def node_name(cluster_name, role, index, count)
  count == 1 ? "#{cluster_name}-#{role}" : "#{cluster_name}-#{role}#{index}"
end

def generate_hosts_entries
  entries = []
  ALL_CLUSTERS_DECLARATION.each do |cname, cfg|
    s = cfg[:base_subnet]
    entries << "#{lb_ip(s)} #{cname}-lb" if cfg[:master_count] > 1
    (1..cfg[:master_count]).each  { |i| entries << "#{node_ip(s,'master',i)} #{node_name(cname,'master',i,cfg[:master_count])}" }
    (1..cfg[:worker_count]).each  { |i| entries << "#{node_ip(s,'worker',i)} #{node_name(cname,'worker',i,cfg[:worker_count])}" }
  end
  entries.join("\n")
end

def all_vm_names
  names = []
  ALL_CLUSTERS_DECLARATION.each do |cname, cfg|
    names << "#{cname}-lb" if cfg[:master_count] > 1
    (1..cfg[:master_count]).each { |i| names << node_name(cname, "master", i, cfg[:master_count]) }
    (1..cfg[:worker_count]).each { |i| names << node_name(cname, "worker", i, cfg[:worker_count]) }
  end
  names
end

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  SSH CONFIGURATION SETUP
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
SSH_KEY_DIR     = File.join(File.dirname(__FILE__), '.vagrant', 'ssh-keys')
SSH_PRIVATE_KEY = File.join(SSH_KEY_DIR, 'id_rsa')
SSH_PUBLIC_KEY  = File.join(SSH_KEY_DIR, 'id_rsa.pub')

unless File.exist?(SSH_PRIVATE_KEY)
  FileUtils.mkdir_p(SSH_KEY_DIR)
  system("ssh-keygen -t rsa -b 2048 -f \"#{SSH_PRIVATE_KEY}\" -N '' -q")
end

SSH_PUB_KEY_CONTENT = File.read(SSH_PUBLIC_KEY).strip

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  CLUSTER DATA DIRECTORIES
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
ALL_CLUSTERS_DECLARATION.each_key do |cname|
  FileUtils.mkdir_p(File.join(File.dirname(__FILE__), '.vagrant', 'cluster-data', cname))
end

HOSTS_ENTRIES = generate_hosts_entries

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  BOX CHANGE GUARD FILE
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
BOX_STATE_FILE = File.join(File.dirname(__FILE__), '.vagrant', 'box-state')

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  PROVISIONING SCRIPTS
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
#  Base Setup - every node (including LB)
# ---------------------------------------------------------------------------
SCRIPT_BASE_SETUP = <<~'SHELL'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

HOSTS_ENTRIES="$1"
SSH_PUB_KEY="$2"
UTIL_PKGS="$3"

# -- Ensure /vagrant/.vagrant/cluster-data exists inside the VM -------------
mkdir -p /vagrant/.vagrant/cluster-data 2>/dev/null || true

# -- Utility packages (idempotent — apt skips already-installed packages) ---
if [ -n "${UTIL_PKGS}" ]; then
  MARKER="/var/lib/vagrant-util-pkgs-installed"
  if [ ! -f "${MARKER}" ]; then
    echo "================================================================"
    echo "Installing utility packages..."
    echo "================================================================"
    apt-get update -qq
    apt-get install -y --no-install-recommends ${UTIL_PKGS} || true
    touch "${MARKER}"
  fi
fi

# -- /etc/hosts -------------------------------------------------------------
sed -i '/# VAGRANT-K8S-BEGIN/,/# VAGRANT-K8S-END/d' /etc/hosts
cat >> /etc/hosts <<EOF
# VAGRANT-K8S-BEGIN
${HOSTS_ENTRIES}
# VAGRANT-K8S-END
EOF

# -- Disable swap -----------------------------------------------------------
swapoff -a 2>/dev/null || true
sed -i '/\sswap\s/d' /etc/fstab

# -- SSH authorized key --
for UHOME in /home/vagrant /root; do
  mkdir -p "${UHOME}/.ssh"
  echo "${SSH_PUB_KEY}" >> "${UHOME}/.ssh/authorized_keys"
  sort -u -o "${UHOME}/.ssh/authorized_keys" "${UHOME}/.ssh/authorized_keys"
  chmod 700 "${UHOME}/.ssh"
  chmod 600 "${UHOME}/.ssh/authorized_keys"
done
chown -R vagrant:vagrant /home/vagrant/.ssh
SHELL

# ---------------------------------------------------------------------------
#  SSH Private Key
# ---------------------------------------------------------------------------
SCRIPT_SSH_PRIVKEY = <<~'SHELL'
#!/bin/bash
set -euo pipefail

KEY_PATH="/home/vagrant/.ssh/id_rsa"
CFG_PATH="/home/vagrant/.ssh/config"

if [ -f /tmp/cluster_id_rsa ]; then
  mv /tmp/cluster_id_rsa "${KEY_PATH}"
  chmod 600 "${KEY_PATH}"
  chown vagrant:vagrant "${KEY_PATH}"
fi

cat > "${CFG_PATH}" <<'EOF'
Host 192.168.* k8s-* *.local
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
chmod 600 "${CFG_PATH}"
chown vagrant:vagrant "${CFG_PATH}"
SHELL

# ---------------------------------------------------------------------------
#  K8s Prerequisites - masters and workers
# ---------------------------------------------------------------------------
SCRIPT_K8S_PREREQS = <<~'SHELL'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

K8S_VER="$1"
CRI_VER="$2"
NODE_IP="$3"

# -- Kernel modules ---------------------------------------------------------
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# -- Sysctl -----------------------------------------------------------------
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null 2>&1

# -- Docker CE --------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release apt-transport-https >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  chmod a+r /etc/apt/keyrings/docker.gpg
  CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
  if [ -z "${CODENAME}" ] || [ "${CODENAME}" = "n/a" ]; then
    CODENAME=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo "jammy")
    [ -z "${CODENAME}" ] && CODENAME="jammy"
  fi
  DOCKER_CODENAME="${CODENAME}"
  if ! curl -fsSL --head "https://download.docker.com/linux/ubuntu/dists/${DOCKER_CODENAME}/Release" &>/dev/null; then
    echo "Docker repo for '${DOCKER_CODENAME}' not found, falling back to 'noble'..."
    DOCKER_CODENAME="noble"
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io >/dev/null
  usermod -aG docker vagrant
fi

# -- Docker systemd cgroup driver -------------------------------------------
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DJEOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m" },
  "storage-driver": "overlay2"
}
DJEOF
systemctl daemon-reload
systemctl enable docker
systemctl restart docker

# -- Disable containerd CRI plugin ------------------------------------------
CONTAINERD_CFG="/etc/containerd/config.toml"
mkdir -p /etc/containerd
if [ ! -f "${CONTAINERD_CFG}" ] || ! grep -q 'disabled_plugins.*cri' "${CONTAINERD_CFG}" 2>/dev/null; then
  containerd config default > "${CONTAINERD_CFG}" 2>/dev/null || true
  sed -i 's/disabled_plugins = \[\]/disabled_plugins = ["cri"]/' "${CONTAINERD_CFG}"
  if ! grep -q 'disabled_plugins.*cri' "${CONTAINERD_CFG}" 2>/dev/null; then
    sed -i '1s/^/disabled_plugins = ["cri"]\n/' "${CONTAINERD_CFG}"
  fi
  systemctl restart containerd 2>/dev/null || true
fi

# -- cri-dockerd (version-aware) --------------------------------------------
DESIRED_CRI=$(echo "${CRI_VER}" | sed 's/^v//')
INSTALLED_CRI=""
if command -v cri-dockerd &>/dev/null; then
  INSTALLED_CRI=$(cri-dockerd --version 2>&1 | grep -oP '[\d.]+' | head -1 || true)
fi

if [ "${INSTALLED_CRI}" != "${DESIRED_CRI}" ]; then
  echo "================================================================"
  echo "cri-dockerd: ${INSTALLED_CRI:-none} → ${DESIRED_CRI} (upgrade/downgrade)"
  echo "================================================================"
  systemctl stop cri-docker.service 2>/dev/null || true
  systemctl stop cri-docker.socket 2>/dev/null || true
  ARCH=$(dpkg --print-architecture)
  curl -fsSL "https://github.com/Mirantis/cri-dockerd/releases/download/${CRI_VER}/cri-dockerd-${DESIRED_CRI}.${ARCH}.tgz" \
    | tar -xz -C /tmp/
  install -o root -g root -m 0755 /tmp/cri-dockerd/cri-dockerd /usr/local/bin/cri-dockerd
  rm -rf /tmp/cri-dockerd

  cat > /etc/systemd/system/cri-docker.service <<'SVCEOF'
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target firewalld.service docker.service
Wants=network-online.target
Requires=docker.service cri-docker.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd --container-runtime-endpoint fd:// --network-plugin= --pod-infra-container-image=registry.k8s.io/pause:3.10
Restart=always
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
SVCEOF

  cat > /etc/systemd/system/cri-docker.socket <<'SOCKEOF'
[Unit]
Description=CRI Docker Socket for the API
PartOf=cri-docker.service

[Socket]
ListenStream=/var/run/cri-dockerd.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
SOCKEOF

  systemctl daemon-reload
  systemctl enable --now cri-docker.socket
  systemctl enable --now cri-docker.service
fi

systemctl is-active --quiet cri-docker.socket  || systemctl start cri-docker.socket
systemctl is-active --quiet cri-docker.service || systemctl start cri-docker.service
TRIES=0
while [ ! -S /var/run/cri-dockerd.sock ] && [ $TRIES -lt 30 ]; do
  sleep 2; TRIES=$((TRIES+1))
done

# -- kubeadm / kubelet / kubectl (version-aware) ----------------------------
INSTALLED_KUBELET=""
if command -v kubelet &>/dev/null; then
  INSTALLED_KUBELET=$(kubelet --version 2>/dev/null | grep -oP 'v\K[\d]+\.[\d]+' || true)
fi

if [ "${INSTALLED_KUBELET}" != "${K8S_VER}" ]; then
  echo "================================================================"
  echo "Kubernetes: ${INSTALLED_KUBELET:-none} → ${K8S_VER} (upgrade/downgrade)"
  echo "================================================================"
  rm -f /etc/apt/sources.list.d/kubernetes*.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VER}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VER}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq
  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
  apt-get remove -y -qq kubelet kubeadm kubectl 2>/dev/null || true
  apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
  apt-mark hold kubelet kubeadm kubectl
fi

# -- Auto-detect private network interface by matching the assigned IP ------
# VirtualBox can name the interface eth1, enp0s8, enp0s9, etc.
PRIV_IFACE=$(ip -o -4 addr show | grep "${NODE_IP}" | awk '{print $2}' | head -1)
if [ -z "$PRIV_IFACE" ]; then
  echo "WARNING: Could not detect interface for ${NODE_IP}, falling back to kubelet node-ip only."
  PRIV_IFACE=""
fi
echo "  Detected private interface: ${PRIV_IFACE:-none} for IP ${NODE_IP}"

# -- Kubelet drop-in: force cri-dockerd socket and set node-ip --------------
mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/10-cri-dockerd.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///var/run/cri-dockerd.sock --node-ip=${NODE_IP}"
EOF

mkdir -p /etc/default
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///var/run/cri-dockerd.sock --node-ip=${NODE_IP}
EOF

systemctl daemon-reload
systemctl enable kubelet

echo "[k8s-prereqs] Done. (interface=${PRIV_IFACE:-auto}, node-ip=${NODE_IP})"
SHELL

# ---------------------------------------------------------------------------
#  HAProxy Load Balancer
# ---------------------------------------------------------------------------
SCRIPT_LB_SETUP = <<~'SHELL'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CLUSTER_NAME="$1"
BASE_SUBNET="$2"
MASTER_COUNT="$3"

if ! command -v haproxy &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq haproxy >/dev/null
fi

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    retries 3

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if LOCALHOST

frontend kubernetes-frontend
    bind *:6443
    default_backend kubernetes-backend

backend kubernetes-backend
    balance roundrobin
EOF

MASTER_OFFSETS=(11 12 13 14 15 16 17 18 19 20 31 33)
for i in $(seq 1 "${MASTER_COUNT}"); do
  OFFSET=${MASTER_OFFSETS[$((i-1))]}
  if [ "${MASTER_COUNT}" -eq 1 ]; then
    NAME="${CLUSTER_NAME}-master"
  else
    NAME="${CLUSTER_NAME}-master${i}"
  fi
  echo "    server ${NAME} ${BASE_SUBNET}.${OFFSET}:6443 check fall 3 rise 2" \
    >> /etc/haproxy/haproxy.cfg
done

systemctl enable haproxy
systemctl restart haproxy
echo "[lb] HAProxy configured for ${CLUSTER_NAME}."
SHELL

# ---------------------------------------------------------------------------
#  First Master Initialization
# ---------------------------------------------------------------------------
SCRIPT_MASTER_INIT = <<~'SHELL'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NODE_IP="$1"
CLUSTER_NAME="$2"
BASE_SUBNET="$3"
MASTER_COUNT="$4"
POD_CIDR="$5"
CALICO_VER="$6"
METALLB_VER="$7"
METALLB_RANGE="$8"
HELM_VER="$9"
HEADLAMP_VER="${10}"
METRICS_REPLICAS="${11}"
CONTEXT_NAME="${12}"
LB_OFFSET="${13}"

DATA_DIR="/vagrant/.vagrant/cluster-data/${CLUSTER_NAME}"
mkdir -p "${DATA_DIR}"

# ===========================================================================
#  Helper: show pod progress
# ===========================================================================
show_pod_progress() {
  local NS="$1"
  local TIMEOUT="${2:-120}"
  local ELAPSED=0
  local INTERVAL=10
  while [ $ELAPSED -lt "$TIMEOUT" ]; do
    echo ""
    echo "--- Pod status in '${NS}' (${ELAPSED}s / ${TIMEOUT}s) ---"
    kubectl get pods -n "${NS}" -o wide 2>/dev/null || true
    local NOT_READY
    NOT_READY=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null \
      | grep -vcE 'Running|Completed|Succeeded' || true)
    if [ "$NOT_READY" -eq 0 ] && [ "$ELAPSED" -gt 0 ]; then
      echo "All pods in '${NS}' are ready!"
      return 0
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  echo "WARNING: Not all pods in '${NS}' became ready within ${TIMEOUT}s."
  kubectl get pods -n "${NS}" -o wide 2>/dev/null || true
  return 0
}

# ===========================================================================
#  Helper: add control-plane toleration to a deployment
# ===========================================================================
add_control_plane_toleration() {
  local NS="$1"
  local DEPLOY="$2"
  echo "  Patching ${DEPLOY} in ${NS} to tolerate control-plane taint..."
  kubectl patch deployment "${DEPLOY}" -n "${NS}" --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/tolerations/-",
      "value": {
        "key": "node-role.kubernetes.io/control-plane",
        "operator": "Exists",
        "effect": "NoSchedule"
      }
    }
  ]' 2>/dev/null || \
  kubectl patch deployment "${DEPLOY}" -n "${NS}" --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/tolerations",
      "value": [
        {
          "key": "node-role.kubernetes.io/control-plane",
          "operator": "Exists",
          "effect": "NoSchedule"
        }
      ]
    }
  ]' 2>/dev/null || true
}

# ---- Ensure cri-dockerd is running ----------------------------------------
systemctl is-active --quiet cri-docker.socket  || systemctl start cri-docker.socket
systemctl is-active --quiet cri-docker.service || systemctl start cri-docker.service
sleep 2

TRIES=0
while [ ! -S /var/run/cri-dockerd.sock ] && [ $TRIES -lt 30 ]; do
  echo "Waiting for cri-dockerd socket..."; sleep 2; TRIES=$((TRIES+1))
done
if [ ! -S /var/run/cri-dockerd.sock ]; then
  echo "ERROR: cri-dockerd socket not found after 60s."
  systemctl status cri-docker.service --no-pager || true
  exit 1
fi

# ---- kubeadm init (skip if already initialised) ---------------------------
if [ ! -f /etc/kubernetes/admin.conf ]; then
  kubeadm reset -f --cri-socket unix:///var/run/cri-dockerd.sock 2>/dev/null || true

  echo "Pre-pulling Kubernetes images via cri-dockerd..."
  kubeadm config images pull --cri-socket unix:///var/run/cri-dockerd.sock

  INIT_ARGS="--apiserver-advertise-address=${NODE_IP}"
  INIT_ARGS+=" --pod-network-cidr=${POD_CIDR}"
  INIT_ARGS+=" --cri-socket unix:///var/run/cri-dockerd.sock"

  if [ "${MASTER_COUNT}" -gt 1 ]; then
    LB_REAL_IP="${BASE_SUBNET}.${LB_OFFSET}"
    INIT_ARGS+=" --control-plane-endpoint=${LB_REAL_IP}:6443 --upload-certs"
    INIT_ARGS+=" --apiserver-cert-extra-sans=${NODE_IP},${LB_REAL_IP}"
  else
    INIT_ARGS+=" --apiserver-cert-extra-sans=${NODE_IP}"
  fi

  kubeadm init ${INIT_ARGS}
fi

# ---- kubeconfig -----------------------------------------------------------
for UHOME in /home/vagrant /root; do
  mkdir -p "${UHOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "${UHOME}/.kube/config"
done
chown -R vagrant:vagrant /home/vagrant/.kube
export KUBECONFIG=/etc/kubernetes/admin.conf

# ---- Configure context name with cluster name -----------------------------
# Rename the default "kubernetes-admin@kubernetes" context to the cluster name for easier multi-cluster management with kubectl.
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || true)
if [ -n "$CURRENT_CTX" ] && [ "$CURRENT_CTX" != "${CLUSTER_NAME}" ]; then
  kubectl config rename-context "${CURRENT_CTX}" "${CLUSTER_NAME}" 2>/dev/null || true
  echo "  Kubernetes context renamed: ${CURRENT_CTX} → ${CLUSTER_NAME}"
fi
# Also rename for the vagrant user
su - vagrant -c "
  export KUBECONFIG=/home/vagrant/.kube/config
  CTX=\$(kubectl config current-context 2>/dev/null || true)
  if [ -n \"\$CTX\" ] && [ \"\$CTX\" != '${CLUSTER_NAME}' ]; then
    kubectl config rename-context \"\$CTX\" '${CLUSTER_NAME}' 2>/dev/null || true
  fi
" 2>/dev/null || true

# ---- Save join commands ---------------------------------------------------
JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
echo "${JOIN_CMD} --cri-socket unix:///var/run/cri-dockerd.sock" > "${DATA_DIR}/worker-join.sh"
chmod +x "${DATA_DIR}/worker-join.sh"

if [ "${MASTER_COUNT}" -gt 1 ]; then
  CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
  echo "${JOIN_CMD} --control-plane --certificate-key ${CERT_KEY} --cri-socket unix:///var/run/cri-dockerd.sock \"\$@\"" \
    > "${DATA_DIR}/master-join.sh"
  chmod +x "${DATA_DIR}/master-join.sh"
fi

cp -f /etc/kubernetes/admin.conf "${DATA_DIR}/admin.conf"

echo "Waiting for API server..."
until kubectl get nodes &>/dev/null; do sleep 2; done

# ===========================================================================
#  CALICO CNI (version-aware upgrade/downgrade)
# ===========================================================================
INSTALLED_CALICO=""
if kubectl get daemonset -n kube-system calico-node &>/dev/null; then
  INSTALLED_CALICO=$(kubectl get daemonset -n kube-system calico-node \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | grep -oP 'v[\d.]+' || true)
fi

if [ "${INSTALLED_CALICO}" != "${CALICO_VER}" ]; then
  echo ""
  echo "================================================================"
  echo "  Calico: ${INSTALLED_CALICO:-none} → ${CALICO_VER} (install/upgrade/downgrade)"
  echo "================================================================"
  curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml" \
    -o /tmp/calico.yaml
  sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|g'         /tmp/calico.yaml
  sed -i 's|#   value: "192.168.0.0/16"|  value: "'"${POD_CIDR}"'"|g'               /tmp/calico.yaml
  sed -i 's|value: "192.168.0.0/16"|value: "'"${POD_CIDR}"'"|g'                     /tmp/calico.yaml
  kubectl apply -f /tmp/calico.yaml
  rm -f /tmp/calico.yaml
else
  echo ""
  echo "  Calico ${CALICO_VER} already installed — skipping."
fi

echo ""
echo "Waiting for Calico rollout..."
kubectl rollout status daemonset/calico-node -n kube-system --timeout=300s 2>/dev/null || true
show_pod_progress "kube-system" 120

# ===========================================================================
#  HELM (version-aware upgrade/downgrade)
# ===========================================================================
INSTALLED_HELM=""
if command -v helm &>/dev/null; then
  INSTALLED_HELM=$(helm version --short 2>/dev/null | grep -oP 'v\K[\d.]+' || true)
fi

if [ "${INSTALLED_HELM}" != "${HELM_VER}" ]; then
  echo ""
  echo "================================================================"
  echo "  Helm: ${INSTALLED_HELM:-none} → v${HELM_VER} (install/upgrade/downgrade)"
  echo "================================================================"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | DESIRED_VERSION="v${HELM_VER}" bash
else
  echo ""
  echo "  Helm v${HELM_VER} already installed — skipping."
fi

# ===========================================================================
#  METALLB (version-aware upgrade/downgrade)
# ===========================================================================
INSTALLED_METALLB=""
if kubectl get namespace metallb-system &>/dev/null; then
  INSTALLED_METALLB=$(kubectl get deployment -n metallb-system controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | grep -oP 'v[\d.]+' || true)
fi

if [ "${INSTALLED_METALLB}" != "${METALLB_VER}" ]; then
  echo ""
  echo "================================================================"
  echo "  MetalLB: ${INSTALLED_METALLB:-none} → ${METALLB_VER} (install/upgrade/downgrade)"
  echo "================================================================"
  kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VER}/config/manifests/metallb-native.yaml"

  echo "Patching MetalLB controller to schedule on control-plane nodes..."
  add_control_plane_toleration "metallb-system" "controller"

  echo "Waiting for MetalLB controller deployment rollout..."
  kubectl rollout status deployment/controller -n metallb-system --timeout=300s 2>/dev/null || true

  echo "Waiting for MetalLB webhook to become ready..."
  WEBHOOK_READY=false
  for attempt in $(seq 1 30); do
    if [ $((attempt % 5)) -eq 1 ]; then
      echo "  [${attempt}/30] Checking MetalLB pods..."
      kubectl get pods -n metallb-system -o wide 2>/dev/null || true
    fi
    if kubectl apply --dry-run=server -f - <<'DRYEOF' >/dev/null 2>&1
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: dry-run-test
  namespace: metallb-system
spec:
  addresses:
  - 192.168.255.240/32
DRYEOF
    then
      WEBHOOK_READY=true
      echo "  MetalLB webhook is ready! (attempt ${attempt})"
      break
    fi
    sleep 5
  done

  if [ "$WEBHOOK_READY" = false ]; then
    echo "WARNING: MetalLB webhook did not become ready within 300s."
    kubectl get pods -n metallb-system -o wide 2>/dev/null || true
  fi

  echo "Applying MetalLB IPAddressPool and L2Advertisement..."
  METALLB_CFG=$(cat <<MLEOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
MLEOF
  )

  APPLY_SUCCESS=false
  for attempt in $(seq 1 20); do
    echo "  [${attempt}/20] Applying MetalLB config..."
    if echo "${METALLB_CFG}" | kubectl apply -f - 2>&1; then
      APPLY_SUCCESS=true
      echo "  MetalLB configuration applied successfully!"
      break
    fi
    echo "  Retrying in 10s..."
    sleep 10
  done

  if [ "$APPLY_SUCCESS" = false ]; then
    echo "ERROR: Failed to apply MetalLB config after 20 attempts."
    echo "You can retry manually: vagrant provision <master-vm>"
    exit 1
  fi
else
  echo ""
  echo "  MetalLB ${METALLB_VER} already installed — skipping."
fi

show_pod_progress "metallb-system" 120

# ===========================================================================
#  METRICS SERVER
# ===========================================================================
if ! kubectl get deployment -n kube-system metrics-server &>/dev/null; then
  echo ""
  echo "================================================================"
  echo "  Installing Metrics Server (replicas=${METRICS_REPLICAS})..."
  echo "================================================================"
  curl -fsSL "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml" \
    -o /tmp/metrics-server.yaml
  sed -i '/- --metric-resolution/a\        - --kubelet-insecure-tls' /tmp/metrics-server.yaml
  kubectl apply -f /tmp/metrics-server.yaml
  rm -f /tmp/metrics-server.yaml
  add_control_plane_toleration "kube-system" "metrics-server"
fi

CURRENT_MS_ARGS=$(kubectl get deployment metrics-server -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)
if ! echo "${CURRENT_MS_ARGS}" | grep -q "kubelet-insecure-tls"; then
  echo "  Patching metrics-server to add --kubelet-insecure-tls..."
  kubectl patch deployment metrics-server -n kube-system --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true
fi

CURRENT_MS_REPLICAS=$(kubectl get deployment metrics-server -n kube-system \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
if [ "${CURRENT_MS_REPLICAS}" != "${METRICS_REPLICAS}" ]; then
  echo "  Scaling metrics-server to ${METRICS_REPLICAS} replicas..."
  kubectl scale deployment metrics-server -n kube-system --replicas="${METRICS_REPLICAS}" 2>/dev/null || true
fi

echo ""
echo "Waiting for Metrics Server rollout..."
kubectl rollout status deployment/metrics-server -n kube-system --timeout=300s 2>/dev/null || true
echo ""
echo "--- Metrics Server pods ---"
kubectl get pods -n kube-system -l k8s-app=metrics-server -o wide 2>/dev/null || true

# ===========================================================================
#  HEADLAMP DASHBOARD (version-aware upgrade/downgrade)
# ===========================================================================
INSTALLED_HEADLAMP=""
HEADLAMP_DEPLOYED=false
if helm list -n headlamp 2>/dev/null | grep -q headlamp; then
  HEADLAMP_DEPLOYED=true
  INSTALLED_HEADLAMP=$(helm list -n headlamp -o json 2>/dev/null \
    | jq -r '.[0].chart // empty' 2>/dev/null \
    | sed 's/^headlamp-//' || true)
fi

if [ "${INSTALLED_HEADLAMP}" != "${HEADLAMP_VER}" ]; then
  echo ""
  echo "================================================================"
  echo "  Headlamp: ${INSTALLED_HEADLAMP:-none} → ${HEADLAMP_VER} (install/upgrade/downgrade)"
  echo "================================================================"

  echo "  Adding Headlamp Helm repo..."
  helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ || true

  echo "  Updating Helm repos..."
  helm repo update || true

  echo "  Available Headlamp chart versions:"
  helm search repo headlamp/headlamp --versions 2>&1 | head -10 || true

  HELM_CMD="install"
  if [ "${HEADLAMP_DEPLOYED}" = true ]; then
    HELM_CMD="upgrade"
  fi

  HELM_INSTALL_SUCCESS=false
  for attempt in $(seq 1 5); do
    echo "  [${attempt}/5] Attempting helm ${HELM_CMD} headlamp ${HEADLAMP_VER}..."
    if helm ${HELM_CMD} headlamp headlamp/headlamp \
        --namespace headlamp --create-namespace \
        --version "${HEADLAMP_VER}" \
        --set service.type=LoadBalancer 2>&1; then
      HELM_INSTALL_SUCCESS=true
      echo "  Headlamp ${HELM_CMD}d successfully!"
      break
    fi
    echo "  Helm ${HELM_CMD} failed, retrying in 15s..."
    sleep 15
  done

  if [ "$HELM_INSTALL_SUCCESS" = false ]; then
    echo "WARNING: Headlamp ${HELM_CMD} failed after 5 attempts."
    echo "  You can retry: vagrant provision <master-vm>"
    echo "  Continuing..."
  else
    add_control_plane_toleration "headlamp" "headlamp"
  fi
else
  echo ""
  echo "  Headlamp ${HEADLAMP_VER} already installed — skipping."
fi

echo ""
echo "Waiting for Headlamp rollout..."
kubectl rollout status deployment/headlamp -n headlamp --timeout=120s 2>/dev/null || true
echo ""
echo "--- Headlamp pods ---"
kubectl get pods -n headlamp -o wide 2>/dev/null || true
echo ""
echo "--- Headlamp service (LoadBalancer) ---"
kubectl get svc -n headlamp -o wide 2>/dev/null || true

# ===========================================================================
#  FINAL STATUS
# ===========================================================================
echo ""
echo "================================================================"
echo "  Final cluster status for '${CLUSTER_NAME}' (context: ${CLUSTER_NAME})"
echo "================================================================"
echo ""
echo "--- Context ---"
kubectl config current-context 2>/dev/null || true
echo ""
echo "--- Nodes ---"
kubectl get nodes -o wide 2>/dev/null || true
echo ""
echo "--- All pods ---"
kubectl get pods --all-namespaces -o wide 2>/dev/null || true
echo ""
echo "============================================"
echo " Cluster '${CLUSTER_NAME}' (context: ${CLUSTER_NAME}) — master init complete"
echo "============================================"
SHELL

# ---------------------------------------------------------------------------
#  Additional Master Join (HA only)
#  Includes network connectivity check and retry loop to handle the
#  case where the LB/API server isn't yet reachable from master2+.
# ---------------------------------------------------------------------------
SCRIPT_MASTER_JOIN = <<~'SHELL'
#!/bin/bash
set -euo pipefail

CLUSTER_NAME="$1"
NODE_IP="$2"
LB_ENDPOINT="$3"
DATA_DIR="/vagrant/.vagrant/cluster-data/${CLUSTER_NAME}"

if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "[master-join] Already joined. Skipping."
  exit 0
fi

# Ensure cri-dockerd is running
systemctl is-active --quiet cri-docker.socket  || systemctl start cri-docker.socket
systemctl is-active --quiet cri-docker.service || systemctl start cri-docker.service
sleep 2

# Pre-pull images
echo "Pre-pulling Kubernetes images via cri-dockerd..."
kubeadm config images pull --cri-socket unix:///var/run/cri-dockerd.sock

# ---- Wait for the LB / API server to be reachable -------------------------
# This is critical: master2 is provisioned in parallel and the LB or master1 endpoint before attempting kubeadm join, which avoids the 
# "context deadline exceeded" error when the API server isn't reachable.

echo "Checking network connectivity to control-plane endpoint ${LB_ENDPOINT}..."
LB_HOST=$(echo "${LB_ENDPOINT}" | cut -d: -f1)
LB_PORT=$(echo "${LB_ENDPOINT}" | cut -d: -f2)
CONN_ELAPSED=0
CONN_TIMEOUT=300
while [ $CONN_ELAPSED -lt $CONN_TIMEOUT ]; do
  if timeout 5 bash -c "echo > /dev/tcp/${LB_HOST}/${LB_PORT}" 2>/dev/null; then
    echo "  Control-plane endpoint ${LB_ENDPOINT} is reachable! (${CONN_ELAPSED}s)"
    break
  fi
  echo "  [${CONN_ELAPSED}s/${CONN_TIMEOUT}s] Waiting for ${LB_ENDPOINT} to become reachable..."
  sleep 10
  CONN_ELAPSED=$((CONN_ELAPSED + 10))
done

if [ $CONN_ELAPSED -ge $CONN_TIMEOUT ]; then
  echo "ERROR: Control-plane endpoint ${LB_ENDPOINT} not reachable after ${CONN_TIMEOUT}s."
  echo "  Check that the LB VM and master1 are running."
  exit 1
fi

# ---- Wait for join command file -------------------------------------------
echo "Waiting for master join command..."
ELAPSED=0
while [ ! -f "${DATA_DIR}/master-join.sh" ]; do
  sleep 5; ELAPSED=$((ELAPSED+5))
  [ $ELAPSED -ge 600 ] && { echo "ERROR: Timed out waiting for join command."; exit 1; }
done

# ---- Join with retry loop -------------------------------------------------
# Even after the LB is reachable, the API server may need a few more seconds to fully initialize. Retry up to 5 times.
echo "Joining as control-plane node..."
JOIN_SUCCESS=false
for attempt in $(seq 1 5); do
  echo "  [${attempt}/5] Attempting kubeadm join..."
  if bash "${DATA_DIR}/master-join.sh" --apiserver-advertise-address="${NODE_IP}" 2>&1; then
    JOIN_SUCCESS=true
    break
  fi
  echo "  Join failed, resetting and retrying in 30s..."
  kubeadm reset -f --cri-socket unix:///var/run/cri-dockerd.sock 2>/dev/null || true
  sleep 30
done

if [ "$JOIN_SUCCESS" = false ]; then
  echo "ERROR: Failed to join cluster after 5 attempts."
  exit 1
fi

mkdir -p /home/vagrant/.kube
cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# Rename context for this node's kubeconfig too
export KUBECONFIG=/etc/kubernetes/admin.conf
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || true)
if [ -n "$CURRENT_CTX" ] && [ "$CURRENT_CTX" != "${CLUSTER_NAME}" ]; then
  kubectl config rename-context "${CURRENT_CTX}" "${CLUSTER_NAME}" 2>/dev/null || true
fi
su - vagrant -c "
  export KUBECONFIG=/home/vagrant/.kube/config
  CTX=\$(kubectl config current-context 2>/dev/null || true)
  if [ -n \"\$CTX\" ] && [ \"\$CTX\" != '${CLUSTER_NAME}' ]; then
    kubectl config rename-context \"\$CTX\" '${CLUSTER_NAME}' 2>/dev/null || true
  fi
" 2>/dev/null || true

echo "[master-join] Joined ${CLUSTER_NAME}."
SHELL

# ---------------------------------------------------------------------------
#  Worker Join - with connectivity check + retry
# ---------------------------------------------------------------------------
SCRIPT_WORKER_JOIN = <<~'SHELL'
#!/bin/bash
set -euo pipefail

CLUSTER_NAME="$1"
API_ENDPOINT="$2"
DATA_DIR="/vagrant/.vagrant/cluster-data/${CLUSTER_NAME}"

if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "[worker-join] Already joined. Skipping."
  exit 0
fi

# Ensure cri-dockerd is running
systemctl is-active --quiet cri-docker.socket  || systemctl start cri-docker.socket
systemctl is-active --quiet cri-docker.service || systemctl start cri-docker.service
sleep 2

# ---- Verify API server is reachable ---------------------------------------
API_HOST=$(echo "${API_ENDPOINT}" | cut -d: -f1)
API_PORT=$(echo "${API_ENDPOINT}" | cut -d: -f2)
echo "Checking connectivity to API endpoint ${API_ENDPOINT}..."
CONN_ELAPSED=0
CONN_TIMEOUT=300
while [ $CONN_ELAPSED -lt $CONN_TIMEOUT ]; do
  if timeout 5 bash -c "echo > /dev/tcp/${API_HOST}/${API_PORT}" 2>/dev/null; then
    echo "  API endpoint reachable! (${CONN_ELAPSED}s)"
    break
  fi
  echo "  [${CONN_ELAPSED}s/${CONN_TIMEOUT}s] Waiting for ${API_ENDPOINT}..."
  sleep 10
  CONN_ELAPSED=$((CONN_ELAPSED + 10))
done

# ---- Wait for join command file -------------------------------------------
echo "Waiting for worker join command..."
ELAPSED=0
while [ ! -f "${DATA_DIR}/worker-join.sh" ]; do
  sleep 5; ELAPSED=$((ELAPSED+5))
  [ $ELAPSED -ge 600 ] && { echo "ERROR: Timed out waiting for join command."; exit 1; }
done

# ---- Join with retry ------------------------------------------------------
echo "Joining as worker node..."
JOIN_SUCCESS=false
for attempt in $(seq 1 5); do
  echo "  [${attempt}/5] Attempting kubeadm join..."
  if bash "${DATA_DIR}/worker-join.sh" 2>&1; then
    JOIN_SUCCESS=true
    break
  fi
  echo "  Join failed, resetting and retrying in 15s..."
  kubeadm reset -f --cri-socket unix:///var/run/cri-dockerd.sock 2>/dev/null || true
  sleep 15
done

if [ "$JOIN_SUCCESS" = false ]; then
  echo "ERROR: Failed to join cluster after 5 attempts."
  exit 1
fi

echo "[worker-join] Joined ${CLUSTER_NAME}."
SHELL

# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#  VAGRANT VM DEFINITIONS
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
Vagrant.configure("2") do |config|

  # -- Global box settings --------------------------------------------------
  config.vm.box              = BOX_IMAGE
  if BOX_VERSION && !BOX_VERSION.to_s.strip.empty?
    config.vm.box_version    = BOX_VERSION
  end
  config.vm.box_check_update = BOX_CHECK_UPDATES

  # -- Suppress VirtualBox Guest Additions version mismatch warnings --------
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
    config.vbguest.no_remote   = true
  end

  # =========================================================================
  #  Performance & timeout tuning
  # =========================================================================
  config.vm.graceful_halt_timeout   = 30
  config.vm.boot_timeout            = 900
  config.ssh.connect_timeout        = 30
  config.ssh.insert_key             = true

  # -- Synced folder (configurable for box compatibility) -------------------
  if SYNCED_FOLDER_TYPE == "rsync"
    config.vm.synced_folder ".", "/vagrant",
      type: "rsync",
      rsync__exclude: [".git/", ".vagrant/machines/"],
      rsync__auto: false,
      rsync__args: ["--verbose", "--archive", "--delete", "-z"]
  elsif SYNCED_FOLDER_TYPE
    config.vm.synced_folder ".", "/vagrant", type: SYNCED_FOLDER_TYPE
  else
    config.vm.synced_folder ".", "/vagrant"
  end

  # =========================================================================
  #  Box Change Guard - prevents mixing box images on existing VMs
  # =========================================================================
  config.trigger.before :up do |trigger|
    trigger.name = "Box Change Guard"
    trigger.ruby do |_env, _machine|
      current_box = "#{BOX_IMAGE}@#{BOX_VERSION}"
      if File.exist?(BOX_STATE_FILE)
        previous_box = File.read(BOX_STATE_FILE).strip
        if previous_box != current_box
          puts ""
          puts "=" * 70
          puts "  WARNING: Box image changed!"
          puts "    Previous: #{previous_box}"
          puts "    Current:  #{current_box}"
          puts ""
          puts "  If VMs already exist with the old box, run:"
          puts "    vagrant destroy -f"
          puts "  before 'vagrant up' with the new box."
          puts "=" * 70
          puts ""
        end
      end
      FileUtils.mkdir_p(File.dirname(BOX_STATE_FILE))
      File.write(BOX_STATE_FILE, current_box)
    end
  end

  # =========================================================================
  #  Rsync-back trigger - for rsync-based synced folders, copy join commands
  #  from master1 VMs back to the host after provisioning so that workers
  #  and additional masters can read them.
  # =========================================================================
  if SYNCED_FOLDER_TYPE == "rsync"
    ALL_CLUSTERS_DECLARATION.each do |cluster_name, cfg|
      master1_name = cfg[:master_count] == 1 ? "#{cluster_name}-master" : "#{cluster_name}-master1"

      config.trigger.after :provision do |trigger|
        trigger.only_on = master1_name
        trigger.name    = "Rsync-back cluster data for #{cluster_name}"
        trigger.ruby do |_env, machine|
          local_data_dir = File.join(File.dirname(__FILE__), '.vagrant', 'cluster-data', cluster_name)
          FileUtils.mkdir_p(local_data_dir)

          %w[worker-join.sh master-join.sh admin.conf].each do |fname|
            remote_path = "/vagrant/.vagrant/cluster-data/#{cluster_name}/#{fname}"
            local_path  = File.join(local_data_dir, fname)
            begin
              content = `vagrant ssh #{master1_name} -c "cat #{remote_path} 2>/dev/null" 2>/dev/null`
              if $?.success? && !content.strip.empty?
                File.write(local_path, content)
                File.chmod(0755, local_path) if fname.end_with?('.sh')
                puts "  Copied #{fname} from #{master1_name} to host."
              end
            rescue => e
              puts "  Warning: Could not copy #{fname} from #{master1_name}: #{e.message}"
            end
          end
        end
      end

      remaining_vms = []
      if cfg[:master_count] > 1
        (2..cfg[:master_count]).each { |i| remaining_vms << "#{cluster_name}-master#{i}" }
      end
      (1..cfg[:worker_count]).each { |i| remaining_vms << node_name(cluster_name, "worker", i, cfg[:worker_count]) }

      remaining_vms.each do |vm_name|
        config.trigger.before :provision do |trigger|
          trigger.only_on = vm_name
          trigger.name    = "Rsync cluster data to #{vm_name}"
          trigger.run     = { inline: "vagrant rsync #{vm_name}" }
          trigger.on_error = :continue
        end
      end
    end
  end

  # =========================================================================
  #  Iterate over every declared cluster
  # =========================================================================
  ALL_CLUSTERS_DECLARATION.each do |cluster_name, cfg|
    subnet       = cfg[:base_subnet]
    master_count = cfg[:master_count]
    worker_count = cfg[:worker_count]
    needs_lb     = master_count > 1
    vbox_group   = CLUSTER_GROUPS[cluster_name]

    # The API endpoint that workers and additional masters connect to.
    # For HA clusters: the LB IP. For single-master: master1's IP directly.
    api_endpoint = needs_lb \
      ? "#{lb_ip(subnet)}:6443" \
      : "#{node_ip(subnet, 'master', 1)}:6443"

    # -----------------------------------------------------------------------
    #  LOAD BALANCER
    # -----------------------------------------------------------------------
    if needs_lb
      lb_hostname = "#{cluster_name}-lb"

      config.vm.define lb_hostname do |node|
        node.vm.hostname = lb_hostname
        node.vm.network "private_network", ip: lb_ip(subnet)

        node.vm.provider "virtualbox" do |v|
          v.name   = lb_hostname
          v.cpus   = LB_CPUS
          v.memory = LB_MEMORY
          v.customize ["modifyvm", :id, "--groups", vbox_group]
          v.customize ["modifyvm", :id, "--ioapic", "on"]
          v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
          v.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
          v.customize ["modifyvm", :id, "--nictype1", "virtio"]
          v.customize ["modifyvm", :id, "--nictype2", "virtio"]
        end

        node.vm.provision "base",    type: "shell", inline: SCRIPT_BASE_SETUP,  args: [HOSTS_ENTRIES, SSH_PUB_KEY_CONTENT, UTILITY_PACKAGES]
        node.vm.provision "file",    source: SSH_PRIVATE_KEY, destination: "/tmp/cluster_id_rsa"
        node.vm.provision "sshkey",  type: "shell", inline: SCRIPT_SSH_PRIVKEY
        node.vm.provision "haproxy", type: "shell", inline: SCRIPT_LB_SETUP, args: [cluster_name, subnet, master_count.to_s]
      end
    end

    # -----------------------------------------------------------------------
    #  MASTER NODES
    # -----------------------------------------------------------------------
    (1..master_count).each do |i|
      mname = node_name(cluster_name, "master", i, master_count)
      mip   = node_ip(subnet, 'master', i)

      config.vm.define mname do |node|
        node.vm.hostname = mname
        node.vm.network "private_network", ip: mip

        node.vm.provider "virtualbox" do |v|
          v.name   = mname
          v.cpus   = cfg[:master_cpus]
          v.memory = cfg[:master_memory]
          v.customize ["modifyvm", :id, "--groups", vbox_group]
          v.customize ["modifyvm", :id, "--ioapic", "on"]
          v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
          v.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
          v.customize ["modifyvm", :id, "--nictype1", "virtio"]
          v.customize ["modifyvm", :id, "--nictype2", "virtio"]
        end

        node.vm.provision "base",    type: "shell", inline: SCRIPT_BASE_SETUP,  args: [HOSTS_ENTRIES, SSH_PUB_KEY_CONTENT, UTILITY_PACKAGES]
        node.vm.provision "file",    source: SSH_PRIVATE_KEY, destination: "/tmp/cluster_id_rsa"
        node.vm.provision "sshkey",  type: "shell", inline: SCRIPT_SSH_PRIVKEY
        node.vm.provision "k8s_pre", type: "shell", inline: SCRIPT_K8S_PREREQS, args: [K8S_VERSION, CRI_DOCKERD_VERSION, mip]

        if i == 1
          node.vm.provision "master_init", type: "shell", inline: SCRIPT_MASTER_INIT,
            args: [
              mip, cluster_name, subnet, master_count.to_s,
              POD_NETWORK_CIDR, CALICO_VERSION, METALLB_VERSION,
              cfg[:metallb_ip_range], HELM_VERSION, HEADLAMP_VERSION,
              METRICS_SERVER_REPLICAS.to_s, cfg[:context_name],
              IP_OFFSETS['lb'].to_s
            ]
        else
          node.vm.provision "master_join", type: "shell", inline: SCRIPT_MASTER_JOIN,
            args: [cluster_name, mip, api_endpoint]
        end
      end
    end

    # -----------------------------------------------------------------------
    #  WORKER NODES
    # -----------------------------------------------------------------------
    (1..worker_count).each do |i|
      wname = node_name(cluster_name, "worker", i, worker_count)
      wip   = node_ip(subnet, 'worker', i)

      config.vm.define wname do |node|
        node.vm.hostname = wname
        node.vm.network "private_network", ip: wip

        node.vm.provider "virtualbox" do |v|
          v.name   = wname
          v.cpus   = cfg[:worker_cpus]
          v.memory = cfg[:worker_memory]
          v.customize ["modifyvm", :id, "--groups", vbox_group]
          v.customize ["modifyvm", :id, "--ioapic", "on"]
          v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
          v.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
          v.customize ["modifyvm", :id, "--nictype1", "virtio"]
          v.customize ["modifyvm", :id, "--nictype2", "virtio"]
        end

        node.vm.provision "base",    type: "shell", inline: SCRIPT_BASE_SETUP,  args: [HOSTS_ENTRIES, SSH_PUB_KEY_CONTENT, UTILITY_PACKAGES]
        node.vm.provision "file",    source: SSH_PRIVATE_KEY, destination: "/tmp/cluster_id_rsa"
        node.vm.provision "sshkey",  type: "shell", inline: SCRIPT_SSH_PRIVKEY
        node.vm.provision "k8s_pre", type: "shell", inline: SCRIPT_K8S_PREREQS, args: [K8S_VERSION, CRI_DOCKERD_VERSION, wip]
        node.vm.provision "worker",  type: "shell", inline: SCRIPT_WORKER_JOIN, args: [cluster_name, api_endpoint]
      end
    end
  end

  # =========================================================================
  #  POST-UP TRIGGER
  # =========================================================================
  config.trigger.after :up do |trigger|
    trigger.only_on = all_vm_names.last
    trigger.name    = "Post-Up Summary"
    trigger.info    = "Running post-up tasks: SSH key verification and cluster access info..."
    trigger.ruby do |_env, machine|
      puts ""
      puts "=" * 70
      puts "  POST-UP: SSH KEY DISTRIBUTION"
      puts "=" * 70
      puts ""
      puts "  Shared SSH key pair location:"
      puts "    Private key : #{SSH_PRIVATE_KEY}"
      puts "    Public key  : #{SSH_PUBLIC_KEY}"
      puts ""
      puts "  The shared SSH key has been distributed to ALL VMs."
      puts "  Every VM can SSH into every other VM (within and across clusters):"
      puts "    vagrant ssh <vm-name>            # SSH from host"
      puts "    ssh vagrant@<ip-or-hostname>     # SSH between VMs"
      puts ""

      ALL_CLUSTERS_DECLARATION.each do |cname, cfg|
        s  = cfg[:base_subnet]
        mc = cfg[:master_count]
        wc = cfg[:worker_count]

        puts "-" * 70
        puts "  CLUSTER: #{cname}  (context: #{cname})"
        puts "-" * 70

        puts ""
        puts "  Nodes:"
        if mc > 1
          puts "    LB       : #{lb_ip(s)} (#{cname}-lb)"
        end
        (1..mc).each do |i|
          name = mc == 1 ? "#{cname}-master" : "#{cname}-master#{i}"
          puts "    Master   : #{node_ip(s,'master',i)} (#{name})"
        end
        (1..wc).each do |i|
          name = wc == 1 ? "#{cname}-worker" : "#{cname}-worker#{i}"
          puts "    Worker   : #{node_ip(s,'worker',i)} (#{name})"
        end

        master1 = mc == 1 ? "#{cname}-master" : "#{cname}-master1"
        puts ""
        puts "  Kubernetes Context:"
        puts "    Context name: #{cname}"
        puts "    Switch context: kubectl config use-context #{cname}"
        puts ""
        puts "  Headlamp Dashboard:"
        puts "    To find the external IP:"
        puts "      vagrant ssh #{master1} -c 'kubectl get svc -n headlamp'"
        puts "    Then open: http://<EXTERNAL-IP>/ in your browser."
        puts "    To create an access token:"
        puts "      vagrant ssh #{master1} -c 'kubectl create token headlamp --namespace headlamp'"
        puts ""

        if mc > 1
          puts "  HAProxy Stats (HA cluster):"
          puts "    URL: http://#{lb_ip(s)}:8404/stats"
          puts ""
        end
      end

      puts "=" * 70
      puts "  ALL CLUSTERS DEPLOYED SUCCESSFULLY - Happy Cluster-ing! :)"
      puts "=" * 70
      puts ""
    end
  end
end
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# END OF VAGRANTFILE
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
