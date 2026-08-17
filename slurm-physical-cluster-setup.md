# SLURM HPC Cluster Setup on Physical Machines (College Lab)

> **Architecture:** 1 Host (Controller) + 4 Worker Nodes on Different CPUs
> **Environment:** College Lab with Multiple Physical Computers
> **OS:** Ubuntu 22.04 LTS (recommended)
>
> Want a quick test first on a single laptop? See **[`slurm-docker-setup.md`](slurm-docker-setup.md)** — the Docker guide simulates the same 3-node layout with Arch containers.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [What You Need](#2-what-you-need)
3. [Network Planning](#3-network-planning)
4. [Prerequisites on All Machines](#4-prerequisites-on-all-machines)
5. [Step 1: Configure Hostnames and Network](#step-1-configure-hostnames-and-network)
6. [Step 2: Setup SSH Between All Machines](#step-2-setup-ssh-between-all-machines)
7. [Step 3: Install and Configure Munge](#step-3-install-and-configure-munge)
8. [Step 4: Configure slurm.conf](#step-4-configure-slurmconf)
9. [Step 5: Start SLURM Services](#step-5-start-slurm-services)
10. [Step 6: Test the Cluster](#step-6-test-the-cluster)
11. [Step 7: Write and Submit Jobs](#step-7-write-and-submit-jobs)
12. [Commands Cheat Sheet](#commands-cheat-sheet)
13. [Troubleshooting](#troubleshooting)
14. [Quick Reference: Full Setup Sequence](#quick-reference-full-setup-sequence)

---

## 1. Architecture Overview

```
+------------------+
|   HOST NODE      |
|  (Controller)    |
|  192.168.1.100   |
|  slurmctld       |
|  slurmd          |
+--------+---------+
         |
    +----+----+----+----+
    |    |    |    |    |
+---+--+ +---+--+ +---+--+ +---+--+
|W1    | |W2    | |W3    | |W4    |
|CPU A | |CPU B | |CPU C | |CPU D |
|.101  | |.102  | |.103  | |.104  |
|slurmd| |slurmd| |slurmd| |slurmd|
+------+ +------+ +------+ +------+
```

- **Host Node (192.168.1.100):** Runs `slurmctld` (controller daemon). Schedules jobs.
- **Worker 1-4:** Run `slurmd` (worker daemon). Execute jobs assigned by controller.
- **Host also runs `slurmd`** so it can serve the `all` partition (see Step 5).
- All machines are connected to the **same network switch/router**.

---

## 2. What You Need

### Hardware

| Role | Machine | Recommended | Min RAM |
|------|---------|-------------|---------|
| Host | Any CPU | 8 GB RAM, 50 GB disk | 4 GB |
| Worker 1 | CPU Type A | 8 GB RAM | 4 GB |
| Worker 2 | CPU Type B | 8 GB RAM | 4 GB |
| Worker 3 | CPU Type C | 8 GB RAM | 4 GB |
| Worker 4 | CPU Type D | 8 GB RAM | 4 GB |

### Software (on ALL 5 machines)

- Ubuntu 22.04 LTS
- `slurm-wlm` package
- `munge` package
- `openssh-server` package
- `net-tools` package (optional, for `netstat`)
- **The same username with sudo rights on every machine**

> **Important:** SLURM runs jobs on the workers as *your* user. If you submit a job as user `alice` from the host, that user must exist on every worker, otherwise job launch fails with `user not found`. Use one identical username everywhere.

---

## 3. Network Planning

### Assign Static IPs

Choose a subnet. Here we use `192.168.1.0/24`:

| Machine | Hostname | IP Address | Role |
|---------|----------|------------|------|
| Host | `host` | 192.168.1.100 | Controller |
| Worker 1 | `worker1` | 192.168.1.101 | Compute |
| Worker 2 | `worker2` | 192.168.1.102 | Compute |
| Worker 3 | `worker3` | 192.168.1.103 | Compute |
| Worker 4 | `worker4` | 192.168.1.104 | Compute |

> **Note:** Change these IPs to match your college network. Ask your lab admin for the subnet range.

### Pre-flight Checklist (avoids 90% of "why is it down?" problems)

```bash
# 1. Time must be synchronized on ALL machines
#    Munge credentials are timestamped; a skewed clock causes
#    "MUNGE-CREDENTIAL expired" errors immediately.
sudo timedatectl set-ntp true
timedatectl status      # NTP service: active

# 2. Consistent username + sudo on every machine (see Section 2)

# 3. If ufw (firewall) is active, allow the SLURM + SSH ports
sudo ufw allow 22/tcp        # SSH
sudo ufw allow 6817/tcp      # slurmctld <-> slurmd
sudo ufw allow 6818:6819/tcp # slurmd <-> slurmstepd (job I/O)
sudo ufw status              # verify
```

---

## 4. Prerequisites on All Machines

Run these commands on **every machine** (host + all 4 workers):

### Update System

```bash
sudo apt update && sudo apt upgrade -y
```

### Install Required Packages

```bash
sudo apt install -y \
    slurm-wlm \
    munge \
    openssh-server \
    net-tools \
    vim \
    sudo \
    iputils-ping \
    iproute2
```

> **Why not `cluster-wait` / `libmunge-dev`?** `cluster-wait` is not an Ubuntu package (a common copy-paste trap that makes `apt` fail). `libmunge-dev` is only needed if you *compile* software against Munge — not for running SLURM.

### Create Required Users and Directories

```bash
# Create slurm user (the slurm-wlm package usually creates it; be safe)
sudo useradd -m -s /bin/bash slurm 2>/dev/null || true

# Shared directory (only needed if you set up NFS shared storage)
sudo mkdir -p /shared/home
sudo chown slurm:slurm /shared/home
sudo chmod 755 /shared/home

# Log directories
sudo mkdir -p /var/log/slurm
sudo chown slurm:slurm /var/log/slurm

# State/spool directories (must match slurm.conf in Step 4)
sudo mkdir -p /var/spool/slurmctld /var/spool/slurmd
sudo chown slurm:slurm /var/spool/slurmctld /var/spool/slurmd
```

---

## Step 1: Configure Hostnames and Network

### On Every Machine: Set Hostname

```bash
# On the HOST machine
sudo hostnamectl set-hostname host

# On WORKER 1
sudo hostnamectl set-hostname worker1

# On WORKER 2
sudo hostnamectl set-hostname worker2

# On WORKER 3
sudo hostnamectl set-hostname worker3

# On WORKER 4
sudo hostnamectl set-hostname worker4
```

### On Every Machine: Edit `/etc/hosts`

```bash
sudo vim /etc/hosts
```

Add these lines to **all 5 machines**:

```
192.168.1.100   host
192.168.1.101   worker1
192.168.1.102   worker2
192.168.1.103   worker3
192.168.1.104   worker4
```

> **Important:** The hostname of each machine **must exactly match** the `NodeName=` entries in `slurm.conf` (Step 4). SLURM is strict about this.

### On Every Machine: Verify Hostname Resolution

```bash
ping -c 2 host
ping -c 2 worker1
ping -c 2 worker2
ping -c 2 worker3
ping -c 2 worker4
```

All pings should succeed. If not, check your `/etc/hosts` and network cable connections.

---

## Step 2: Setup SSH Between All Machines

SSH lets the host reach the workers (and each worker reach the host) without typing a password. This is also what lets you distribute config files later.

### On HOST: Generate SSH Key

```bash
# Generate SSH key (press Enter for all prompts)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
```

### On HOST: Copy Key to All Workers

```bash
# Copy to each worker (you will be asked for the password once)
ssh-copy-id user@worker1
ssh-copy-id user@worker2
ssh-copy-id user@worker3
ssh-copy-id user@worker4
```

Replace `user` with the username you use on each worker (it should be the same on all machines).

### On Each WORKER: Copy Key to Host

```bash
# On worker1
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
ssh-copy-id user@host

# Repeat on worker2, worker3, worker4
```

### Test SSH (from Host)

```bash
ssh worker1 hostname
ssh worker2 hostname
ssh worker3 hostname
ssh worker4 hostname
```

Each should return the hostname of that machine without asking for a password.

> **Note:** If your `user` account needs to become root during the steps below, make sure it has sudo rights on every machine (`sudo -v` works without errors).

---

## Step 3: Install and Configure Munge

Munge provides authentication for SLURM. All nodes **must** share the **same munge key**, with correct ownership (`munge:munge`) and mode **0400**.

> **`chmod 400`, not `0700`:** Munge expects the key file to be read-only for the `munge` user (`0400`). An overly-open mode makes `munged` refuse to start.

### On HOST: Generate Munge Key

```bash
# Generate a random key
sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key

# Set correct ownership + permissions
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key

# Start munge
sudo systemctl enable --now munge
```

### On HOST: Copy Munge Key to All Workers

The key is only readable by root, so it must be piped through your SSH connection and written with `sudo tee` on each worker. This avoids the "root has no SSH keys" trap and leaves no plaintext copy behind:

```bash
# From the host, run once per worker (replace user@workerX):
sudo cat /etc/munge/munge.key | ssh user@worker1 \
  "sudo tee /etc/munge/munge.key > /dev/null && \
   sudo chown munge:munge /etc/munge/munge.key && \
   sudo chmod 400 /etc/munge/munge.key"
```

Repeat for `worker2`, `worker3`, `worker4`.

> **Why not `sudo scp`?** `sudo scp` runs as root and uses *root's* SSH keys, which were never set up in Step 2 — it will fail or prompt for passwords unexpectedly. The pipe above reuses your user's keys.

### On Each WORKER: Start Munge

```bash
# Create munge run directory if missing
sudo mkdir -p /run/munge
sudo chown munge:munge /run/munge
sudo chmod 0700 /run/munge

# Start munge
sudo systemctl enable --now munge
```

### Verify Munge (on any machine)

```bash
# Test munge authentication
munge --version
# Should output: MUNGE UTTU 0.9.x

# Test munge credential
munge | unmunge
# Should end with: MUNGE: Success
```

---

## Step 4: Configure slurm.conf

### On HOST: Create slurm.conf

```bash
sudo vim /etc/slurm/slurm.conf
```

Paste this entire configuration:

```bash
#==========================================================
# SLURM Configuration for 1 Host + 4 Worker Cluster
#==========================================================

#--- CONTROLLER ---
SlurmctldHost=host
ControlMachine=host

#--- LOGGING ---
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

#--- AUTHENTICATION ---
AuthType=auth/munge
CredType=cred/munge

#--- SCHEDULER ---
SchedulerType=sched/backfill
SelectType=select/cons_tres

#--- STATE STORAGE ---
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDirectory=/var/spool/slurmd

#--- TIMERS ---
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
Waittime=0

#--- CLUSTER TOPOLOGY ---
# NodeName=Address CPUs Cores RealMemory(MB) State
#
# Adjust CPUs, Cores, and RealMemory to match
# the ACTUAL hardware of each machine.
# RealMemory is in MEGABYTES (see "How to Find Your Hardware Specs" below).

NodeName=host    CPUs=8  CoresPerSocket=4 RealMemory=7800 State=IDLE
NodeName=worker1 CPUs=8  CoresPerSocket=4 RealMemory=7800 State=IDLE
NodeName=worker2 CPUs=16 CoresPerSocket=8 RealMemory=15800 State=IDLE
NodeName=worker3 CPUs=8  CoresPerSocket=4 RealMemory=7800 State=IDLE
NodeName=worker4 CPUs=12 CoresPerSocket=6 RealMemory=11800 State=IDLE

#--- PARTITIONS (job queues) ---
# PartitionName=Name  Nodes=NodeList  Default=Yes/No  MaxTime=Time  State=UP

PartitionName=normal Nodes=worker1,worker2,worker3,worker4 Default=YES MaxTime=INFINITE State=UP
PartitionName=all    Nodes=host,worker1,worker2,worker3,worker4 Default=NO MaxTime=INFINITE State=UP
PartitionName=big    Nodes=worker2,worker4 Default=NO MaxTime=INFINITE State=UP
```

Save and exit.

### How to Find Your Hardware Specs

Run these commands on each machine to find the correct values:

```bash
# Number of CPUs (logical cores)
nproc
# or
lscpu | grep "^CPU(s):"

# Cores per socket
lscpu | grep "^Core(s) per socket:"

# Sockets (physical CPUs)
lscpu | grep "^Socket(s):"

# Total RAM in MB
free -m | awk '/Mem:/ {print $2}'
```

**Example:** If `nproc` returns 16 and `Core(s) per socket` returns 8 and `Socket(s)` returns 1, then:
```
NodeName=worker2 CPUs=16 CoresPerSocket=8 RealMemory=15800 State=IDLE
```

### Copy slurm.conf to All Workers

`/etc/slurm/` is root-owned, so you cannot `scp` straight into it. Pipe the file through SSH and write it with `sudo tee` instead:

```bash
# From the host, run once per worker:
cat /etc/slurm/slurm.conf | ssh user@worker1 "sudo tee /etc/slurm/slurm.conf > /dev/null"

# Repeat for worker2, worker3, worker4
```

---

## Step 5: Start SLURM Services

> `service` is a friendly wrapper around `systemctl` on Ubuntu; both work. Start order matters: **munge first, then slurmctld on the host, then slurmd everywhere**.

### On HOST: Start Controller

```bash
# Start slurmctld (controller daemon)
sudo service slurmctld start

# The host is also a node (partition "all"), so it needs slurmd too
sudo service slurmd start

# Check status
sudo service slurmctld status
sudo service slurmd status
```

### On Each WORKER: Start slurmd

```bash
# On worker1
sudo service slurmd start
sudo service slurmd status

# Repeat on worker2, worker3, worker4
```

### Verify Cluster Status (from Host)

```bash
sinfo
```

Expected output:
```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
normal*      up   infinite      4   idle worker[1-4]
all          up   infinite      5   idle host,worker[1-4]
big          up   infinite      2   idle worker[2,4]
```

If nodes show `down` or `drain`, check the troubleshooting section.

> **Not using the host for jobs?** Remove `host` from the `all` partition (or leave it — jobs just won't be scheduled there unless requested).

---

## Step 6: Test the Cluster

### Test 1: Run hostname on all worker nodes

```bash
srun --nodes=4 hostname
```

Should output:
```
worker1
worker2
worker3
worker4
```

### Test 2: Check node details

```bash
scontrol show nodes
```

### Test 3: Check partition details

```bash
scontrol show partitions
```

### Test 4: Simple batch job

```bash
cat > test_job.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=test_job
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:05:00
#SBATCH --output=result_%j.out
#SBATCH --error=error_%j.out

echo "=== SLURM Job Test ==="
echo "Job ID: $SLURM_JOB_ID"
echo "Job Name: $SLURM_JOB_NAME"
echo "Running on nodes: $SLURM_NODELIST"
echo "Number of nodes: $SLURM_NNODES"
echo "Host: $(hostname)"
echo "Date: $(date)"
echo "CPU: $(lscpu | grep 'Model name' | awk -F: '{print $2}')"
echo "========================="
EOF

sbatch test_job.sh
```

Wait a few seconds, then check output:
```bash
cat result_*.out
```

---

## Step 7: Write and Submit Jobs

### Example 1: Parallel Computation (Matrix Multiply)

```bash
cat > matrix_job.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=matrix_multiply
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:10:00
#SBATCH --output=matrix_%j.out

echo "Running matrix multiplication on $SLURM_NNODES nodes"
echo "Nodes: $SLURM_NODELIST"
echo "Start time: $(date)"

# Simulate matrix operations
for i in $(seq 1 1000000); do
    result=$((i * i))
done

echo "End time: $(date)"
echo "Job completed successfully!"
EOF

sbatch matrix_job.sh
```

### Example 2: Using MPI (Message Passing Interface)

First install MPI on all nodes:
```bash
sudo apt install -y openmpi-bin libopenmpi-dev
```

Create MPI program:
```bash
cat > hello_mpi.c << 'EOF'
#include <mpi.h>
#include <stdio.h>

int main(int argc, char** argv) {
    int rank, size;
    char processor_name[256];
    int name_len;

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    MPI_Get_processor_name(processor_name, &name_len);

    printf("Hello from processor %s, rank %d out of %d processors\n",
           processor_name, rank, size);

    MPI_Finalize();
    return 0;
}
EOF
```

Compile:
```bash
mpicc -o hello_mpi hello_mpi.c
```

Create the SLURM script:

> **Use `srun`, not `mpirun`, inside a SLURM script.** `srun` lets SLURM launch each MPI rank exactly on an allocated core. A bare `mpirun` instead tries to SSH between nodes itself and frequently fights with SLURM for resources (wrong task counts, doubled processes).

```bash
cat > mpi_job.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=mpi_hello
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:05:00
#SBATCH --output=mpi_%j.out

srun ./hello_mpi
EOF

sbatch mpi_job.sh
```

After it finishes, check the output:
```bash
cat mpi_*.out
# You should see 8 "Hello from processor ..." lines (2 nodes x 4 ranks)
```

### Example 3: Array Jobs (Run Same Script with Different Parameters)

```bash
cat > array_job.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=array_test
#SBATCH --array=1-10
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:05:00
#SBATCH --output=array_%A_%a.out

echo "Task $SLURM_ARRAY_TASK_ID running on $(hostname)"
echo "Processing input file: input_$SLURM_ARRAY_TASK_ID.txt"

# Your computation here
sleep 5

echo "Task $SLURM_ARRAY_TASK_ID completed"
EOF

sbatch array_job.sh
```

> `%A` = array job ID, `%a` = task index. This gives each of the 10 tasks its own log file.

---

## Commands Cheat Sheet

### SLURM Job Management

| Command | Purpose |
|---------|---------|
| `sinfo` | View cluster and node status |
| `squeue` | View job queue |
| `sbatch script.sh` | Submit batch job |
| `srun --nodes=N command` | Run interactive job |
| `scancel JOB_ID` | Cancel a job |
| `scancel -u username` | Cancel all jobs of a user |
| `scontrol show nodes` | Detailed node info |
| `scontrol show partitions` | Detailed partition info |
| `scontrol show jobs` | Detailed job info |
| `sacct` | Job accounting (requires slurmdbd — see note) |
| `sprio` | View job priorities |
| `sping host` | Ping nodes via SLURM |

> **`sacct` needs accounting configured.** Without a running `slurmdbd` + MariaDB, `sacct` reports "No accounting storage configured" and returns nothing. That setup is out of scope here — `sacct` will still work after you configure accounting later.

### Useful Flags

```bash
# Submit job with specific partition
sbatch -p big script.sh

# Request specific nodes
sbatch -w worker2,worker4 script.sh

# Exclude specific nodes
sbatch -x worker1 script.sh

# Set job name
sbatch --job-name=my_job script.sh

# Set output file
sbatch --output=log_%j.out script.sh

# Set time limit
sbatch --time=02:00:00 script.sh

# Cancel all my jobs
scancel -u $USER
```

### Monitoring Commands

```bash
# Watch queue in real-time
watch -n 2 squeue

# Check node utilization
sinfo -N -l

# Check who is using what
squeue -u username

# Check SLURM daemon logs
sudo tail -f /var/log/slurm/slurmctld.log    # On host
sudo tail -f /var/log/slurm/slurmd.log       # On worker
```

---

## Troubleshooting

### Problem: `sinfo` shows nodes in `down` state

**Fix:**
```bash
# On host
sudo scontrol update nodename=worker1 state=resume
```

If still down, check slurmd on the worker:
```bash
# On the worker
sudo service slurmd status
sudo service slurmd restart
# And check its log
sudo tail -20 /var/log/slurm/slurmd.log
```

### Problem: `sbatch` gives "slurmctld not running"

**Fix:**
```bash
# On host
sudo service slurmctld status
sudo service slurmctld restart

# Check logs
sudo tail -20 /var/log/slurm/slurmctld.log
```

### Problem: `munge: MUNGE-CREDENTIAL not valid` or `expired`

**Fix:** Most often a **clock-skew** problem or a **different key** on some node.

```bash
# 1. Synchronize time on EVERY machine (common root cause)
sudo timedatectl set-ntp true
timedatectl status

# 2. Regenerate key on HOST
sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key

# 3. Copy to ALL workers (the sudo-tee pipe from Step 3)

# 4. Restart munge everywhere
sudo systemctl restart munge    # on every machine

# 5. Verify
munge | unmunge                # should end with: MUNGE: Success
```

### Problem: Jobs stuck in "pending" state forever

**Possible causes:**
1. No nodes available — check `sinfo`
2. Resources exhausted — check `squeue`
3. Partition mismatch — ensure job requests correct partition

```bash
# Check why job is pending
scontrol show job JOB_ID
# Look for "Reason:" in the output
```

### Problem: Job fails with `user not found` / `setuid: no such user`

**Fix:** SLURM runs the job on each worker as your submitting user. Create that user on **every** worker:

```bash
sudo useradd -m -s /bin/bash alice   # same username you use on the host
```

Or submit as a user that exists everywhere (e.g. `root` is easiest to test with).

### Problem: SSH connection fails between nodes

**Fix:**
```bash
# On the failing node
sudo service ssh status
sudo service ssh start

# Test connectivity
ping worker1
ping host
```

### Problem: `slurmd` won't start on worker

**Fix:**
```bash
# Check if port 6817 is in use
sudo netstat -tlnp | grep 6817

# Check permissions
ls -la /var/spool/slurmd/
ls -la /etc/slurm/

# Check config
slurmd -C  # Shows computed configuration
```

### Problem: Different CPU types cause issues

If your workers have different CPU architectures, add **Features** to each node in `slurm.conf`:
```bash
NodeName=worker1 CPUs=8 Feature="Intel_i5"
NodeName=worker2 CPUs=16 Feature="Intel_i7"
```

Then submit jobs requesting specific features:
```bash
sbatch --constraint="Intel_i7" script.sh
```

---

## Quick Reference: Full Setup Sequence

Run these in order on all machines:

```bash
# === ON ALL 5 MACHINES ===
# 1. Install packages
sudo apt update
sudo apt install -y slurm-wlm munge openssh-server net-tools vim sudo

# 2. Set hostname (different on each machine)
sudo hostnamectl set-hostname <hostname>

# 3. Edit /etc/hosts (add all 5 hostname/IP lines)
sudo vim /etc/hosts

# 4. Synchronize time (Munge requires it!)
sudo timedatectl set-ntp true

# 5. Setup SSH keys (same user on every machine)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
# Copy keys between all machines with ssh-copy-id

# 6. Create SLURM dirs
sudo mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
sudo chown slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd

# === ON HOST ONLY ===
# 7. Generate munge key
sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
sudo systemctl enable --now munge

# 8. Copy munge key to each worker (repeat per worker)
sudo cat /etc/munge/munge.key | ssh user@worker1 \
  "sudo tee /etc/munge/munge.key > /dev/null && sudo chown munge:munge /etc/munge/munge.key && sudo chmod 400 /etc/munge/munge.key"

# 9. Create + distribute slurm.conf (repeat per worker)
sudo vim /etc/slurm/slurm.conf
cat /etc/slurm/slurm.conf | ssh user@worker1 "sudo tee /etc/slurm/slurm.conf > /dev/null"

# 10. Start controller + host slurmd
sudo systemctl enable --now munge
sudo service slurmctld start
sudo service slurmd start

# === ON EACH WORKER ===
# 11. Start munge + slurmd
sudo systemctl enable --now munge
sudo service slurmd start

# === ON HOST ===
# 12. Verify
sinfo
srun --nodes=4 hostname
```

---

*Want to test the same concepts on a single laptop first? See **[`slurm-docker-setup.md`](slurm-docker-setup.md)**, the Docker-based 3-node cluster (pure Arch containers, no systemd).*