# SLURM HPC Cluster Setup Using Docker on Arch Linux

> **Document type:** Technical setup report
> **Author:** Anany
> **Host hardware:** 13th Gen Intel Core i5-13450HX (12+4 cores) @ 4.60 GHz
> **Host OS:** Arch Linux
> **Container OS:** Arch Linux (100% `pacman` — no Ubuntu, no `apt`)
> **Topology:** 1 control node + 2 worker nodes simulated with Docker
> **Last updated:** 17 August 2026
> **Review cadence:** Weekly

> **Related document:** [`slurm-physical-cluster-setup.md`](slurm-physical-cluster-setup.md) documents the deployment of an equivalent cluster on real hardware (1 controller + 4 workers, Ubuntu 22.04, shared Ethernet LAN).

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Objectives](#2-objectives)
3. [Technical Decisions](#3-technical-decisions)
4. [Prerequisites](#4-prerequisites)
5. [Step 1: Install Docker on Arch Linux](#5-step-1-install-docker-on-arch-linux)
6. [Step 2: Docker Concepts Used](#6-step-2-docker-concepts-used)
7. [Step 3: Create the Cluster Configuration Files](#7-step-3-create-the-cluster-configuration-files)
8. [Step 4: Build and Run the Cluster](#8-step-4-build-and-run-the-cluster)
9. [Step 5: Connect to the Nodes](#9-step-5-connect-to-the-nodes)
10. [Step 6: Verify the Cluster](#10-step-6-verify-the-cluster)
11. [Step 7: Submit and Test Jobs](#11-step-7-submit-and-test-jobs)
12. [Command Reference](#12-command-reference)
13. [Troubleshooting](#13-troubleshooting)
14. [Stopping and Cleaning Up](#14-stopping-and-cleaning-up)
15. [Repository Layout](#15-repository-layout)
16. [Docker Official Resources](#16-docker-official-resources)

---

## 1. Executive Summary

I built a three-node SLURM cluster entirely as Docker containers on an Arch Linux host, in order to validate the SLURM/Munge/SSH configuration approach before deploying to physical machines. The cluster consists of one control container (`master`, running `slurmctld` + `slurmd`) and two worker containers (`worker1`, `worker2`, running `slurmd`), all based on `archlinux:latest` and connected over a private Docker bridge network.

This report documents the design decisions, the configuration files I created, and the verification and job-testing steps I carried out. It is reviewed and updated on a weekly cadence.

---

## 2. Objectives

- Build a working multi-node SLURM cluster on a single laptop using Docker
- Exercise the same SLURM, Munge, and SSH concepts used in the physical deployment
- Run the containers without systemd, starting only the daemons required
- Verify scheduling, job submission, and output retrieval across simulated nodes

---

## 3. Technical Decisions

### Why Docker for SLURM?

I used Docker to simulate a multi-node cluster without buying three physical machines. Each container behaves as an independent node with its own hostname, network address, and services, while remaining cheap to create, destroy, and recreate. This let me validate the configuration pipeline before applying it to real hardware.

### Why Arch Linux inside the Containers?

I chose pure Arch Linux (`archlinux:latest`) as the container base for two reasons:

1. **Lower CPU and RAM usage.** The earlier version of this setup ran `systemd` (`command: /sbin/init`) as the main process in every container. Booting a full init system three times wastes cycles. My approach starts only the daemons actually needed (`munged`, `sshd`, `slurmctld`, `slurmd`) via an entrypoint script, with no init process.
2. **One package manager everywhere.** The host already uses `pacman`; the containers do too. This avoids `apt`/Ubuntu mismatch and keeps the tooling consistent.

> **Note:** the containers run their own rolling Arch userland. The host Arch Linux is not modified.

### SSH (Secure Shell)

SSH provides authenticated, encrypted remote access between nodes. I configured passwordless SSH so the master can reach the workers without prompting — this mirrors what SLURM's process-launching expects on real hardware.

> **Reference:** https://man.archlinux.org/man/ssh.1

### Munge

Munge authenticates inter-node communication by signing and verifying credentials with a shared secret key. Every node must hold the same key; a node without it is rejected. I ensured a single, identical key was mounted into all three containers.

### SLURM

SLURM (Simple Linux Utility for Resource Management) is the job scheduler. It decides which jobs run on which nodes, when they start, and how much CPU/RAM each receives. On Arch the package is `slurm-llnl`.

> **Reference:**
> - https://slurm.schedmd.com/documentation.html
> - Arch package: https://archlinux.org/packages/extra/x86_64/slurm-llnl/
> - ArchWiki: https://wiki.archlinux.org/title/Slurm

---

## 4. Prerequisites

- A laptop running **Arch Linux**
- At least **8 GB RAM** (16 GB recommended)
- **20 GB free disk space**
- An internet connection

---

## 5. Step 1: Install Docker on Arch Linux

### 5.1 Install from the Official Repositories

Docker is available in the official Arch repositories; no third-party repositories are needed.

```bash
# Update the system first (always before installing new packages)
sudo pacman -Syu

# Install Docker and Docker Compose
sudo pacman -S docker docker-compose
```

> **Note:** the installer may ask for a provider choice (such as `docker` vs `docker-nvidia`). I accepted the default.

### 5.2 Enable and Start the Services

```bash
sudo systemctl enable docker.service
sudo systemctl start docker.service

sudo systemctl enable containerd.service
sudo systemctl start containerd.service
```

### 5.3 Grant the User Docker Access

By default only root can run Docker commands. I added my user to the `docker` group so the daemon can be driven without `sudo`:

```bash
sudo usermod -aG docker $USER

# Apply the group change immediately (or log out and back in)
newgrp docker
```

> **Reference:** https://docs.docker.com/engine/install/

### 5.4 Verify the Installation

```bash
docker --version
docker run hello-world
```

`docker run hello-world` printed "Hello from Docker!", confirming the daemon is functional.

---

## 6. Step 2: Docker Concepts Used

### Images vs Containers

- **Image:** a template describing the filesystem and default command of a container.
- **Container:** a running instance of an image.

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

> **Reference:** https://docs.docker.com/engine/reference/commandline/docker/

### Dockerfile

A Dockerfile declares the build steps for an image: which base image to use, which packages to install, which files to copy, and what command to run on start.

> **Reference:** https://docs.docker.com/engine/reference/builder/

### docker-compose

docker-compose defines and manages multi-container applications declaratively. I defined all three nodes in a single `docker-compose.yml` and started them with one command.

> **Reference:** https://docs.docker.com/compose/

---

## 7. Step 3: Create the Cluster Configuration Files

> **Shortcut:** ready-made copies of every file below are checked into this repository under **`docker-cluster/`**. I used these to avoid retyping:
> ```bash
> cp -r ~/paanduv_hpc/docker-cluster ~/slurm-cluster
> cd ~/slurm-cluster
> mkdir -p config/munge shared/job_scripts
> ```
> The sections below explain what each file does.

### 7.1 Project Directory

```bash
mkdir -p ~/slurm-cluster
cd ~/slurm-cluster

mkdir -p config/munge setup shared
```

### 7.2 File 1: `Dockerfile`

This file builds the container image: base `archlinux:latest`, SLURM/SSH/Munge installed with `pacman`, and an entrypoint that starts the daemons.

```bash
nano ~/slurm-cluster/Dockerfile
```

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

> **Why the `id ... || {...}` guard?** Installing `slurm-llnl` on Arch already creates the `slurm` and `munge` users via pacman's `sysusers` hook. A plain `groupadd slurm` would fail with `groupadd: group 'slurm' already exists` and stop the build. Guarding each command with `id ... >/dev/null 2>&1 ||` makes the build idempotent.
>
> **Why `inetutils`?** `hostname` is not in the base image (Arch splits it into `inetutils`); the job test scripts and SSH checks need it.

> **Why no systemd?** `systemd` cannot start services in the official Arch Docker image without extra privileges, and booting it three times wastes CPU/RAM. The entrypoint script starts exactly the daemons needed.

### 7.3 File 2: `docker-compose.yml`

This file defines the three containers, the private bridge network, and the shared volumes.

```bash
nano ~/slurm-cluster/docker-compose.yml
```

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

> **Bridge network:** the containers form a private network (10.0.0.0/24) that only they can see; they are isolated from the outside world.

> **Why `privileged: true`?** Arch's `slurm-llnl` is compiled with cgroup v2 + systemd support. `slurmd` refuses to start unless it can manage a cgroup tree, which inside a default container is mounted read-only. Running the containers **privileged** gives them a writable `/sys/fs/cgroup`. Without it, `slurmd` exits with `fatal: systemd scope for slurmstepd could not be set` (see [Troubleshooting](#13-troubleshooting)). This is a sandbox; privileged containers should not be used for untrusted workloads.

> **What the volumes do:**
> - `./config/slurm.conf` is mounted into **all** nodes at `/etc/slurm-llnl/slurm.conf` (note the Arch path is `slurm-llnl`, not `slurm`). One file, shared automatically.
> - `./config/cgroup.conf` is mounted into **all** nodes at `/etc/slurm-llnl/cgroup.conf`; it tells the cgroup plugin how to work without systemd (File 4).
> - `./config/munge` is mounted at `/etc/munge` on **all** nodes, so every node uses the **same** Munge key. No manual key copying is needed.
> - `./shared` is mounted at `/shared` on all nodes, so job scripts and output files are visible everywhere.

> **Reference:** https://docs.docker.com/engine/network/

### 7.4 File 3: `config/slurm.conf`

This is the core SLURM configuration, defining the cluster topology.

```bash
nano ~/slurm-cluster/config/slurm.conf
```

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

> **Note:** I allocated 2 CPUs and 4 GB RAM per node. The i5-13450HX has 12+4 cores, so the `CPUs=` values can be raised if the scheduler should hand out more.
>
> **Note:** on Arch the config file lives in `/etc/slurm-llnl/`, which is where SLURM looks by default on this distro.

### 7.5 File 4: `config/cgroup.conf`

Arch's `slurm-llnl` is compiled against cgroup v2 + systemd. When `slurmd` starts it tries to create a systemd "scope" over D-Bus for `slurmstepd`; inside a container there is no systemd and no `/run/dbus/system_bus_socket`, so it dies with `fatal: systemd scope for slurmstepd could not be set`. This file instructs the cgroup plugin to prepare the cgroup tree itself instead of asking systemd.

```bash
nano ~/slurm-cluster/config/cgroup.conf
```

```bash
# Arch's SLURM wants to ask systemd (via D-Bus) to create a cgroup scope for
# slurmstepd. There is no systemd inside a container, so have the cgroup
# plugin create the directories manually instead. Requires a writable cgroup
# filesystem, which is why the containers run with privileged: true.
CgroupPlugin=cgroup/v2
IgnoreSystemd=yes
```

> **What `IgnoreSystemd=yes` does:** it skips the D-Bus call to systemd and performs a plain `mkdir` for the slurmstepd cgroup directories. Combined with `privileged: true` (writable `/sys/fs/cgroup`), `slurmd` starts normally inside the container.

### 7.6 File 5: `setup/entrypoint.sh`

Because there is no systemd inside the containers, this script starts the daemons directly on every container start.

```bash
nano ~/slurm-cluster/setup/entrypoint.sh
```

```bash
#!/bin/bash
# Starts Munge, SSH and the SLURM daemons.
# No systemd is used inside the containers, so nothing heavy boots up.
set -e

# ${HOSTNAME} is a bash built-in — the hostname binary needs inetutils.
echo "=== ${HOSTNAME} starting (role: ${NODE_ROLE:-worker}) ==="

# Sandbox convenience: fixed root password so ssh-copy-id / SSH login works.
echo 'root:hpc123' | chpasswd

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

I marked the script executable:

```bash
chmod +x ~/slurm-cluster/setup/entrypoint.sh
```

### 7.7 Generate the Shared Munge Key

The Munge key must be **identical on every node**. I generated it once on the host and let every container mount it:

```bash
cd ~/slurm-cluster

dd if=/dev/urandom bs=1024 count=1 of=config/munge/munge.key 2>/dev/null
chmod 400 config/munge/munge.key
```

> **Note:** the master also auto-generates a key if none exists, so the cluster still boots without this step; generating it up front is more predictable.

### 7.8 Shared Job Folder

```bash
cd ~/slurm-cluster
mkdir -p shared/job_scripts
```

---

## 8. Step 4: Build and Run the Cluster

### 8.1 Build the Image

```bash
cd ~/slurm-cluster
docker compose build
```

The first build takes a few minutes: Docker downloads the Arch base image and installs SLURM, Munge, and SSH with `pacman`. The result is a reusable image that can be started many times.

> **Reference:** https://docs.docker.com/engine/reference/commandline/build/

### 8.2 Start the Three Nodes

```bash
docker compose up -d
```

The `-d` flag runs the containers detached, in the background.

> **Note:** all three containers run **privileged** (see the `docker-compose.yml` rationale) so `slurmd` can manage a writable cgroup filesystem.

> **Reference:** https://docs.docker.com/reference/cli/docker/compose/up/

### 8.3 Confirm All Nodes Are Up

```bash
docker ps
```

All three containers were listed as running:

```
NAMES             STATUS          PORTS
slurm_master      Up X seconds
slurm_worker1     Up X seconds
slurm_worker2     Up X seconds
```

For any container that is not running, the logs show why:

```bash
docker compose logs master
docker compose logs worker1
docker compose logs worker2
```

The expected log sequence is `Starting munged...`, `Starting sshd...`, `Starting slurmctld + slurmd...`, and finally `=== hostname is ready ===`.

---

## 9. Step 5: Connect to the Nodes

### 9.1 Open a Terminal on the Master

```bash
docker exec -it slurm_master bash
```

This places me inside the master container as root (prompt `root@master:/#`).

> **What `docker exec -it` means:** `exec` runs a command in a container, `-i` keeps STDIN open (interactive), and `-t` allocates a pseudo-TTY.

### 9.2 Sanity Checks

Because the entrypoint started the daemons, no further configuration was required. I confirmed the services:

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

### 9.3 Passwordless SSH Between Nodes

SLURM communicates over its own protocol (port 6817), but I also set up passwordless SSH to inspect the workers directly.

> **The root password on every node is `hpc123`** (set by the entrypoint). This is a sandbox; it is not reused anywhere real.

```bash
# Generate an SSH key (press Enter for all prompts)
ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa

# Copy the public key to authorized_keys on yourself
cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys

# Copy key to worker1 (type the password: hpc123)
ssh-copy-id -o StrictHostKeyChecking=no root@worker1

# Copy key to worker2 (type the password: hpc123)
ssh-copy-id -o StrictHostKeyChecking=no root@worker2
```

I verified each connection returns the worker hostname without a password:

```bash
ssh worker1 hostname
# worker1

ssh worker2 hostname
# worker2
```

---

## 10. Step 6: Verify the Cluster

### 10.1 Node Status

Still inside the master container:

```bash
sinfo
```

I observed the expected output:

```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
normal*      up   infinite      2   idle worker[1-2]
all          up   infinite      3   idle master,worker[1-2]
```

### 10.2 Controller State

```bash
# Show detailed node info
scontrol show nodes

# Show current jobs (should be empty)
squeue
```

> **If nodes show as `down`:** the workers may simply need a few seconds to register; re-running `sinfo` usually resolves it. If they stay `down`, see the [Troubleshooting](#13-troubleshooting) section.

---

## 11. Step 7: Submit and Test Jobs

### 11.1 Interactive Job

```bash
# Run hostname on the worker nodes
srun --nodes=2 hostname
```

### 11.2 Test Script

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

### 11.3 Submit and Monitor

```bash
sbatch /shared/job_scripts/test_job.sh
squeue
```

Expected queue output:

```
JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
   123   normal test_job   root PD       0:00      2 worker[1-2]
```

### 11.4 Job Output

```bash
cat /shared/job_scripts/output_*.out
```

The output showed the job ran on both `worker1` and `worker2`, confirming the batch path works across the simulated nodes.

---

## 12. Command Reference

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

## 13. Troubleshooting

The following issues and their resolutions are recorded for future review.

### Problem: `sinfo` shows nodes in `down` or `drain` state

**Resolution:** the worker usually needs a moment to register with the controller, or `slurmd` failed to start.

```bash
# Look at the worker logs
docker compose logs worker1

# Bring a node back online (from master)
scontrol update nodename=worker1 state=resume
```

### Problem: `munge: MUNGE-CREDENTIAL expired` or `Invalid Credential`

**Resolution:** the nodes do not share the same Munge key. I regenerated it **once** on the host and restarted:

```bash
# On the host
cd ~/slurm-cluster
docker compose down
dd if=/dev/urandom bs=1024 count=1 of=config/munge/munge.key 2>/dev/null
chmod 400 config/munge/munge.key
docker compose up -d
```

### Problem: `munge: Error: No munge.key in /etc/munge` on a worker

**Resolution:** the shared key was not created before starting. Either generate it as in [Section 7.7](#77-generate-the-shared-munge-key), or restart with the master first so it auto-generates:

```bash
docker compose down
docker compose up -d   # master starts first and creates the key
```

### Problem: Container fails to start

**Resolution:**

```bash
docker compose logs master   # Check what went wrong
docker compose down          # Stop everything
docker compose build --no-cache  # Rebuild from scratch
docker compose up -d
```

### Problem: SSH connection refused between nodes

**Resolution:**

```bash
# Make sure sshd is running inside the container
ss -tlnp | grep :22
# If nothing is listening, start it manually:
/usr/bin/sshd
```

### Problem: `permission denied while trying to connect to Docker daemon socket`

**Resolution:**

```bash
# Make sure the user is in the docker group
groups $USER
# Should show 'docker' in the list

# If not, add the user and re-login
sudo usermod -aG docker $USER
# Log out and log back in, or run:
newgrp docker
```

### Problem: `slurmd` dies with `fatal: systemd scope for slurmstepd could not be set`

**Resolution:** Arch's SLURM is built with cgroup v2 + systemd-dbus support, but there is no systemd inside the containers. The slurmd log confirms it:

```bash
docker exec slurm_worker1 tail -20 /var/log/slurm-llnl/slurmd.log
# Expect: error: cgroup_dbus_attach_to_scope: cannot connect to dbus system daemon
#         fatal: systemd scope for slurmstepd could not be set.
```

Two conditions must hold:

1. `config/cgroup.conf` exists and is mounted (it sets `IgnoreSystemd=yes`, so the cgroup plugin uses `mkdir` instead of D-Bus).
2. The containers run with `privileged: true` so `/sys/fs/cgroup` is writable. Without it the error is `unable to create cgroup '/sys/fs/cgroup/system' : Read-only file system`.

```bash
docker compose down
# Make sure cgroup.conf + privileged: true are in place, then:
docker compose up -d
```

### Problem: `slurmd` dies with `The cgroup mountpoint does not align with the current namespace`

**Resolution:** this happens when the host cgroup tree is bind-mounted into a container that still uses its own private cgroup namespace. I removed any `- /sys/fs/cgroup:/sys/fs/cgroup:rw` volume and relied on `privileged: true` instead, which mounts a writable cgroup inside the container's own namespace.

### Problem: Job fails with a `cgroup` error

**Resolution:** ensure `slurm.conf` contains the two lines that avoid cgroup process tracking inside Docker, and that `cgroup.conf` is in place:

```bash
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
```

Then restart the cluster (see "Container fails to start" above).

### Problem: `error: Parse error in file /etc/slurm-llnl/slurm.conf` or `unrecognized key: State`

**Resolution:** SLURM config files do **not** support line continuation. A directive split across two lines makes the second line's tokens parse as unknown directives (e.g. `State=UP` on its own line → `unrecognized key: State`). Each directive must sit on a single line, and `ClusterName=` must be set — without it `slurmctld` refuses to start with `fatal: ClusterName needs to be specified`.

---

## 14. Stopping and Cleaning Up

### Stop the Cluster

```bash
# From the host (not inside containers)
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

## 15. Repository Layout

```
~/slurm-cluster/
├── Dockerfile                  # Builds the pure-Arch container image
├── docker-compose.yml          # Defines the 3-node cluster architecture (privileged)
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

These files are also checked into this repository under **`docker-cluster/`**, so the cluster can be run directly from the repo.

---

*Related: see **[`slurm-physical-cluster-setup.md`](slurm-physical-cluster-setup.md)** for the real-hardware deployment (1 controller + 4 workers, Ubuntu 22.04, shared Ethernet LAN).*

---

## 16. Docker Official Resources

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