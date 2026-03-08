# Multi-Cluster Kubernetes Setup with Passwordless SSH

**For Development, Testing, and Learning Purposes Only**

A production-like multi-cluster Kubernetes environment built with Vagrant and VirtualBox. This project provisions multiple independent, high-availability Kubernetes clusters - each with its own control plane, worker nodes, and (optionally) an HAProxy load balancer - all wired together with passwordless SSH.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Default Cluster Layout](#default-cluster-layout)
4. [Prerequisites](#prerequisites)
5. [Quick Start](#quick-start)
6. [Cluster Definitions](#cluster-definitions)
7. [IP Addressing Scheme](#ip-addressing-scheme)
8. [Component Stack](#component-stack)
9. [Provisioning Flow](#provisioning-flow)
10. [Version Management](#version-management)
11. [Day-to-Day Operations](#day-to-day-operations)
12. [Accessing the Kubernetes Dashboard (Headlamp)](#accessing-the-kubernetes-dashboard-headlamp)
13. [HAProxy Stats Page](#haproxy-stats-page)
14. [SSH Between VMs](#ssh-between-vms)
15. [Kubeconfig Setup (Host-Side)](#kubeconfig-setup-host-side)
16. [Adding or Removing Clusters](#adding-or-removing-clusters)
17. [Changing the Base Box](#changing-the-base-box)
18. [Synced Folder Modes](#synced-folder-modes)
19. [Idempotency Guarantees](#idempotency-guarantees)
20. [Resource Planning](#resource-planning)
21. [File Structure](#file-structure)
22. [Reference: Vagrant Commands](#reference-vagrant-commands)

---

## Overview

This Vagrantfile creates one or more fully independent Kubernetes clusters, each containing:

- **Master nodes** (1–13 per cluster) running the Kubernetes control plane.
- **Worker nodes** (1–13 per cluster) for scheduling workloads.
- **HAProxy load balancer** (automatically created when a cluster has more than one master) to distribute API-server traffic across masters.
- **Calico CNI** for pod networking and network policy enforcement.
- **MetalLB** in Layer 2 mode, giving every cluster real `LoadBalancer`-type service IPs.
- **Headlamp** (the official kubernetes-sigs successor to the archived kubernetes-dashboard), deployed via Helm with a `LoadBalancer` service.
- **Metrics Server** for `kubectl top` and HPA support, with configurable replica count.
- **Passwordless SSH** between every VM - within and across clusters - using a shared key pair generated on the host and distributed during provisioning.

All provisioning scripts are idempotent: running `vagrant up` or `vagrant provision` multiple times is safe.

---

## Architecture

### Single-Master Cluster (e.g. qa, dev)

```
 Host Machine
 │
 └─ VirtualBox
     │
     ├─ k8s-qa-master   (192.168.52.11)   Control plane + kubectl
     ├─ k8s-qa-worker1  (192.168.52.21)   Workload node
     └─ k8s-qa-worker2  (192.168.52.22)   Workload node
```

Workers join the master directly via `192.168.52.11:6443`.

### Multi-Master (HA) Cluster (e.g. prod)

```
 Host Machine
 │
 └─ VirtualBox
     │
     ├─ k8s-prod-lb       (192.168.54.20)   HAProxy → round-robin to masters
     ├─ k8s-prod-master1   (192.168.54.11)   Control plane (primary init)
     ├─ k8s-prod-master2   (192.168.54.12)   Control plane (joined)
     ├─ k8s-prod-master3   (192.168.54.13)   Control plane (joined)
     ├─ k8s-prod-worker1   (192.168.54.21)   Workload node
     ├─ k8s-prod-worker2   (192.168.54.22)   Workload node
     └─ k8s-prod-worker3   (192.168.54.23)   Workload node
```

All masters and workers connect to `192.168.54.20:6443` (the LB). HAProxy health-checks each master and removes unhealthy backends automatically.

### Shared Pod Network

All clusters share the pod CIDR `10.244.0.0/16`. Because each cluster runs its own isolated Calico instance inside its own VirtualBox private network, there is no conflict. Clusters cannot route pod traffic to each other - they are fully independent.

### Cross-Cluster SSH

Every VM carries the same SSH key pair. This means any VM can `ssh vagrant@<ip>` to any other VM - even across clusters - without a password prompt.

---

## Default Cluster Layout

The Vagrantfile ships with five clusters enabled by default:

| Cluster | Subnet | Masters | Workers | LB | MetalLB Range | Context |
|---------|--------|---------|---------|-----|---------------|---------|
| k8s-dr | 192.168.55.x | 2 | 2 | Yes | 192.168.55.200/27 | `k8s-dr` |
| k8s-prod | 192.168.54.x | 3 | 3 | Yes | 192.168.54.200/27 | `k8s-prod` |
| k8s-pre-prod | 192.168.53.x | 1 | 3 | No | 192.168.53.200/27 | `k8s-pre-prod` |
| k8s-qa | 192.168.52.x | 1 | 2 | No | 192.168.52.200/27 | `k8s-qa` |
| k8s-dev | 192.168.51.x | 1 | 2 | No | 192.168.51.200/27 | `k8s-dev` |

Total VMs when all five clusters are active: **22** (2 LBs + 8 masters + 12 workers).

To reduce resource consumption, comment out clusters you don't need in `ALL_CLUSTERS_DECLARATION`.

---

## Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| VirtualBox | 7.0+ | Latest stable |
| Vagrant | 2.4+ | Latest stable |
| Host CPU | 8 cores | 16+ cores |
| Host RAM | 16 GB | 32–64 GB |
| Free Disk | 50 GB | 100+ GB |

Download links: [VirtualBox](https://www.virtualbox.org/wiki/Downloads) - [Vagrant](https://www.vagrantup.com/downloads)

If you only enable one or two clusters, the requirements drop significantly. A single-master, two-worker cluster needs roughly 2 CPU cores and 6 GB RAM.

---

## Quick Start

**Step 1 - Clone and enter the project directory.**

```bash
cd /path/to/project
```

**Step 2 - (Optional) Trim clusters to fit your hardware.**

Open the `Vagrantfile` and comment out any clusters you don't need in the `ALL_CLUSTERS_DECLARATION` hash. For a first run, keeping only `k8s-dev` (1 master + 2 workers ≈ 6 GB RAM) is a good starting point.

**Step 3 - Bring everything up.**

```bash
vagrant up
```

Vagrant will download the base box on first run (≈1 GB), then provision each VM in the order: LB → masters → workers, cluster by cluster. The first master of each cluster installs all cluster-level components (Calico, MetalLB, Helm, Headlamp, Metrics Server).

**Step 4 - Verify.**

```bash
vagrant ssh k8s-dev-master
kubectl get nodes -o wide
kubectl get pods --all-namespaces
```

You should see all nodes in `Ready` state and all pods `Running`.

**Step 5 - Access the dashboard.**

```bash
# Find the external IP assigned by MetalLB
kubectl get svc -n headlamp

# Create a login token
kubectl create token headlamp --namespace headlamp
```

Open `http://<EXTERNAL-IP>/` in your browser and paste the token.

**Step 6 - (Optional) Enable kubectl from the host.**

If you want to run `kubectl` directly from your host machine (without `vagrant ssh` first), use the included helper script:

```bash
chmod +x kubeconfig-setup.sh
./kubeconfig-setup.sh fetch
```

This fetches kubeconfigs from every running cluster, merges them into `~/.kube/config`, fixes TLS certificate issues, and sets up named contexts. Afterwards you can switch clusters with `kubectl config use-context prod` and run commands directly from the host. See [Kubeconfig Setup (Host-Side)](#kubeconfig-setup-host-side) for full details.

---

## Cluster Definitions

Each cluster is defined in the `ALL_CLUSTERS_DECLARATION` Ruby hash near the top of the Vagrantfile. Every entry supports these keys:

| Key | Type | Description |
|-----|------|-------------|
| `base_subnet` | String | The first three octets of the private network (e.g. `"192.168.55"`) |
| `master_count` | Integer | Number of control-plane nodes (1–13) |
| `worker_count` | Integer | Number of worker nodes (1–13) |
| `master_cpus` | Integer | vCPUs per master VM |
| `master_memory` | Integer | RAM in MB per master VM |
| `worker_cpus` | Integer | vCPUs per worker VM |
| `worker_memory` | Integer | RAM in MB per worker VM |
| `metallb_ip_range` | String | CIDR range for MetalLB's Layer 2 IP pool |
| `context_name` | String | Short label used in the kubectl context name |

When `master_count > 1`, an HAProxy VM is automatically created on `.20` of the subnet.

---

## IP Addressing Scheme

IP addresses are deterministic and managed centrally through the `IP_OFFSETS` map:

| Role | Offset | Example (subnet 192.168.55) |
|------|--------|-----------------------------|
| LB VIP (reserved, future) | .10 | 192.168.55.10 |
| HAProxy LB | .20 | 192.168.55.20 |
| Master 1 | .11 | 192.168.55.11 |
| Master 2 | .12 | 192.168.55.12 |
| Master 3 | .13 | 192.168.55.13 |
| Master 4 | .14 | 192.168.55.14 |
| Worker 1 | .21 | 192.168.55.21 |
| Worker 2 | .22 | 192.168.55.22 |
| Worker 3 | .23 | 192.168.55.23 |
| Worker 4 | .24 | 192.168.55.24 |

Masters use offsets 11–20 then 31, 33, 35 (up to 13 masters). Workers use 21–30 then 32, 34, 36 (up to 13 workers). All VMs in all clusters are registered in every VM's `/etc/hosts` file so that hostnames like `k8s-prod-master1` resolve everywhere.

---

## Component Stack

| Component | Version Constant | Purpose |
|-----------|-----------------|---------|
| Kubernetes | `K8S_VERSION = "1.33"` | Control plane and kubelet |
| Docker CE | Latest from Docker APT repo | Container runtime |
| cri-dockerd | `CRI_DOCKERD_VERSION = "v0.3.23"` | CRI shim for Docker |
| Calico | `CALICO_VERSION = "v3.31.3"` | CNI plugin and network policies |
| MetalLB | `METALLB_VERSION = "v0.15.2"` | Layer 2 LoadBalancer IPs |
| Helm | `HELM_VERSION = "4.1.0"` | Kubernetes package manager |
| Headlamp | `HEADLAMP_VERSION = "0.39.0"` | Web-based Kubernetes dashboard |
| Metrics Server | Latest release | CPU/memory metrics for `kubectl top` and HPA |
| HAProxy | Latest from Ubuntu APT repo | API-server load balancing (HA clusters) |

---

## Provisioning Flow

The provisioning happens in a strict order within each cluster. Here is exactly what runs on each role:

### Every VM (including LB)

1. Install utility packages (`build-essential`, `curl`, `jq`, `vim`, `htop`, `nmap`, etc.).
2. Populate `/etc/hosts` with all VM hostnames across all clusters.
3. Disable swap (required by kubelet).
4. Install the shared SSH public key into `authorized_keys` for both `vagrant` and `root`.
5. Deploy the shared SSH private key and configure `StrictHostKeyChecking no`.

### Load Balancer (only when `master_count > 1`)

6. Install HAProxy.
7. Generate `haproxy.cfg` with a `kubernetes-backend` that lists all master IPs for this cluster, with TCP health checks.
8. Enable the HAProxy stats frontend on port 8404.

### Master and Worker Nodes

6. Load kernel modules (`overlay`, `br_netfilter`) and set sysctl params for bridged traffic and IP forwarding.
7. Install Docker CE with the systemd cgroup driver.
8. Disable the containerd CRI plugin (so cri-dockerd is the sole CRI).
9. Install cri-dockerd (version-aware - upgrades or downgrades to match `CRI_DOCKERD_VERSION`).
10. Install kubeadm, kubelet, kubectl (version-aware - matches `K8S_VERSION`).
11. Auto-detect the VirtualBox private network interface and configure kubelet's `--node-ip` accordingly.

### First Master (master1)

12. Run `kubeadm init` with `--apiserver-advertise-address` set to the private IP, `--pod-network-cidr=10.244.0.0/16`, and `--cri-socket` pointing to cri-dockerd. For HA clusters, `--control-plane-endpoint` points to the LB IP and `--upload-certs` is added.
13. Copy the admin kubeconfig to `/home/vagrant/.kube/config` and `/root/.kube/config`.
14. Rename the kubectl context from `kubernetes-admin@kubernetes` to the cluster name (e.g. `k8s-prod`).
15. Generate and save `worker-join.sh` and `master-join.sh` (for HA) to the shared `/vagrant/.vagrant/cluster-data/<cluster>/` directory. The master join script includes `"$@"` so that additional masters can pass `--apiserver-advertise-address`.
16. Apply the Calico manifest with the pod CIDR patched in (version-aware).
17. Install Helm (version-aware).
18. Apply MetalLB's native manifest, patch the controller to tolerate the control-plane taint, wait for the webhook to become ready (dry-run validation loop), then apply the `IPAddressPool` and `L2Advertisement` resources (with retry logic).
19. Apply the Metrics Server manifest with `--kubelet-insecure-tls` injected. Then verify via `kubectl patch` that the flag is present (safety net), and `kubectl scale` to the desired replica count.
20. Install Headlamp via `helm install` with `service.type=LoadBalancer` (version-aware upgrade/downgrade).

### Additional Masters (master2, master3, …)

12. Pre-pull Kubernetes images.
13. Wait for the LB endpoint to become reachable (TCP connect loop, up to 300 s).
14. Wait for `master-join.sh` to appear in the shared directory.
15. Run `bash master-join.sh --apiserver-advertise-address=<this-node-ip>` with up to 5 retries (reset + 30 s backoff).
16. Copy kubeconfig and rename context.

### Worker Nodes

12. Wait for the API endpoint (LB or master1) to become reachable.
13. Wait for `worker-join.sh` to appear.
14. Run `bash worker-join.sh` with up to 5 retries (reset + 15 s backoff).

---

## Version Management

All component versions are declared as Ruby constants near the top of the Vagrantfile. To upgrade or downgrade any component:

**Step 1 - Edit the version constant.**

```ruby
K8S_VERSION         = "1.34"       # was "1.33"
CALICO_VERSION      = "v3.31.3"    # was "vv3.29.0"
```

**Step 2 - Re-provision.**

```bash
vagrant provision
# or
vagrant reload --provision
```

Each provisioning script compares the installed version to the declared version and will install, upgrade, or downgrade accordingly.

**Important notes:**

- Kubernetes can be upgraded across minor versions (e.g. 1.33 → 1.34) but kubeadm does not support minor-version downgrades on an already-initialized cluster.
- cri-dockerd, Calico, MetalLB, Helm, and Headlamp can be freely upgraded or downgraded.
- The Metrics Server replica count and `--kubelet-insecure-tls` flag are enforced on every provision run, regardless of whether the deployment already exists.

---

## Day-to-Day Operations

### Start all clusters

```bash
vagrant up
```

### Shut down all VMs (fast - ~30 s per VM)

```bash
vagrant halt
```

### Restart all VMs

```bash
vagrant reload
```

### Destroy everything and start fresh

```bash
vagrant destroy -f
vagrant up
```

### Show the state of all VMs

```bash
vagrant status
```

### SSH into a specific VM

```bash
vagrant ssh k8s-prod-master1
```

### Run a command on a VM without interactive shell

```bash
vagrant ssh k8s-prod-master1 -c 'kubectl get nodes -o wide'
```

### Provision a single VM (e.g. after editing versions)

```bash
vagrant provision k8s-dev-master
```

---

## Accessing the Kubernetes Dashboard (Headlamp)

Headlamp is installed on the first master of every cluster via Helm, exposed as a `LoadBalancer` service (MetalLB assigns an IP from the cluster's pool).

**Step 1 - Find the external IP.**

```bash
vagrant ssh k8s-prod-master1 -c 'kubectl get svc -n headlamp'
```

Look for the `EXTERNAL-IP` column.

**Step 2 - Generate a login token.**

```bash
vagrant ssh k8s-prod-master1 -c 'kubectl create token headlamp --namespace headlamp'
```

**Step 3 - Open in browser.**

Navigate to `http://<EXTERNAL-IP>/` and paste the token. No HTTPS certificate warnings - Headlamp runs over plain HTTP in this setup.

---

## HAProxy Stats Page

For HA clusters (those with `master_count > 1`), the HAProxy VM exposes a statistics dashboard:

```
http://<lb-ip>:8404/stats
```

For example, for `k8s-prod`: `http://192.168.54.20:8404/stats`. This page shows backend health, connection counts, and request distribution across masters.

---

## SSH Between VMs

A single RSA key pair is generated on the host (under `.vagrant/ssh-keys/`) and distributed to every VM during provisioning. This enables passwordless SSH between any two VMs:

```bash
# From the host
vagrant ssh k8s-prod-master1

# From inside k8s-prod-master1, SSH to a worker in a different cluster
ssh vagrant@192.168.51.21   # k8s-dev-worker1
ssh vagrant@k8s-qa-master   # uses /etc/hosts
```

`StrictHostKeyChecking` is disabled for the `192.168.*` and `k8s-*` hostname patterns, so there are no fingerprint prompts.

---

## Kubeconfig Setup (Host-Side)

The `kubeconfig-setup.sh` script automates fetching kubeconfigs from your running clusters and merging them into `~/.kube/config` on your host machine, so you can run `kubectl` directly from the host without SSH-ing into a VM first.

### Prerequisites

The script requires `kubectl` installed on your host for the merge step. VirtualBox and Vagrant must already be working (which they are if you ran `vagrant up`). On Windows, the script is designed for Git Bash and will auto-detect `VBoxManage.exe` even if it is not on your `PATH`.

### Make the script executable

```bash
chmod +x kubeconfig-setup.sh
```

### Commands

| Command | Description |
|---------|-------------|
| `./kubeconfig-setup.sh show` | Display detected VMs and cluster configuration (read-only, safe to run anytime) |
| `./kubeconfig-setup.sh fetch` | Fetch kubeconfigs from all running clusters, merge into `~/.kube/config`, and fix TLS |
| `./kubeconfig-setup.sh fix-tls` | Fix TLS certificate validation errors in an existing `~/.kube/config` |
| `./kubeconfig-setup.sh sync` | Update the Vagrantfile's cluster definitions to match the actual running VMs |
| `./kubeconfig-setup.sh scan` | Deep-scan every running VM (regardless of naming) to find Kubernetes installations |
| `./kubeconfig-setup.sh help` | Show the full help message |

### Typical workflow

**Step 1 - Verify your clusters are up.**

```bash
./kubeconfig-setup.sh show
```

This reads the running VM list directly from VirtualBox (not from `vagrant status`), parses each VM's name to determine its cluster and role, and displays a summary of masters, workers, CPUs, and memory per cluster.

**Step 2 - Fetch and merge all kubeconfigs.**

```bash
./kubeconfig-setup.sh fetch
```

This connects to the primary master of each detected cluster via `vagrant ssh`, retrieves its `~/.kube/config`, renames the context from `kubernetes-admin@kubernetes` to the cluster name (stripping the `k8s-` prefix - so `k8s-prod` becomes `prod`), applies a TLS fix, and merges everything into `~/.kube/config` on the host. A timestamped backup of the existing config is created before any changes.

**Step 3 - Use kubectl from the host.**

```bash
# List all available contexts
kubectl config get-contexts

# Switch to a specific cluster
kubectl config use-context prod

# Run commands against that cluster
kubectl get nodes -o wide
kubectl get pods --all-namespaces
```

### TLS certificate fix

Kubeadm embeds a self-signed CA certificate in every kubeconfig as `certificate-authority-data`. When you use that kubeconfig from the host (outside the VM), kubectl tries to verify the API server's certificate against that embedded CA - but because the CA was generated inside the VM and is unknown to the host's trust store, verification fails with `x509: certificate signed by unknown authority`.

The `fetch` command applies this fix automatically in two stages. First, it removes `certificate-authority-data` and injects `insecure-skip-tls-verify: true` in each fetched kubeconfig before merging. Second, after the merge, it reinforces the flag on every cluster entry via `kubectl config set-cluster`. This ensures the fix survives even if a stale backup re-introduces the CA data.

If you already have a `~/.kube/config` that was fetched without the fix (or copied manually from a VM), run:

```bash
./kubeconfig-setup.sh fix-tls
```

This is safe for local development clusters. Do not use it for production kubeconfigs.

### Syncing the Vagrantfile

If you have manually changed VM resources (CPUs, memory) through VirtualBox or have added nodes outside of Vagrant, the `sync` command reads the actual running state from VirtualBox and updates the `ALL_CLUSTERS_DECLARATION` hash in the Vagrantfile to match:

```bash
./kubeconfig-setup.sh sync
```

A timestamped backup of the Vagrantfile is created in `.vagrant/backups/` before any modification.

### Deep scan

If your VMs use non-standard naming conventions that the pattern filter doesn't match, the `scan` command checks every running VM (regardless of name) by SSH-ing in and looking for `~/.kube/config`, `kubectl`, or `kubeadm`:

```bash
./kubeconfig-setup.sh scan
```

### Customizing VM naming patterns

The script matches VM names against a configurable regex defined at the top of the file:

```bash
ROLE_PATTERNS="master|worker|control-plane|node|cp|wk|ctrl|compute"
```

If your VMs use a different naming convention, edit this line and add your patterns. The script expects VM names in the format `<cluster>-<role><index>`, for example `k8s-prod-master1`, `qa-worker2`, or `dev-cp1`.

---

## Adding or Removing Clusters

### Adding a cluster

Add a new entry to `ALL_CLUSTERS_DECLARATION`:

```ruby
"k8s-staging" => {
  base_subnet: "192.168.50",
  master_count: 1,
  worker_count: 2,
  master_cpus: 2,
  master_memory: 4096,
  worker_cpus: 1,
  worker_memory: 1024,
  metallb_ip_range: "192.168.50.200/27",
  context_name: "staging"
},
```

Then run `vagrant up`. Only the new VMs are created; existing VMs are untouched.

### Removing a cluster

Comment out the cluster's entry and run `vagrant destroy <vm-names>` for the VMs you want to remove, or simply `vagrant destroy -f` to tear down everything.

---

## Changing the Base Box

The Vagrantfile includes four pre-configured box options. Uncomment the one you want:

| Option | Box | Notes |
|--------|-----|-------|
| 1 (default) | `bento/ubuntu-25.04` | Recommended. Uses password auth. |
| 2 | `kdq/ubuntu-24.04` | Fallback. Uses insecure key. |
| 3 | `ubuntu/jammy64` | Ubuntu 22.04 LTS. Uses insecure key. |
| 4 | `generic/ubuntu2204` | Requires `SYNCED_FOLDER_TYPE = "rsync"`. |

**Important:** If VMs already exist with a different box, you must `vagrant destroy -f` before `vagrant up` with the new box. A "Box Change Guard" trigger will warn you if a mismatch is detected.

---

## Synced Folder Modes

The `SYNCED_FOLDER_TYPE` constant controls how the project directory is shared with VMs:

| Value | Mechanism | Notes |
|-------|-----------|-------|
| `nil` (default) | VirtualBox shared folders | Works with most boxes. Best for bento and ubuntu boxes. |
| `"rsync"` | One-way rsync from host to VM | Required for `generic/ubuntu2204`. Extra triggers handle copying join commands back to the host. |
| Other string | Passed directly to Vagrant | e.g. `"nfs"`, `"smb"` - use if you have specific requirements. |

When using rsync mode, the Vagrantfile includes automatic triggers that rsync cluster data (join commands, kubeconfig) back to the host after master1 provisioning, and forward to other VMs before their provisioning.

---

## Idempotency Guarantees

Every provisioning script is designed to be run repeatedly without side effects:

- **kubeadm init** is skipped if `/etc/kubernetes/admin.conf` already exists.
- **kubeadm join** is skipped if `/etc/kubernetes/kubelet.conf` already exists.
- **Calico, MetalLB, Helm, Headlamp** each check the installed version and only act if it differs from the declared version.
- **Metrics Server** checks both the `--kubelet-insecure-tls` arg and replica count on every run, patching or scaling as needed.
- **Utility packages** are gated by a marker file (`/var/lib/vagrant-util-pkgs-installed`).
- **`/etc/hosts`** entries are replaced (not appended) on each run.
- **`kubectl apply`** is naturally idempotent.

---

## Resource Planning

### Per-VM resource defaults

| Role | vCPU | RAM | Notes |
|------|------|-----|-------|
| Master | 2 | 4096 MB | Minimum for stable control plane |
| Worker | 1–2 | 1024 MB | Configurable per cluster |
| Load Balancer | 1 | 1024 MB | Minimum 1 GB to avoid OOM on Ubuntu |

### Example: Running all five default clusters

```
Cluster        LB    Masters          Workers            Total
k8s-dr         1 GB  2 × 4 GB = 8    2 × 1 GB = 2      11 GB
k8s-prod       1 GB  3 × 4 GB = 12   3 × 1 GB = 3      16 GB
k8s-pre-prod   -     1 × 4 GB = 4    3 × 1 GB = 3       7 GB
k8s-qa         -     1 × 4 GB = 4    2 × 1 GB = 2       6 GB
k8s-dev        -     1 × 4 GB = 4    2 × 1 GB = 2       6 GB
─────────────────────────────────────────────────────────────
Grand Total                                              46 GB
```

For a 64 GB host, this leaves ~18 GB for the host OS and other applications.

### Recommended starting configurations

| Host RAM | Suggested clusters |
|----------|--------------------|
| 8 GB | 1 cluster, single master, 1–2 workers |
| 16 GB | 1–2 clusters, single master each |
| 32 GB | 2–3 clusters, one can be HA |
| 64 GB | All five clusters comfortably |

---

## File Structure

```
project/
├── Vagrantfile                          # Everything lives here
├── kubeconfig-setup.sh                  # Host-side kubeconfig fetch, merge, and TLS fix
├── .vagrant/
│   ├── ssh-keys/
│   │   ├── id_rsa                       # Shared private key (auto-generated)
│   │   └── id_rsa.pub                   # Shared public key (auto-generated)
│   ├── cluster-data/
│   │   ├── k8s-dr/
│   │   │   ├── admin.conf              # Kubeconfig for this cluster
│   │   │   ├── worker-join.sh          # Worker join command
│   │   │   └── master-join.sh          # Master join command (HA only)
│   │   ├── k8s-prod/
│   │   │   └── ...
│   │   └── ...
│   ├── backups/                         # Vagrantfile backups from sync command
│   ├── box-state                        # Tracks current box image for change guard
│   └── machines/                        # Vagrant machine state (auto-managed)
```

The `.vagrant/` directory is created automatically and should not be committed to version control.

---

## Reference: Vagrant Commands

| Command | Description |
|---------|-------------|
| `vagrant up` | Create and provision all VMs (idempotent) |
| `vagrant up k8s-qa-master` | Create and provision a specific VM |
| `vagrant halt` | Gracefully shut down all VMs (~30 s per VM) |
| `vagrant reload` | Restart all VMs (halt + up, no re-provision) |
| `vagrant reload --provision` | Restart and re-provision all VMs |
| `vagrant provision` | Re-run provisioners on running VMs |
| `vagrant provision k8s-dev-master` | Re-provision a single VM |
| `vagrant destroy -f` | Destroy all VMs without confirmation |
| `vagrant status` | Show the state of all defined VMs |
| `vagrant ssh k8s-prod-master1` | Open an interactive SSH session |
| `vagrant ssh k8s-prod-master1 -c 'cmd'` | Run a command and return |

---

## Tested Hardware

```
HP OmniStudio X 31.5" All-in-One
  CPU:     Intel Core Ultra 7 155H - 16 cores, 22 threads, up to 4.8 GHz
  RAM:     64 GB DDR5 5600 MT/s (2 × 32 GB Kingston FURY Impact)
  Storage: 4 TB PCIe 4.0 NVMe SSD (7,400 MB/s read, 6,500 MB/s write)
```

All five default clusters (22 VMs, ~46 GB RAM) provision successfully on this hardware in approximately 45–60 minutes for the initial run.
