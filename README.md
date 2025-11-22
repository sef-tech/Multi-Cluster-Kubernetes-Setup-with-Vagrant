# Multi-Cluster-Kubernetes-Setup-with-Vagrant

A comprehensive production-ready, scalable Kubernetes multi-cluster setup using Vagrant, VirtualBox, and Calico CNI. Supports high-availability configurations with multiple master nodes, HAProxy + Keepalived load balancing, MetalLB for service load balancing, and passwordless SSH between nodes with continuous key synchronization.

## 📋 Table of Contents

- [Features](#-features)
- [Architecture](#-architecture)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [Configuration](#-configuration)
- [Usage](#-usage)
- [Cluster Management](#-cluster-management)
- [Networking](#-networking)
- [Troubleshooting](#-troubleshooting)
- [Advanced Usage](#-advanced-usage)

## ✨ Features

### Multi-Cluster Support
- **Multiple Isolated Clusters**: Run prod, qa, dev, or any custom-named clusters simultaneously
- **Independent Configuration**: Each cluster has its own network, resources, and configuration
- **Merged Kubeconfig**: Single kubeconfig file to access all clusters with easy context switching

### High Availability
- **Multi-Master Support**: Configure 1-n master nodes per cluster
- **HAProxy + Keepalived Load Balancer**: Automatic HA setup when master_count > 1
- **Virtual IP (VIP)**: Keepalived manages a floating VIP for API server access
- **Automatic Failover**: API server requests distributed across master nodes with health checks
- **Conditional LB Creation**: Load balancer VMs are only created when you have multiple masters

### Scalability
- **Flexible Worker Nodes**: Configure 1-n worker nodes per cluster
- **Resource Control**: Customize CPU and memory for each node type
- **Flexible Configuration & Easy Scaling**: Add/remove nodes by updating Vagrantfile or using the `cluster-scaler.sh` script

### Networking
- **Calico CNI**: Production-grade container networking with network policies
- **MetalLB**: Layer 2 load balancing for bare-metal Kubernetes services
- **Custom Pod Networks**: Separate CIDR ranges for each cluster (10.244.0.0/16 for prod, 10.245.0.0/16 for qa, 10.246.0.0/16 for dev)
- **Passwordless SSH**: Pre-configured SSH keys with continuous background synchronization (every 3 seconds)
- **Dynamic Interface Detection**: Auto-detects private network interfaces (eth1, enp0s8, etc.)
- **Centralized IP Management**: IP_OFFSETS configuration for consistent IP addressing across clusters

### Container Runtime
- **Docker + cri-dockerd**: Modern Docker integration with Kubernetes
- **SystemD CGroups**: Proper resource management
- **CNI Integration**: Fully integrated with Calico networking

### SSH and Networking Architecture
- **Progressive Key Distribution**: Each VM generates SSH keys during provisioning and shares them via /vagrant/.vagrant/ssh-keys/
- **Continuous Background Sync**: A background process on each node checks for new keys every 3 seconds and imports them automatically
- **Post-Up Trigger**: After all VMs are provisioned, a final SSH key distribution ensures all nodes can communicate
- **No Prompts**: StrictHostKeyChecking disabled, no password or "yes/no" prompts
- **DNS Configuration**: systemd-resolved disabled to prevent DNS conflicts; uses static DNS (8.8.8.8, 8.8.4.4)

## 🏗️ Architecture

### Provisioning Flow

The Vagrantfile follows this provisioning sequence for each cluster:

1. **Load Balancer (if master_count > 1)**:
   - Base system setup (DNS, utilities, network interfaces)
   - HAProxy installation and configuration
   - Keepalived installation for VIP management

2. **Primary Master (first master node)**:
   - Base setup (Docker, kubelet, kubeadm, kubectl)
   - Network interface auto-detection
   - Kubernetes cluster initialization with `kubeadm init`
   - Calico CNI deployment
   - Generate join commands for secondary masters and workers
   - Configure kubectl context with cluster name

3. **Secondary Masters (if master_count > 1)**:
   - Base setup
   - Wait for primary master initialization
   - Retrieve join command via SSH
   - Validate API server accessibility
   - Join cluster as control plane node

4. **Worker Nodes**:
   - Base setup
   - Wait for primary master initialization
   - Retrieve join command via SSH
   - Validate API server accessibility
   - Join cluster as worker node

5. **Post-Deployment (on last worker)**:
   - Wait for all nodes to be ready
   - Deploy and configure MetalLB
   - Verify cluster health

6. **Post-Up Trigger (after all VMs)**:
   - Final SSH key distribution to all nodes
   - Verification and status report

### Default Cluster Layout

```
┌─────────────────────────────────────────────────────────────────┐
│                        PROD CLUSTER                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│           ┌──────────────┐       ┌──────────────┐               │
│           │ prod-master1 │       │ prod-master2 │               │
│           │ 192.168.56.10│       │ 192.168.56.11│               │
│           │ 4GB / 2 CPU  │       │ 4GB / 2 CPU  │               │
│           └──────┬───────┘       └──────┬───────┘               │
│                  │                      │                       │
│                  └──────────┬───────────┘                       │
│                             │                                   │
│                    ┌────────▼────────┐                          │
│                    │   prod-lb       │ (HAProxy)                │
│                    │ 192.168.56.100  │                          │
│                    │  512MB / 1 CPU  │                          │
│                    └────────┬────────┘                          │
│                             │                                   │
│             ┌───────────────┼───────────┬───────────┐           │
│             │               │           │           │           │
│      ┌──────▼────────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐      │
│      │  prod-worker1 │ │ worker2 │ │ worker3 │ │ worker4 │      │
│      │ 192.168.56.20 │ │   .21   │ │   .22   │ │  .23    │      │
│      │   1GB/1CPU    │ │1GB/1CPU │ │1GB/1CPU │ │1GB/1CPU │      │
│      └───────────────┘ └─────────┘ └─────────┘ └─────────┘      │
│                                                                 │
│  Pod Network: 10.244.0.0/16                                     │
│  MetalLB Range: 192.168.56.200-210                              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                          QA CLUSTER                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│           ┌──────────────┐       ┌──────────────┐               │
│           │  qa-master1  │       │  qa-master2  │               │
│           │ 192.168.56.30│       │ 192.168.56.31│               │
│           │    4GB/2CPU  │       │    4GB/2CPU  │               │
│           └──────┬───────┘       └──────┬───────┘               │
│                  │                      │                       │
│                  └──────────┬───────────┘                       │
│                             │                                   │
│                    ┌────────▼────────┐                          │
│                    │     prod-lb     │ (HAProxy)                │
│                    │ 192.168.56.101  │                          │
│                    │    512MB/1CPU   │                          │
│                    └────────┬────────┘                          │
│                             │                                   │
│             ┌───────────────┼───────────┬───────────┐           │
│             │               │           │           │           │
│      ┌──────▼────────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐      │
│      │  prod-worker1 │ │ worker2 │ │ worker3 │ │ worker4 │      │
│      │ 192.168.56.40 │ │   .41   │ │   .42   │ │  .43    │      │
│      │   1GB/1CPU    │ │1GB/1CPU │ │1GB/1CPU │ │1GB/1CPU │      │
│      └───────────────┘ └─────────┘ └─────────┘ └─────────┘      │
│                                                                 │
│  Pod Network: 10.245.0.0/16                                     │
│  MetalLB Range: 192.168.56.220-230                              │
└─────────────────────────────────────────────────────────────────┘

|   Cluster  |   Masters |    Workers    |  Pod Network CIDR  |  MetalLB Range | 
|------------|-----------|---------------|--------------------|----------------|
|  k8s-prod  |   2 | 2   | 10.244.0.0/16 | 192.168.56.200-210 | 192.168.56.100 |
|   k8s-qa   |   2 | 2   | 10.245.0.0/16 | 192.168.56.220-230 | 192.168.56.101 |
|   k8s-dev  |   2 | 2   | 10.246.0.0/16 | 192.168.56.240-250 | 192.168.56.102 |
```

## 📦 Prerequisites

### Required Software [Install on Host Machine]
- **Operating System**: Windows 10/11, macOS, or Linux
- **Chocolatey**: Latest version
- **VirtualBox**: 6.1+ or 7.0+
- **Vagrant**: 2.3.0+
- **kubectl**: Latest version (for cluster management)

### Other Software [Install on Host Machine]
- **kubens kubectx**
- **k9s**
- **kustomize**
- **kubernetes-helm**
- **kubernetes-cli**
- **terraform**
- **starship**
- **git**

### System Requirements
**Minimum** (Single Master per Cluster):
- CPU: 8 cores
- RAM: 16 GB
- Disk: 50 GB free space

**Recommended** (HA Setup with Multiple Masters):
- CPU: 12+ cores
- RAM: 24+ GB
- Disk: 100 GB free space

### Installation

```bash
# Chocolatey
- Install chocolatey CLI from https://docs.chocolatey.org/en-us/choco/setup using Powershell or CMD.
- Chocolatey is the package manager for Windows (like apt-get for Ubuntu and Brew for MacOS)
```

```bash
# Install VirtualBox
Windows: Download from https://www.virtualbox.org/ or choco install virtualbox --version=7.2.2 -y
macOS: brew install virtualbox
Linux: sudo apt install virtualbox
```
```bash
# Install Vagrant
Windows: Download from https://www.vagrantup.com/ or choco install vagrant --version=2.4.9 -y
macOS: brew install vagrant
Linux: sudo apt install vagrant
```

```bash
# =============================================================================================
# Note: The following section is for Windows users using Chocolatey and Scoop package managers.
# If you're on Linux, you can ignore this section.
# =============================================================================================

# Install Chocolatey from https://docs.chocolatey.org/en-us/choco/setup/

# choco install kubernetes-cli -y
# choco install kubens kubectx -y
# choco install k9s -y
# choco install kustomize -y
# choco install kubernetes-helm -y
# choco install terraform -y
# choco install starship -y
# choco install git -y

# # Install Scoop and use it to install helmfile
#     # Set execution policy
#       Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#
#     # Install Scoop
#       Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
#
# scoop install helmfile
# =============================================================================================
# End of Windows installation section
# =============================================================================================
```

## 🚀 Quick Start

### 1. Clone and Setup

```bash
# Clone the repository
git clone <your-repo-url>
cd k8s-multi-cluster

# Review and customize Vagrantfile (optional)
vim Vagrantfile or nano Vagrantfile
```

### 2. Start the Clusters

```bash
# Start all clusters based on the customized Vagrantfile (prod, qa, dev...)
vagrant up

# Or start specific cluster
vagrant up /prod/
vagrant up /qa/
```

**Note**: Initial setup takes 15-30 minutes per cluster depending on your internet speed.

### 3. Configure kubectl Access

```bash
# Ensure the kubeconfig-setup.sh is in the same directory as the Vagrantfile and run the script.
chmod +x kubeconfig-setup.sh
./kubeconfig-setup.sh

# Set the merged kubeconfig to merge to ~/.kube/config
export KUBECONFIG="/c/Users/forsa/.kube/config"

# To make it permanent, export into `bashrc`
'export KUBECONFIG="/c/Users/forsa/.kube/config"' >> ~/.bashrc

# If unable to still access the cluster after all the above
`source ~/.bashrc`
`source ~/.bashrc_profile`

# Verify the config
kubectl config view

# Verify access
kubectl config get-contexts

# Test connectivity
kubectl config use-context prod
kubectl get nodes

kubectl config use-context qa
kubectl get nodes
```

### 4. Verify Installation

```bash
# Check all nodes in prod cluster
kubectl config use-context prod
kubectl get nodes -o wide

# Check all pods
kubectl get pods -A

# Test MetalLB (deploy a LoadBalancer service)
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --type=LoadBalancer --port=80
kubectl get svc nginx
```

## ⚙️ Configuration

### Vagrantfile Cluster Configuration

The `ALL_CLUSTERS_DECLARATION` hash in the Vagrantfile defines all cluster configurations. This is the primary place to configure your clusters:

```ruby
ALL_CLUSTERS_DECLARATION = {
  "k8s-prod" => {
    base_subnet: "192.168.51",                      # Base subnet for this cluster
    master_count: 2,                                # Number of master nodes (LB created if > 1)
    worker_count: 8,                                # Number of worker nodes
    master_cpus: 2,                                 # CPU cores per master
    master_memory: 4096,                            # RAM per master (MB)
    worker_cpus: 1,                                 # CPU cores per worker
    worker_memory: 1024,                            # RAM per worker (MB)
    metallb_ip_range: "192.168.51.200/27",          # MetalLB IP pool
    context_name: "prod"                            # Kubectl context name
  },
  "k8s-qa" => {
    # Similar configuration for QA cluster
  }
}
```

### IP Offset Configuration

The Vagrantfile uses a centralized `IP_OFFSETS` hash to manage IP addressing consistently:

```ruby
IP_OFFSETS = {
  'lb_vip'  => 10,            # Virtual IP for Keepalived (e.g., 192.168.51.10)
  'lb'      => 20,            # Load balancer VM IP (e.g., 192.168.51.20)
  'master'  => { 1 => 11, 2 => 12, 3 => 13, ... },      # Master node IPs
  'worker'  => { 1 => 21, 2 => 22, 3 => 23, ... }       # Worker node IPs
}
```

This ensures:
- **Consistent addressing**: Each cluster follows the same IP pattern
- **No IP conflicts**: Masters and workers have separate IP ranges
- **Easy scaling**: Add more nodes without manual IP calculation

### Adding a New Cluster

```ruby
CLUSTERS = {
  # ... existing clusters ...
  
  "k8s-dev" => {
    base_subnet: "192.168.53",
    master_count: 2,
    worker_count: 2,
    master_cpus: 2,
    master_memory: 3072,
    worker_cpus: 1, 
    worker_memory: 1024,
    metallb_ip_range: "192.168.53.200/27",
    context_name: "dev"
  }
}
```

### Version Configuration

Update software versions at the top of Vagrantfile:

```ruby
K8S_VERSION           = "1.32"                  # Kubernetes version     - Check latest version: https://github.com/kubernetes/kubernetes/releases
CRI_DOCKERD_VERSION   = "v0.3.21"               # cri-dockerd version    - Check latest version: https://github.com/Mirantis/cri-dockerd
CALICO_VERSION        = "v3.31.2"               # Calico CNI version     - Check latest version: https://github.com/projectcalico/calico/releases
METALLB_VERSION       = "v0.15.2"               # MetalLB version        - Check latest version: https://github.com/metallb/metallb/releases
BOX_IMAGE             = "bento/ubuntu-24.04"    # Box VM image           - Boxes Repo: https://portal.cloud.hashicorp.com/vagrant/discover
BOX_VERSION           = "202510.26.0"           # Box VM image version
```

### Load Balancer Hardware Configuration

Configure the load balancer VM resources (applies to all clusters):

```ruby
LB_CPUS    = 1      # CPU cores for load balancer VM
LB_MEMORY  = 512    # RAM for load balancer VM (MB) - minimum 1024 for Ubuntu 24.04
```

**Important**: Load balancer VMs are only created when `master_count > 1` for a cluster.

### Automated Post-Deployment

The Vagrantfile includes automated post-deployment tasks:

1. **MetalLB Installation**: Automatically deployed on the last worker node of each cluster
2. **MetalLB Configuration**: IP address pool and L2 advertisement configured based on `metallb_ip_range`
3. **Webhook Validation**: Waits for MetalLB webhooks to be ready before applying configuration
4. **Retry Logic**: Built-in retry mechanisms for network operations to handle transient failures
5. **Cluster Validation**: Verifies all nodes are ready before proceeding with post-deployment tasks

## 📘 Usage

### Basic kubectl Commands

```bash
# List all contexts
kubectl config get-contexts

# Switch to prod cluster
kubectl config use-context prod

# Switch to qa cluster
kubectl config use-context qa

# Get nodes in current context
kubectl get nodes

# Get all resources
kubectl get all -A

# Deploy application
kubectl create deployment myapp --image=nginx
kubectl expose deployment myapp --type=LoadBalancer --port=80

# Check load balancer IP (MetalLB)
kubectl get svc myapp
```

### Kubeconfig Management

```bash
# Run kubeconfig-setup merger (after cluster changes). This fetches all kubeconfigs and merge them into "~/.kube/config"
./kubeconfig-setup.sh fetch

# Make kubeconfig permanent
echo 'export KUBECONFIG="'$(pwd)'/kubeconfigs/merged-config"' >> ~/.bashrc
source ~/.bashrc
```

### Accessing Individual Cluster Configs

```bash
# Use individual cluster config
export KUBECONFIG="$(pwd)/kubeconfigs/prod-config"
kubectl get nodes

# Use specific config for one command
kubectl --kubeconfig=kubeconfigs/qa-config get nodes
```

## 🔧 Cluster Management

### Starting Clusters

```bash
# Start all clusters
vagrant up

# Start specific cluster
vagrant up /prod/

# Start specific VMs
vagrant up prod-master1 prod-worker1
```

### Stopping Clusters

```bash
# Stop all VMs
vagrant halt

# Stop specific cluster
vagrant halt /prod/

# Stop specific VM
vagrant halt prod-master1
```

### Restarting Clusters

```bash
# Restart all
vagrant reload

# Restart specific cluster
vagrant reload /prod/

# Restart with re-provisioning
vagrant reload --provision prod-master1
```

### Destroying Clusters

```bash
# Destroy all (caution: data loss!)
vagrant destroy -f

# Destroy specific cluster
vagrant destroy -f /prod/

# Destroy specific VM
vagrant destroy -f prod-worker1
```

### SSH Access

```bash
# SSH into any VM
vagrant ssh prod-master1
vagrant ssh qa-worker2

# Run command on VM
vagrant ssh prod-master1 -c "kubectl get nodes"

# SSH between VMs (passwordless configured)
vagrant ssh prod-master1
ssh vagrant@192.168.56.21  # From master to worker
```

### Scaling Clusters

#### Adding Worker Nodes

1. Update `worker_count` in Vagrantfile
2. Run `vagrant up` to create new workers
3. Workers automatically join the cluster

```ruby
"prod" => {
  # ... other settings ...
  worker_count: 5,  # Increased from 3 to 5
}
```

```bash
vagrant up prod-worker4 prod-worker5
```

#### Adding Master Nodes (HA)

1. Update `master_count` in Vagrantfile
2. Ensure `setup_load_balancer: true`
3. Run `vagrant up` to create new masters

```ruby
"prod" => {
  # ... other settings ...
  master_count: 3,  # Increased from 2 to 3
  setup_load_balancer: true,
}
```

```bash
vagrant up prod-master3
```

## 🌐 Networking

### Network Ranges

| Component       | Prod Cluster       | QA Cluster         | Purpose          |
|-----------------|--------------------|--------------------|------------------|
| Master Nodes    | 192.168.56.10-19   | 192.168.56.30-39   | Control plane    |
| Worker Nodes    | 192.168.56.20-29   | 192.168.56.40-49   | Workloads        |
| Load Balancer   | 192.168.56.100     | 192.168.56.101     | HA API access    |
| Pod Network     | 10.244.0.0/16      | 10.245.0.0/16      | Pod IPs          |
| Service Network | 10.96.0.0/12       | 10.96.0.0/12       | Service IPs      |
| MetalLB Pool    | 192.168.56.200-210 | 192.168.56.220-230 | LoadBalancer IPs |

### Accessing Services

#### From Host Machine

```bash
# Get LoadBalancer IP
kubectl get svc myapp

# Access service
curl http://<METALLB_IP>
```

#### From Other VMs

All VMs can access services using LoadBalancer IPs or NodePorts.

### Pod Network CIDRs

Each cluster has its own pod network CIDR to ensure isolation:

| Cluster   | Pod Network CIDR | Purpose             |
|-----------|------------------|---------------------|
| k8s-prod  | 10.244.0.0/16    | Production pod IPs  |
| k8s-qa    | 10.245.0.0/16    | QA/Testing pod IPs  |
| k8s-dev   | 10.246.0.0/16    | Development pod IPs |

These are automatically configured during cluster initialization in the `MASTER_INIT_SCRIPT`.

### HAProxy Stats

When using HA mode (multiple masters), HAProxy provides real-time statistics:

```bash
# Access HAProxy statistics page
# URL: http://<LOAD_BALANCER_IP>:8080/stats
# Prod: http://192.168.56.101:8080/stats
# QA: http://192.168.52.20:8080/stats
# Credentials: admin/admin (if configured)
```

The statistics page shows:
- Active/backup master nodes
- Health check status for each API server
- Request distribution and load balancing
- Session information and response times

**Note**: Load balancer VMs and HAProxy are only created when `master_count > 1` for a cluster.

### Virtual IP (VIP) and Keepalived

For high-availability clusters, Keepalived manages a Virtual IP (VIP) that provides:

- **Floating IP**: The VIP (e.g., 192.168.51.10) floats between load balancer nodes
- **Automatic Failover**: If the primary LB fails, the VIP moves to a backup LB
- **API Endpoint**: Kubernetes API is accessed via the VIP, not individual master IPs
- **VRRP Protocol**: Uses Virtual Router Redundancy Protocol for health checks

The VIP is configured at offset 10 from the base subnet:
- Prod: 192.168.51.10
- QA: 192.168.52.10
- Dev: 192.168.53.10

When you initialize a cluster with multiple masters, the `--control-plane-endpoint` is set to the VIP, ensuring all API requests go through the load balancer.

### Port Forwarding Example

```bash
# Forward pod port to localhost
kubectl port-forward pod/mypod 8080:80

# Forward service port
kubectl port-forward svc/myservice 8080:80
```

## 🔍 Troubleshooting

### Common Issues

#### 1. Network Interface Detection Issues

If VMs fail during network setup:

```bash
# Check which interfaces are available
vagrant ssh prod-master1 -c "ip addr show"

# Check if the correct IP is assigned
vagrant ssh prod-master1 -c "ip addr show | grep 192.168"

# The Vagrantfile auto-detects eth1, enp0s8, or other private interfaces
# If detection fails, check VirtualBox network adapter settings
```

The Vagrantfile automatically detects private network interfaces by:
- Searching for interfaces with the assigned IP
- Falling back to interfaces in the 192.168.x.x subnet
- Waiting up to 60 seconds for IP assignment
- Attempting manual configuration if auto-config fails

#### 2. API Server Not Responding

```bash
# Check API server status
vagrant ssh prod-master1 -c "sudo systemctl status kube-apiserver"

# Check kubelet logs
vagrant ssh prod-master1 -c "sudo journalctl -u kubelet -n 100"

# Restart cluster
vagrant reload prod-master1 --provision
```

#### 3. Nodes Not Ready

```bash
# Check node status
kubectl get nodes -o wide
kubectl describe node prod-worker1

# Check kubelet on worker
vagrant ssh prod-worker1 -c "sudo systemctl status kubelet"

# Check CNI pods
kubectl get pods -n calico-system
kubectl get pods -n kube-system
```

#### 4. Pods Not Starting

```bash
# Check pod status
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>

# Check events
kubectl get events -A --sort-by='.lastTimestamp'

# Check Calico
kubectl get pods -n calico-system
kubectl logs -n calico-system <calico-pod>
```

#### 5. Workers Can't Join Cluster

```bash
# Check join command exists
ls -la /vagrant/*-join-command.sh

# Check master ready file
ls -la /vagrant/*-master1-ready

# Regenerate join command on master
vagrant ssh prod-master1
sudo kubeadm token create --print-join-command

# Manually join worker
vagrant ssh prod-worker1
sudo kubeadm reset -f
# Run join command with --cri-socket=unix:///var/run/cri-dockerd.sock
```

#### 6. LoadBalancer Services Stuck in Pending

```bash
# Check MetalLB installation
kubectl get pods -n metallb-system

# Check MetalLB configuration
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system

# Check logs
kubectl logs -n metallb-system -l app=metallb
```

#### 7. SSH Connectivity Issues

If nodes can't SSH to each other:

```bash
# Check if SSH keys are generated
vagrant ssh prod-master1 -c "ls -la ~/.ssh/"

# Check if keys are in shared directory
ls -la .vagrant/ssh-keys/

# Verify authorized_keys contains keys
vagrant ssh prod-master1 -c "cat ~/.ssh/authorized_keys | wc -l"

# Check if SSH key sync process is running
vagrant ssh prod-master1 -c "ps aux | grep ssh-key-sync"

# Test SSH between nodes
vagrant ssh prod-master1 -c "ssh vagrant@prod-worker1 'echo success'"
```

The continuous SSH key sync process should automatically import new keys every 3 seconds. If it's not running, the post-up trigger will ensure final distribution.

#### 8. kubeconfig-setup.sh Fails

```bash
# Run with verbose output
./kubeconfig-setup.sh -v

# Check API servers manually
curl -k https://192.168.56.10:6443/healthz
curl -k https://192.168.56.30:6443/healthz

# Skip validation
./kubeconfig-setup.sh -s
```

### Viewing Logs

```bash
# Kubelet logs
vagrant ssh prod-master1 -c "sudo journalctl -u kubelet -f"

# Container runtime logs
vagrant ssh prod-worker1 -c "sudo journalctl -u cri-docker -f"

# HAProxy logs
vagrant ssh prod-lb -c "sudo journalctl -u haproxy -f"

# Pod logs
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous  # Previous container
```

### Reset Cluster

```bash
# Reset specific node
vagrant ssh prod-worker1
sudo kubeadm reset -f --cri-socket=unix:///var/run/cri-dockerd.sock
sudo reboot

# Destroy and recreate
vagrant destroy -f prod-worker1
vagrant up prod-worker1
```

## 🚀 Advanced Usage

### Deploy Sample Application

```bash
# Switch to prod cluster
kubectl config use-context prod

# Create namespace
kubectl create namespace demo

# Deploy application
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  namespace: demo
  labels:
    app: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      # nodeName: prod-control-plane
      containers:
        - name: nginx
          image: nginx:latest
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 80
          #   initialDelaySeconds: 10
          #   periodSeconds: 20
          # resources:
          #   requests:
          #     cpu: "50m"
          #     memory: "64Mi"
          #   limits:
          #     cpu: "250m"
          #     memory: "128Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
  namespace: demo
  labels:
    app: nginx
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
    - name: http
      port: 80
      # targetPort: 80
      # nodePort: 30000
EOF

# Check deployment
kubectl get all -n demo

# Get LoadBalancer IP
kubectl get svc nginx-service -n demo

# Test service
curl http://<LOADBALANCER_IP>
```

### Testing HA Failover

```bash
# Get current API server
kubectl config use-context prod
kubectl cluster-info

# Shutdown one master
vagrant halt prod-master1

# Verify cluster still works
kubectl get nodes

# Check HAProxy stats
curl http://192.168.56.100:8080/stats

# Bring master back up
vagrant up prod-master1
```

### Network Policy Example

```bash
# Create network policy
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: demo
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Allow specific traffic
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-nginx
  namespace: demo
spec:
  podSelector:
    matchLabels:
      app: nginx
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}
    ports:
    - protocol: TCP
      port: 80
EOF
```
### Monitoring Setup

```bash
# Metrics Server Deployment Manifest for Kubernetes (Apply the official manifest):
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# If your cluster uses self-signed certificates or has other TLS issues, you may need to modify the Metrics Server deployment to 
# allow insecure TLS connections to the kubelet.
# Patch the deployment to add the --kubelet-insecure-tls argument as shown below.
    kubectl patch deployment metrics-server -n kube-system \
      --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--kubelet-insecure-tls"}]'

# Verify Metrics Server is working correctly:
    kubectl top nodes
    kubectl top pods -A
    kubectl get pods -n kube-system | grep metrics-server
    kubectl get deployment metrics-server -n kube-system
    kubectl get apiservice v1beta1.metrics.k8s.io -o yaml
    kubectl -n kube-system edit deployment metrics-server
```

### Backup and Restore

```bash
# Backup etcd (on master)
vagrant ssh prod-master1
sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Copy backup to host
sudo cp /tmp/etcd-backup.db /vagrant/

# Restore (if needed)
# Follow Kubernetes etcd restore documentation
```

## 📝 Files Overview

```
.
├── Vagrantfile                    # Main cluster configuration
├── kubeconfig-setup.sh            # Kubeconfig merger script
├── cluster-scaler.sh              # Cluster scaler script
├── k8s-upgrade.sh                 # K8S upgrade script
└── README.md
```

## 🤝 Contributing

Feel free to submit issues and enhancement requests!

## 📄 License

This project is provided as-is for educational and development purposes.

## 🙏 Acknowledgments

- Kubernetes community
- Calico Project
- MetalLB Project
- HashiCorp Vagrant
- Bento Project (for Ubuntu boxes)

---

**Happy Clustering! 🚀**
