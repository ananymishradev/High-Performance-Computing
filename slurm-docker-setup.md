# SLURM HPC Cluster Setup Using Docker on Arch Linux

> **Hardware:** 13th Gen Intel Core i5-13450HX (12+4 cores) @ 4.60 GHz
> **Goal:** Create 1 Control Node + 2 Worker Nodes as Docker containers on Arch Linux
> **Host OS:** Arch Linux
> **Container OS:** Arch Linux (100% `pacman` — no Ubuntu, no `apt`)
>
> Planning to build a **real** multi-machine cluster? See **[`slurm-physical-cluster-setup.md`](slurm-physical-cluster-setup.md)** — the guide for 1 controller + 4 workers on Ubuntu 22.04 connected over a shared Ethernet LAN.

---

## Table of Contents

1. [What You Will Learn](#1-what-you-will-learn)
2. [Prerequisites](#2-prerequisites)
3. [Concepts Explained Simply](#3-concepts-explained-simply)
4. [Step 1: Install Docker on Arch Linux](#4-step-1-install-docker-on-arch-linux)
5. [Step 2: Docker Basics for Beginners](#5-step-2-docker-basics-for-beginners)
6. [Step 3: Create the Docker Setup Files](#6-step-3-create-the-docker-setup-files)
7. [Step 4: Build and Run the Cluster](#7-step-4-build-and-run-the-cluster)
8. [Step 5: Connect to Nodes](#8-step-5-connect-to-nodes)
9. [Step 6: Verify Your Cluster](#9-step-6-verify-your-cluster)
10. [Step 7: Test Your Cluster](#10-step-7-test-your-cluster)
11. [Command Reference](#11-command-reference)
12. [Troubleshooting](#12-troubleshooting)
13. [Stopping and Cleaning Up](#13-stopping-and-cleaning-up)
14. [Summary of What Was Created](#14-summary-of-what-was-created)
15. [Docker Official Resources](#15-docker-official-resources)

---

## 1. What You Will Learn

- What Docker is and why it is used here (with official documentation links)
- What SLURM, SSH, and Munge are
- How to create a mini HPC cluster entirely from **Arch Linux** containers
- How to submit jobs across multiple simulated nodes

---

## 2. Prerequisites

- A laptop running **Arch Linux**
- At least **8 GB RAM** (16 GB recommended)
- **20 GB free disk space**
- An internet connection

---

## 3. Concepts Explained Simply

### What is Docker?

Docker creates **virtual computers inside your real computer**. Each virtual computer is called a **container**. Containers are lightweight — they start in seconds and do not require a full operating-system installation.

> **Official Docker Documentation:**
> - What is a container?: https://docs.docker.com/get-started/docker-overview/#containers
> - Docker overview: https://docs.docker.com/get-started/docker-overview/
> - Docker Engine: https://docs.docker.com/engine/
> - Dockerfile reference: https://docs.docker.com/engine/reference/builder/
> - Docker Compose: https://docs.docker.com/compose/

### Why Arch Linux inside the Containers?

The containers use **pure Arch Linux** (`archlinux:latest`) for two reasons:

1. **Lower CPU and RAM usage.** The previous version of this guide ran `systemd` (`command: /sbin/init`) as the main process in every container. Booting a full init system three times wastes cycles. The Arch setup below starts only the daemons actually needed (`munged`, `sshd`, `slurmctld`, `slurmd`) — no heavy init process.
2. **One package manager for everything.** Your laptop already uses `pacman`; the containers do too. Same philosophy, same commands, no `apt`/Ubuntu mismatch.

> **Note:** The containers run their own rolling Arch userland. Your host Arch Linux stays completely untouched.

### Why Docker for SLURM?

Instead of buying 3 separate computers, we create 3 containers that **behave like** separate computers. Each container sees itself as an independent machine. This is ideal for learning because:

- You do not need 3 physical machines
- You can destroy and recreate everything in seconds
- It runs on your existing laptop

### SSH (Secure Shell)

SSH lets you **log into another computer remotely**. Typing `ssh user@computer-name` connects to that machine over the network and gives you a terminal on it.

> **Official SSH Documentation:** https://man.archlinux.org/man/ssh.1

### Munge

Munge is an **authentication service**. When SLURM nodes communicate, Munge ensures they are who they claim to be by issuing a shared secret token.

> **Analogy:** Munge is a shared secret handshake. Every node knows it, so nodes recognize one another; anyone without it is rejected.

### SLURM (Simple Linux Utility for Resource Management)

SLURM is the **job scheduler**. It decides:

- Which jobs run on which nodes
- When jobs start
- How many resources (CPU, RAM) each job receives

> **Official SLURM Documentation:** https://slurm.schedmd.com/documentation.html
> **Arch package:** `slurm-llnl` (https://archlinux.org/packages/extra/x86_64/slurm-llnl/)
> **ArchWiki:** https://wiki.archlinux.org/title/Slurm

---

## 4. Step 1: Install Docker on Arch Linux

### Method: Official Arch Repositories

Docker is available in the official Arch Linux repositories — no external repositories are needed.

```bash
# Update your system first (always do this before installing new packages)
sudo pacman -Syu

# Install Docker and Docker Compose
sudo pacman -S docker docker-compose
```

> **Note:** During installation you may be asked to choose between providers (such as `docker` vs `docker-nvidia`). Press Enter to accept the default.

### Enable and Start the Docker Service

```bash
# Enable Docker to start on boot
sudo systemctl enable docker.service

# Start Docker now
sudo systemctl start docker.service

# Enable containerd (Docker's container runtime)
sudo systemctl enable containerd.service
sudo systemctl start containerd.service
```

### Allow Your User to Run Docker Without sudo

By default only root can run Docker commands. Add your user to the `docker` group:

```bash
sudo usermod -aG docker $USER

# Apply the group change immediately (or log out and back in)
newgrp docker
```

> **Official Docker Installation on Arch Linux:** https://docs.docker.com/engine/install/

### Verify Docker Installation

```bash
# Check the Docker version
docker --version
# Should output something like: Docker version 24.x.x, build xxxxxxx

# Test that Docker is working
docker run hello-world
# Should output: "Hello from Docker!"
```

If you see "Hello from Docker!", Docker is installed and working.

---

## 5. Step 2: Docker Basics for Beginners

> **Official Docker Getting Started Guide:** https://docs.docker.com/get-started/

### Images vs Containers

- **Image:** A blueprint or template — the recipe.
- **Container:** A running instance of an image — the finished result.

### Essential Docker Commands

| Command | What It Does | Example |
|---------|-------------|---------|
| `docker build` | Builds a container image from a Dockerfile | `docker build -t myimage .` |
| `docker run` | Starts a container from an image | `docker run -d myimage` |
| `docker ps` | Lists running containers | `docker ps` |
| `docker exec` | Runs a command inside a running container | `docker exec -it container bash` |
| `docker stop` | Stops a running container | `docker stop container_name` |
| `docker start` | Starts a stopped container | `docker start container_name` |
| `docker rm` | Removes a container | `docker rm container_name` |
| `docker images` | Lists all downloaded images | `docker images` |
| `docker compose up` | Starts all services defined in docker-compose.yml | `docker compose up -d` |
| `docker compose down` | Stops and removes all services | `docker compose down` |

> **Official Docker CLI Reference:** https://docs.docker.com/engine/reference/commandline/docker/

### What is a Dockerfile?

A Dockerfile is a **recipe file**. It tells Docker what software to install inside the container, step by step.

> **Official Dockerfile Reference:** https://docs.docker.com/engine/reference/builder/

### What is docker-compose?

docker-compose defines and runs multi-container Docker applications. Instead of starting containers one by one, you define everything in one file and start them all at once.

> **Official Docker Compose Documentation:** https://docs.docker.com/compose/

---

## 6. Step 3: Create the Docker Setup Files

> **Shortcut:** This repository already contains ready-made copies of every file below in the **`docker-cluster/`** folder. To skip the typing:
> ```bash
> cp -r ~/paanduv_hpc/docker-cluster ~/slurm-cluster
> cd ~/slurm-cluster
> mkdir -p config/munge shared/job_scripts
> ```
> Then jump straight to [Generate the Shared Munge Key](#generate-the-shared-munge-key-on-your-host-before-starting). The sections below explain what each file does so you understand the setup.

### Create the Project Directory

```bash
mkdir -p ~/slurm-cluster
cd ~/slurm-cluster

mkdir -p config/munge setup shared
```

### File 1: `Dockerfile` (Builds the Container Image)

This file tells Docker: "Start with Arch Linux, install SLURM, SSH, and Munge with `pacman`, and prepare everything."

Create the file:

```bash
nano ~/slurm-cluster/Dockerfile
```

Paste this content:

```dockerfile
# Pure Arch Linux base image - no Ubuntu, no apt
FROM archlinux:latest

# Refresh the package database and install everything with pacman
RUN pacman -Syu --noconfirm \
    slurm-llnl \
    munge \
    openssh \
    sudo \
    vim \
    iputils \
    iproute2 \
    net-tools \
    inetutils \
    && rm -rf /var/cache/pacman/pkg

# The slurm-llnl and munge packages already create the slurm + munge
# users/groups through pacman's sysusers hook, so only create them if the
# packages did not. slurm uses the same UID/GID (64030) as a real Arch install.
RUN id slurm >/dev/null 2>&1 || { groupadd -r -g 64030 slurm \
    && useradd -r -u 64030 -g 64030 -d /var/lib/slurm-llnl -s /bin/nologin slurm; } \
    && id munge >/dev/null 2>&1 || { groupadd -r munge \
    && useradd -r -g munge -d /var/log/munge -s /bin/nologin munge; }

# Munge runtime + lib directories, owned by the munge user
RUN mkdir -p /run/munge /var/lib/munge \
    && chown munge:munge /run/munge /var/lib/munge \
    && chmod 0700 /run/munge

# SSH: runtime dir + allow root login (needed for passwordless SSH between nodes)
RUN mkdir -p /var/run/sshd \
    && echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config

# SLURM spool directories
RUN mkdir -p /var/spool/slurm /var/spool/slurmd

# Entrypoint starts the daemons directly (no systemd inside the containers)
COPY setup/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Save and exit (Ctrl+O, Enter, Ctrl+X in nano).

> **Why the `id ... || {...}` guard?** On Arch, installing `slurm-llnl` already creates the `slurm` and `munge` users via pacman's `sysusers` hook. A plain `groupadd slurm` then fails with `groupadd: group 'slurm' already exists` and the build stops. Guarding each command with `id ... >/dev/null 2>&1 ||` makes the build idempotent: create the users only if the packages did not.
>
> **Why `inetutils`?** `hostname` is not in the base image (Arch splits it into `inetutils`). The job test scripts and SSH checks need it.

> **Why no systemd?** `systemd` cannot start services in the official Arch Docker image without extra privileges, and booting it three times wastes CPU/RAM. Instead, the entrypoint script starts exactly the 3–4 daemons we need. Result: a much lighter cluster that responds faster on your i5.

### File 2: `docker-compose.yml` (Defines the 3-Node Cluster)

This file tells Docker: "Create 3 containers, connect them on a network, give them names, and share the configuration files."

Create the file:

```bash
nano ~/slurm-cluster/docker-compose.yml
```

Paste this content:

```yaml
services:
  # CONTROL NODE (also runs the controller)
  master:
    build: .
    image: slurm-arch:latest
    hostname: master
    container_name: slurm_master
    privileged: true
    environment:
      - NODE_ROLE=master
    networks:
      slurm_net:
        ipv4_address: 10.0.0.2
    volumes:
      - ./config/slurm.conf:/etc/slurm-llnl/slurm.conf:ro
      - ./config/cgroup.conf:/etc/slurm-llnl/cgroup.conf:ro
      - ./config/munge:/etc/munge
      - ./shared:/shared

  # WORKER NODE 1
  worker1:
    build: .
    image: slurm-arch:latest
    hostname: worker1
    container_name: slurm_worker1
    privileged: true
    environment:
      - NODE_ROLE=worker
    networks:
      slurm_net:
        ipv4_address: 10.0.0.3
    volumes:
      - ./config/slurm.conf:/etc/slurm-llnl/slurm.conf:ro
      - ./config/cgroup.conf:/etc/slurm-llnl/cgroup.conf:ro
      - ./config/munge:/etc/munge
      - ./shared:/shared

  # WORKER NODE 2
  worker2:
    build: .
    image: slurm-arch:latest
    hostname: worker2
    container_name: slurm_worker2
    privileged: true
    environment:
      - NODE_ROLE=worker
    networks:
      slurm_net:
        ipv4_address: 10.0.0.4
    volumes:
      - ./config/slurm.conf:/etc/slurm-llnl/slurm.conf:ro
      - ./config/cgroup.conf:/etc/slurm-llnl/cgroup.conf:ro
      - ./config/munge:/etc/munge
      - ./shared:/shared

networks:
  slurm_net:
    driver: bridge
    ipam:
      config:
        - subnet: 10.0.0.0/24
```

Save and exit.

> **What is a bridge network?** A bridge network is like a private network that only your containers can see. They can talk to each other but are isolated from the outside world.

> **Why `privileged: true`?** Arch's `slurm-llnl` package is compiled with cgroup v2 + systemd support. `slurmd` refuses to start unless it can manage a cgroup tree, which inside a default container is mounted read-only. Running the containers **privileged** gives them a writable `/sys/fs/cgroup`. Without it, `slurmd` exits with `fatal: systemd scope for slurmstepd could not be set` (see [Troubleshooting](#12-troubleshooting)). This is a sandbox, so privilege escalation is acceptable here — do not run privileged containers on untrusted workloads.

> **What do the volumes do?**
> - `./config/slurm.conf` is mounted into **all** nodes at `/etc/slurm-llnl/slurm.conf` (the Arch path — note it is `slurm-llnl`, not `slurm`). One file, automatically shared.
> - `./config/cgroup.conf` is mounted into **all** nodes at `/etc/slurm-llnl/cgroup.conf`. It tells SLURM's cgroup plugin how to work without systemd (see File 4).
> - `./config/munge` is mounted at `/etc/munge` on **all** nodes, so every node uses the **same** Munge key. No manual key copying needed.
> - `./shared` is mounted at `/shared` on all nodes, so job scripts and output files are visible everywhere.

> **Official Docker Networks Documentation:** https://docs.docker.com/engine/network/

### File 3: `config/slurm.conf` (SLURM Configuration)

This is the **most important file**. It tells SLURM about your cluster topology.

Create the file:

```bash
nano ~/slurm-cluster/config/slurm.conf
```

Paste this content:

```bash
#=== SLURM Cluster Configuration (Arch Linux) ===

# Modern SLURM builds (26.x) require a cluster name
ClusterName=paanduv

# Controller node (host)
SlurmctldHost=master

# Authentication
AuthType=auth/munge
CredType=cred/munge

# Scheduler
SchedulerType=sched/backfill
SelectType=select/cons_tres

# Track processes the simple way; cgroup.conf (File 4) handles the cgroup
# plugin for us so it does not need systemd.
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none

# Logging (Arch keeps SLURM logs under /var/log/slurm-llnl)
SlurmctldLogFile=/var/log/slurm-llnl/slurmctld.log
SlurmdLogFile=/var/log/slurm-llnl/slurmd.log
StateSaveLocation=/var/spool/slurm

# CLUSTER DEFINITION
# Node name, address, CPUs, real memory (in MB)

# --- Control/Controller Node ---
NodeName=master CPUs=2 RealMemory=4000 State=IDLE

# --- Worker Node 1 ---
NodeName=worker1 CPUs=2 RealMemory=4000 State=IDLE

# --- Worker Node 2 ---
NodeName=worker2 CPUs=2 RealMemory=4000 State=IDLE

# --- PARTITION (like a queue) ---
# NOTE: SLURM config has NO line continuation. Keep each directive on ONE line,
# or the split-off tokens (e.g. "State=UP") are parsed as unknown directives.
PartitionName=normal Nodes=worker1,worker2 Default=YES MaxTime=INFINITE State=UP
PartitionName=all Nodes=master,worker1,worker2 Default=NO MaxTime=INFINITE State=UP
```

Save and exit.

> **Note:** We allocate 2 CPUs and 4 GB RAM per node. Your i5-13450HX has 12+4 cores, so raise the `CPUs=` numbers if you want the scheduler to hand out more.
>
> **Note:** On Arch the config file lives in `/etc/slurm-llnl/`. That is where SLURM looks by default on this distro.

### File 4: `config/cgroup.conf` (Keeps slurmd Alive Without systemd)

Arch's `slurm-llnl` package is compiled against cgroup v2 + systemd. When `slurmd` starts it tries to create a systemd "scope" over D-Bus for `slurmstepd`. Inside a container there is no systemd and no `/run/dbus/system_bus_socket`, so it dies with `fatal: systemd scope for slurmstepd could not be set`. This file tells the cgroup plugin to prepare the cgroup tree itself instead of asking systemd.

Create the file:

```bash
nano ~/slurm-cluster/config/cgroup.conf
```

Paste this content:

```bash
# Arch's SLURM wants to ask systemd (via D-Bus) to create a cgroup scope for
# slurmstepd. There is no systemd inside a container, so have the cgroup
# plugin create the directories manually instead. Requires a writable cgroup
# filesystem, which is why the containers run with privileged: true.
CgroupPlugin=cgroup/v2
IgnoreSystemd=yes
```

Save and exit.

> **What does `IgnoreSystemd=yes` do?** It skips the D-Bus call to systemd and does a plain `mkdir` for the slurmstepd cgroup directories. Combined with `privileged: true` (writable `/sys/fs/cgroup`), `slurmd` starts normally inside the container.

### File 5: `setup/entrypoint.sh` (Starts the Daemons Inside Each Container)

Because there is no `systemd` inside the containers, this small script starts the daemons directly. It runs automatically every time a container starts.

Create the file:

```bash
nano ~/slurm-cluster/setup/entrypoint.sh
```

Paste this content:

```bash
#!/bin/bash
# Starts Munge, SSH and the SLURM daemons.
# No systemd is used inside the containers, so nothing heavy boots up.
set -e

# ${HOSTNAME} is a bash built-in — the hostname binary needs inetutils.
echo "=== ${HOSTNAME} starting (role: ${NODE_ROLE:-worker}) ==="

# Sandbox convenience: fixed root password so ssh-copy-id / SSH login works.
echo 'root:paanduv' | chpasswd

# --- Shared Munge key (all nodes share ./config/munge via the bind mount) ---
mkdir -p /etc/munge
if [ "$NODE_ROLE" = "master" ] && [ ! -f /etc/munge/munge.key ]; then
  echo "Generating munge key on master..."
  dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key 2>/dev/null
fi
if [ -f /etc/munge/munge.key ]; then
  chown munge:munge /etc/munge/munge.key
  chmod 400 /etc/munge/munge.key
fi

# --- Munge ---
chown -R munge:munge /run/munge /var/lib/munge /var/log/munge 2>/dev/null || true
echo "Starting munged..."
munged --force
sleep 1

# --- SSH ---
ssh-keygen -A >/dev/null 2>&1 || true
echo "Starting sshd..."
/usr/bin/sshd

# --- SLURM daemons (master runs the controller, workers just run slurmd) ---
case "$NODE_ROLE" in
  master)
    echo "Starting slurmctld + slurmd..."
    slurmctld
    slurmd
    ;;
  worker)
    echo "Starting slurmd..."
    slurmd
    ;;
esac

echo "=== ${HOSTNAME} is ready ==="
exec tail -f /dev/null
```

Save and exit.

### Make the Script Executable

```bash
chmod +x ~/slurm-cluster/setup/entrypoint.sh
```

### Generate the Shared Munge Key (on your host, before starting)

The Munge key must be **identical on every node**. The simplest and most reliable way is to generate it once on your laptop and let every container mount it:

```bash
cd ~/slurm-cluster

dd if=/dev/urandom bs=1024 count=1 of=config/munge/munge.key 2>/dev/null
chmod 400 config/munge/munge.key
```

> **Note:** The master also auto-generates a key if it finds none, so the cluster still boots even if you skip this step. Generating it up front is more predictable.

### Create a Shared Job Folder

```bash
cd ~/slurm-cluster
mkdir -p shared/job_scripts
```

---

## 7. Step 4: Build and Run the Cluster

### Build the Docker Image

```bash
cd ~/slurm-cluster
docker compose build
```

This takes a few minutes the first time. Docker downloads the Arch Linux base image and installs SLURM, Munge, and SSH with `pacman`.

> **What is happening?** Docker reads your Dockerfile and follows each instruction. It downloads Arch, installs packages, creates users, and sets up directories. The result is a reusable image you can start many times.

> **Official Docker Build Documentation:** https://docs.docker.com/engine/reference/commandline/build/

### Start All 3 Nodes

```bash
docker compose up -d
```

The `-d` flag means "detached" — the containers run in the background.

> **Note:** All three containers run **privileged** (see the `docker-compose.yml` explanation). This is required so `slurmd` can manage a writable cgroup filesystem. It only matters inside this sandbox cluster.

> **Official Docker Compose Up Documentation:** https://docs.docker.com/reference/cli/docker/compose/up/

### Check That All Nodes Are Running

```bash
docker ps
```

You should see 3 containers:

```
NAMES             STATUS          PORTS
slurm_master      Up X seconds
slurm_worker1     Up X seconds
slurm_worker2     Up X seconds
```

If a container is not running, check its logs:

```bash
docker compose logs master
docker compose logs worker1
docker compose logs worker2
```

You should see the entrypoint messages: `Starting munged...`, `Starting sshd...`, `Starting slurmctld + slurmd...`, and finally `=== hostname is ready ===`.

---

## 8. Step 5: Connect to Nodes

### Open a Terminal on the Master Node

```bash
docker exec -it slurm_master bash
```

You are now inside the master container as root. The prompt will change to something like `root@master:/#`.

> **What does `docker exec -it` mean?**
> - `exec` = execute a command
> - `-i` = interactive (keep STDIN open)
> - `-t` = allocate a pseudo-TTY (make it look like a terminal)

### Check That Everything Is Already Running

Because the entrypoint already started the daemons, nothing else needs configuring. Quick sanity checks:

```bash
# Munge running?
munged --version

# SSH running?
ss -tlnp | grep :22
# Should show the sshd listener

# SLURM controller running?
ps aux | grep -E 'slurmctld|slurmd'
# Should show both on the master
```

### Optional: Passwordless SSH Between Nodes

SLURM itself talks to nodes over its own protocol (port 6817), but setting up passwordless SSH is still useful for inspecting the workers. Inside the master container:

> **The root password on every node is `paanduv`** (set by the entrypoint). This is a sandbox — do not reuse this anywhere real.

```bash
# Generate an SSH key (press Enter for all prompts)
ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa

# Copy the public key to authorized_keys on yourself
cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys

# Copy key to worker1 (type the password: paanduv)
ssh-copy-id -o StrictHostKeyChecking=no root@worker1

# Copy key to worker2 (type the password: paanduv)
ssh-copy-id -o StrictHostKeyChecking=no root@worker2
```

### Test SSH Between Nodes

```bash
# From master, SSH into worker1
ssh worker1 hostname
# Should output: worker1

# From master, SSH into worker2
ssh worker2 hostname
# Should output: worker2
```

If this works, SSH is configured correctly.

---

## 9. Step 6: Verify Your Cluster

### Check Node Status

Still inside the master container:

```bash
sinfo
```

Expected output:

```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
normal*      up   infinite      2   idle worker[1-2]
all          up   infinite      3   idle master,worker[1-2]
```

### Check the Controller

```bash
# Show detailed node info
scontrol show nodes

# Show current jobs (should be empty)
squeue
```

> **If nodes show as `down`:** wait a few seconds for the workers to register, then run `sinfo` again. If they stay `down`, see the [Troubleshooting](#12-troubleshooting) section.

---

## 10. Step 7: Test Your Cluster

### Run a Simple Job

```bash
# Run hostname on the worker nodes
srun --nodes=2 hostname
```

### Create a Test Script

```bash
cat > /shared/job_scripts/test_job.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=test_job
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:05:00
#SBATCH --output=output_%j.out
#SBATCH --error=error_%j.out

echo "Running on host: $(hostname)"
echo "Date: $(date)"
echo "Working directory: $(pwd)"

# Simulate work
sleep 5

echo "Job completed!"
EOF
```

> **Note:** `/shared` is mounted on every node, so the workers can read the script too.

### Submit the Job

```bash
sbatch /shared/job_scripts/test_job.sh
```

### Check Job Status

```bash
squeue
```

Expected output:

```
JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
   123   normal test_job   root PD       0:00      2 worker[1-2]
```

### View Job Output

```bash
# Wait a few seconds, then check output
cat /shared/job_scripts/output_*.out
```

You should see the job ran on both `worker1` and `worker2`.

---

## 11. Command Reference

### SLURM Commands

| Command | What It Does |
|---------|-------------|
| `sinfo` | Shows cluster status |
| `squeue` | Shows running/pending jobs |
| `sbatch script.sh` | Submits a batch job |
| `srun hostname` | Runs a command on nodes interactively |
| `scancel JOB_ID` | Cancels a job |
| `scontrol show nodes` | Shows detailed node info |
| `scontrol show partitions` | Shows partition info |
| `scontrol show jobs` | Shows detailed job info |
| `sacct` | Shows completed job accounting info |
| `sprio` | Shows job priorities |

### Docker Commands

| Command | What It Does |
|---------|-------------|
| `docker ps` | Lists running containers |
| `docker exec -it name bash` | Opens a terminal inside a container |
| `docker compose up -d` | Starts all containers |
| `docker compose down` | Stops all containers |
| `docker compose logs` | Views container logs |
| `docker stop name` | Stops a specific container |
| `docker start name` | Starts a stopped container |

### SSH Commands

| Command | What It Does |
|---------|-------------|
| `ssh user@host` | Connects to a remote host |
| `ssh user@host command` | Runs a command on a remote host |
| `scp file user@host:path` | Copies a file to a remote host |
| `ssh-keygen` | Generates an SSH key pair |

---

## 12. Troubleshooting

### Problem: `sinfo` shows nodes in `down` or `drain` state

**Fix:** Usually the worker just needs a moment to register with the controller, or it could not start `slurmd`.

```bash
# Look at the worker logs
docker compose logs worker1

# Bring a node back online (from master)
scontrol update nodename=worker1 state=resume
```

### Problem: `munge: MUNGE-CREDENTIAL expired` or `Invalid Credential`

**Fix:** The nodes do not share the same Munge key. Regenerate it **once** on the host and restart:

```bash
# On your laptop
cd ~/slurm-cluster
docker compose down
dd if=/dev/urandom bs=1024 count=1 of=config/munge/munge.key 2>/dev/null
chmod 400 config/munge/munge.key
docker compose up -d
```

### Problem: `munge: Error: No munge.key in /etc/munge` on a worker

**Fix:** The shared key file was not created before starting. Either run the host-side key generation from [Step 3](#generate-the-shared-munge-key-on-your-host-before-starting), or restart with the master first so it auto-generates:

```bash
docker compose down
docker compose up -d   # master starts first and creates the key
```

### Problem: Container fails to start

**Fix:**

```bash
docker compose logs master   # Check what went wrong
docker compose down          # Stop everything
docker compose build --no-cache  # Rebuild from scratch
docker compose up -d
```

### Problem: SSH connection refused between nodes

**Fix:**

```bash
# Make sure sshd is running inside the container
ss -tlnp | grep :22
# If nothing is listening, start it manually:
/usr/bin/sshd
```

### Problem: `permission denied while trying to connect to Docker daemon socket`

**Fix:**

```bash
# Make sure your user is in the docker group
groups $USER
# Should show 'docker' in the list

# If not, add yourself and re-login
sudo usermod -aG docker $USER
# Log out and log back in, or run:
newgrp docker
```

### Problem: `slurmd` dies with `fatal: systemd scope for slurmstepd could not be set`

**Fix:** Arch's SLURM is built with cgroup v2 + systemd-dbus support, but there is no systemd inside the containers. Check the slurmd log:

```bash
docker exec slurm_worker1 tail -20 /var/log/slurm-llnl/slurmd.log
# Expect: error: cgroup_dbus_attach_to_scope: cannot connect to dbus system daemon
#         fatal: systemd scope for slurmstepd could not be set.
```

Two things must be true:

1. `config/cgroup.conf` exists and is mounted (it sets `IgnoreSystemd=yes` so the cgroup plugin uses `mkdir` instead of D-Bus).
2. The containers run with `privileged: true` so `/sys/fs/cgroup` is writable. Without it you get a different error: `unable to create cgroup '/sys/fs/cgroup/system' : Read-only file system`.

```bash
docker compose down
# Make sure cgroup.conf + privileged: true are in place, then:
docker compose up -d
```

### Problem: `slurmd` dies with `The cgroup mountpoint does not align with the current namespace`

**Fix:** This happens when the host cgroup tree is bind-mounted into a container that still uses its own private cgroup namespace. Remove any `- /sys/fs/cgroup:/sys/fs/cgroup:rw` volume and rely on `privileged: true` instead, which mounts a writable cgroup inside the container's own namespace.

### Problem: Job fails with a `cgroup` error

**Fix:** Make sure `slurm.conf` contains the two lines that avoid cgroup process tracking inside Docker, and that `cgroup.conf` is in place:

```bash
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
```

Then restart the cluster (see "Container fails to start" above).

### Problem: `error: Parse error in file /etc/slurm-llnl/slurm.conf` or `unrecognized key: State`

**Fix:** SLURM config files do **not** support line continuation. A directive split across two lines makes the second line's tokens parse as unknown directives (e.g. `State=UP` on its own line → `unrecognized key: State`). Put each directive on a single line. Also make sure `ClusterName=` is set — without it `slurmctld` refuses to start with `fatal: ClusterName needs to be specified`.

---

## 13. Stopping and Cleaning Up

### Stop the Cluster

```bash
# From your laptop (not inside containers)
cd ~/slurm-cluster
docker compose down
```

### Clean Up Everything

```bash
cd ~/slurm-cluster
docker compose down -v    # Remove containers and network
docker image prune -a     # Remove all unused Docker images
```

---

## 14. Summary of What Was Created

```
~/slurm-cluster/
├── Dockerfile                  # Recipe to build the pure-Arch container image
├── docker-compose.yml          # Defines 3-node cluster architecture (privileged)
├── config/
│   ├── slurm.conf              # SLURM configuration (shared on all nodes)
│   ├── cgroup.conf             # Tells the cgroup plugin to skip systemd
│   └── munge/
│       └── munge.key           # Shared secret key (identical on every node)
├── setup/
│   └── entrypoint.sh           # Starts munged/sshd/slurmctld/slurmd
└── shared/
    └── job_scripts/            # Job scripts + outputs, visible on all nodes
```

All of these files are also checked into this repository under **`docker-cluster/`** so you can run the cluster straight from the repo instead of typing them by hand.

---

*Planning to move up to real hardware? See **[`slurm-physical-cluster-setup.md`](slurm-physical-cluster-setup.md)** for the 1-controller + 4-workers guide on Ubuntu 22.04 over a shared Ethernet LAN.*

---

## 15. Docker Official Resources

| Topic | Link |
|-------|------|
| Docker Overview | https://docs.docker.com/get-started/docker-overview/ |
| Docker Getting Started | https://docs.docker.com/get-started/ |
| Dockerfile Reference | https://docs.docker.com/engine/reference/builder/ |
| Docker Compose | https://docs.docker.com/compose/ |
| Docker Networks | https://docs.docker.com/engine/network/ |
| Docker Volumes | https://docs.docker.com/engine/storage/volumes/ |
| Docker CLI Reference | https://docs.docker.com/engine/reference/commandline/docker/ |
| Docker Hub (find images) | https://hub.docker.com/ |

---