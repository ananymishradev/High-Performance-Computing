# SLURM HPC Cluster Setup on Physical Machines

> **Document type:** Technical setup report
> **Author:** Anany
> **Environment:** Ubuntu 22.04 LTS (recommended)
> **Cluster size:** 1 control node + 4 compute nodes
> **Network:** Shared Ethernet LAN
> **Last updated:** 17 August 2026
> **Review cadence:** Weekly

> **Related document:** [`slurm-docker-setup.md`](slurm-docker-setup.md) documents the equivalent Docker-based 3-node cluster, which I used to validate these concepts before working on real hardware.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Prerequisites](#2-prerequisites)
3. [Architecture Overview](#3-architecture-overview)
4. [Network Planning on the Shared Ethernet LAN](#4-network-planning-on-the-shared-ethernet-lan)
5. [Pre-flight Checks](#5-pre-flight-checks)
6. [Step 1: Configure Hostnames and Network](#6-step-1-configure-hostnames-and-network)
7. [Step 2: Configure Passwordless SSH](#7-step-2-configure-passwordless-ssh)
8. [Step 3: Install and Configure Munge](#8-step-3-install-and-configure-munge)
9. [Step 4: Configure slurm.conf](#9-step-4-configure-slurmconf)
10. [Step 5: Start SLURM Services](#10-step-5-start-slurm-services)
11. [Step 6: Test the Cluster](#11-step-6-test-the-cluster)
12. [Step 7: Write and Submit Jobs](#12-step-7-write-and-submit-jobs)
13. [Command Reference](#13-command-reference)
14. [Troubleshooting](#14-troubleshooting)
15. [Appendix: Full Setup Sequence](#15-appendix-full-setup-sequence)

---

## 1. Executive Summary

I built a five-node SLURM cluster consisting of one control node (`host`) and four compute nodes (`worker1`–`worker4`), all running Ubuntu 22.04 LTS and connected over a common Ethernet LAN. The control node runs the `slurmctld` controller daemon, while every node runs the `slurmd` worker daemon. All nodes authenticate through a single shared Munge key and use an identical `slurm.conf`.

This report documents the planning, configuration, verification, and job-testing steps I carried out. It is reviewed and updated on a weekly cadence, so each section records what was done, why it was done, and how it was verified.

---

## 2. Prerequisites

### Hardware

| Role | Machine | Recommended | Minimum RAM |
|------|---------|-------------|-------------|
| Control | Any CPU | 8 GB RAM, 50 GB disk | 4 GB |
| Compute 1 | CPU Type A | 8 GB RAM | 4 GB |
| Compute 2 | CPU Type B | 8 GB RAM | 4 GB |
| Compute 3 | CPU Type C | 8 GB RAM | 4 GB |
| Compute 4 | CPU Type D | 8 GB RAM | 4 GB |

### Software (on all 5 machines)

- Ubuntu 22.04 LTS
- `slurm-wlm`
- `munge`
- `openssh-server`
- `net-tools` (used by `netstat`)
- An identical username with `sudo` rights on every machine

> **Important:** SLURM launches jobs on the compute nodes as *my* user. If I submit a job as user `anany` from the control node, that user must exist on every compute node, or the job fails with `user not found`. I therefore used one identical username everywhere.

---

## 3. Architecture Overview

```
+------------------+
|   CONTROL NODE   |
|      (host)      |
|   slurmctld      |
|   slurmd         |
+--------+---------+
         |
    +----+----+----+----+
    |    |    |    |    |
+---+--+ +---+--+ +---+--+ +---+--+
|W1    | |W2    | |W3    | |W4    |
|worker1| |worker2| |worker3| |worker4|
|slurmd| |slurmd| |slurmd| |slurmd|
+------+ +------+ +------+ +------+

        Existing shared Ethernet LAN
```

- **Control Node (`host`):** runs `slurmctld`, the controller daemon that schedules jobs. It also runs `slurmd` so it can serve compute jobs itself (see [Step 5](#10-step-5-start-slurm-services)).
- **Compute Nodes 1–4 (`worker1`–`worker4`):** run `slurmd`, the worker daemon that executes the jobs assigned by the controller.
- **Network:** all five machines connect to the same existing Ethernet LAN through wall ports or a shared switch. No dedicated private subnet is required.

---

## 4. Network Planning on the Shared Ethernet LAN

The cluster sits on the common Ethernet LAN available in the lab, so there was no private subnet under my control. Every machine receives its address from the LAN's DHCP server. Because SLURM requires stable node identity — every node must always be reachable under the same hostname — I planned the addressing before configuring anything else.

### 4.1 Network Discovery

On each machine I ran the following commands to identify the assigned address, the default gateway, and the DNS servers:

```bash
# All IPv4 addresses of this machine
hostname -I

# Detailed address info (look for the wired NIC, e.g. enp* or eth0)
ip -4 addr show

# Default gateway (router) and subnet of the LAN
ip route | grep default

# DNS servers in use
resolvectl status
```

I recorded the address, gateway, and DNS for every machine; these values drive the address plan in [Section 4.3](#43-address-plan).

### 4.2 Addressing Strategy

I evaluated three options for keeping node identity stable on a DHCP-served LAN:

| Option | Description | Recommendation |
|--------|-------------|----------------|
| **A. DHCP reservations** | Ask the network administrator to reserve a fixed address for each of the five machines. | **Recommended.** Stable, and stays inside the LAN subnet. |
| **B. Manual static addresses** | With the administrator's permission, assign five unused addresses inside the LAN subnet. Keep the gateway and DNS from section 4.1. | Good when the admin cannot add reservations. |
| **C. Pure DHCP** | Let the DHCP server assign addresses automatically. | **Not recommended.** A lease renewal can change a machine's address and silently break the cluster until `/etc/hosts` is updated. |

I used Option A where the administrator could provide reservations, and Option B elsewhere. I avoided Option C for long-term operation because a silent address change would break SLURM registration.

### 4.3 Address Plan

The following table lists the hostnames and example addresses I used. The values shown are illustrative; the actual addresses come from the LAN.

| Machine | Hostname | Example Address | Role |
|---------|----------|-----------------|------|
| Control | `host` | 192.168.1.100 | Controller |
| Compute 1 | `worker1` | 192.168.1.101 | Compute |
| Compute 2 | `worker2` | 192.168.1.102 | Compute |
| Compute 3 | `worker3` | 192.168.1.103 | Compute |
| Compute 4 | `worker4` | 192.168.1.104 | Compute |

> **Note:** If the LAN already resolves hostnames through its own DNS, `/etc/hosts` entries can be skipped. I added them anyway because it makes the cluster independent of that DNS.

---

## 5. Pre-flight Checks

Before touching SLURM I performed a few checks on every machine to rule out the most common failure modes.

### 5.1 Time Synchronization

Munge credentials are timestamped; a skewed clock causes `MUNGE-CREDENTIAL expired` errors immediately. I therefore enabled NTP on all five machines:

```bash
sudo timedatectl set-ntp true
timedatectl status        # NTP service: active
```

`timedatectl status` confirmed `NTP service: active` on every machine.

### 5.2 Consistent Username and `sudo`

I used the same username with `sudo` rights on every machine, as specified in [Section 2](#2-prerequisites).

### 5.3 Firewall Configuration

Because the LAN is **shared**, I left the firewall enabled and exposed only the ports SLURM requires:

```bash
sudo ufw allow 22/tcp         # SSH
sudo ufw allow 6817/tcp       # slurmctld <-> slurmd
sudo ufw allow 6818:6819/tcp  # slurmd <-> slurmstepd (job I/O)
sudo ufw status               # verify
```

> **Security note:** anyone on a shared LAN who obtains my Munge key could join the cluster. I kept the key readable only by `munge` (mode `0400`) and shared it only with my five machines.

---

## 6. Step 1: Configure Hostnames and Network

### 6.1 Set the Hostname

I set a unique hostname on each machine:

```bash
# On the CONTROL machine
sudo hostnamectl set-hostname host

# On COMPUTE 1
sudo hostnamectl set-hostname worker1

# On COMPUTE 2
sudo hostnamectl set-hostname worker2

# On COMPUTE 3
sudo hostnamectl set-hostname worker3

# On COMPUTE 4
sudo hostnamectl set-hostname worker4
```

### 6.2 Edit `/etc/hosts`

On every machine I added the actual addresses from my [address plan](#43-address-plan):

```bash
sudo vim /etc/hosts
```

```
192.168.1.100   host
192.168.1.101   worker1
192.168.1.102   worker2
192.168.1.103   worker3
192.168.1.104   worker4
```

> **Important:** each machine's hostname **must exactly match** the `NodeName=` entries in `slurm.conf` ([Step 4](#9-step-4-configure-slurmconf)); SLURM is strict about this.
>
> **If pure DHCP is used (Option C):** these lines must stay in sync with the currently leased addresses, and need re-checking after any lease change.

### 6.3 Verify Hostname Resolution

On each machine I confirmed that all five names resolve:

```bash
ping -c 2 host
ping -c 2 worker1
ping -c 2 worker2
ping -c 2 worker3
ping -c 2 worker4
```

All five pings succeeded, confirming name resolution and L2/L3 connectivity across the LAN.

---

## 7. Step 2: Configure Passwordless SSH

Passwordless SSH lets the control node reach the compute nodes (and vice versa) without prompting. It is also the transport I used to distribute configuration files in later steps.

### 7.1 Generate the SSH Key on the Control Node

```bash
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
```

### 7.2 Copy the Key to All Compute Nodes

```bash
ssh-copy-id user@worker1
ssh-copy-id user@worker2
ssh-copy-id user@worker3
ssh-copy-id user@worker4
```

I was prompted for the password once per machine. `user` is replaced by the shared username.

### 7.3 Copy the Key Back to the Control Node

I repeated the same procedure from each compute node so that every pair of nodes can talk:

```bash
# On worker1
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
ssh-copy-id user@host

# Repeat on worker2, worker3, worker4
```

### 7.4 Test SSH

From the control node I verified each connection returns the correct hostname without prompting for a password:

```bash
ssh worker1 hostname
ssh worker2 hostname
ssh worker3 hostname
ssh worker4 hostname
```

Each command returned that machine's hostname with no password prompt. I also confirmed `sudo` works without errors on every machine (`sudo -v`), since later steps escalate privileges.

---

## 8. Step 3: Install and Configure Munge

Munge provides the authentication layer for SLURM. All nodes **must** share the **same Munge key**, with correct ownership (`munge:munge`) and mode **0400**.

> **`chmod 400`, not `0700`:** Munge requires the key file to be readable only by the `munge` user (`0400`). An overly-open mode makes `munged` refuse to start.

### 8.1 Generate the Munge Key on the Control Node

```bash
sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key

sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key

sudo systemctl enable --now munge
```

### 8.2 Copy the Key to All Compute Nodes

The key is only readable by root, so I piped it through my SSH connection and wrote it with `sudo tee` on each compute node. This reuses my user's SSH keys and leaves no plaintext copy behind:

```bash
# From the control node, run once per compute node:
sudo cat /etc/munge/munge.key | ssh user@worker1 \
  "sudo tee /etc/munge/munge.key > /dev/null && \
   sudo chown munge:munge /etc/munge/munge.key && \
   sudo chmod 400 /etc/munge/munge.key"
```

I repeated this for `worker2`, `worker3`, and `worker4`.

> **Why not `sudo scp`?** `sudo scp` runs as root and uses *root's* SSH keys, which were never set up in [Step 2](#7-step-2-configure-passwordless-ssh) — it fails or prompts for passwords unexpectedly. The pipe above reuses my user's keys.

### 8.3 Start Munge on Each Compute Node

```bash
sudo mkdir -p /run/munge
sudo chown munge:munge /run/munge
sudo chmod 0700 /run/munge

sudo systemctl enable --now munge
```

### 8.4 Verify Munge

On a representative machine I confirmed Munge authenticates correctly:

```bash
# Test munge authentication
munge --version
# Should output: MUNGE UTTU 0.9.x

# Test munge credential
munge | unmunge
# Should end with: MUNGE: Success
```

`munge | unmunge` ended with `MUNGE: Success`, confirming the shared key is valid on this node.

---

## 9. Step 4: Configure slurm.conf

### 9.1 Create slurm.conf on the Control Node

```bash
sudo vim /etc/slurm/slurm.conf
```

I created the following configuration:

```bash
#==========================================================
# SLURM Configuration for 1 Control + 4 Compute Nodes
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
# RealMemory is in MEGABYTES (see section 9.2).

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

### 9.2 Hardware Specs Used

I derived the `CPUs`, `CoresPerSocket`, and `RealMemory` values on each machine from:

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

**Example:** for a machine where `nproc` returned 16, `Core(s) per socket` returned 8, and `Socket(s)` returned 1, the entry is:

```
NodeName=worker2 CPUs=16 CoresPerSocket=8 RealMemory=15800 State=IDLE
```

### 9.3 Copy slurm.conf to All Compute Nodes

`/etc/slurm/` is root-owned, so I could not `scp` straight into it. I piped the file through SSH and wrote it with `sudo tee` instead:

```bash
# From the control node, run once per compute node:
cat /etc/slurm/slurm.conf | ssh user@worker1 "sudo tee /etc/slurm/slurm.conf > /dev/null"

# Repeat for worker2, worker3, worker4
```

---

## 10. Step 5: Start SLURM Services

> `service` is a wrapper around `systemctl` on Ubuntu; both work. The start order I followed is: **munge first, then `slurmctld` on the control node, then `slurmd` everywhere.**

### 10.1 Start the Controller on the Control Node

```bash
# Start slurmctld (controller daemon)
sudo service slurmctld start

# The control node is also a compute node (partition "all"), so it needs slurmd too
sudo service slurmd start

# Check status
sudo service slurmctld status
sudo service slurmd status
```

### 10.2 Start slurmd on Each Compute Node

```bash
# On worker1
sudo service slurmd start
sudo service slurmd status

# Repeat on worker2, worker3, worker4
```

### 10.3 Verify Cluster Status

From the control node I checked that all nodes registered:

```bash
sinfo
```

I observed the expected output:

```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
normal*      up   infinite      4   idle worker[1-4]
all          up   infinite      5   idle host,worker[1-4]
big          up   infinite      2   idle worker[2,4]
```

Nodes that show `down` or `drain` are handled in the [Troubleshooting](#14-troubleshooting) section.

> **Note:** I left `host` in the `all` partition so the control node can run jobs when requested; jobs are not scheduled there unless explicitly targeted.

---

## 11. Step 6: Test the Cluster

### Test 1: Run hostname on all compute nodes

```bash
srun --nodes=4 hostname
```

The output was:

```
worker1
worker2
worker3
worker4
```

This confirms the scheduler placed one task per compute node.

### Test 2: Node details

```bash
scontrol show nodes
```

### Test 3: Partition details

```bash
scontrol show partitions
```

### Test 4: Simple batch job

I submitted a batch job that reports job metadata and hardware:

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

After a few seconds I inspected the output:

```bash
cat result_*.out
```

The output showed two hosts, correct job metadata, and the CPU model of each node — confirming the batch path works end to end.

---

## 12. Step 7: Write and Submit Jobs

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

### Example 2: MPI (Message Passing Interface)

I installed MPI on all nodes:

```bash
sudo apt install -y openmpi-bin libopenmpi-dev
```

I then wrote a minimal MPI program:

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

and compiled it:

```bash
mpicc -o hello_mpi hello_mpi.c
```

> **I used `srun`, not `mpirun`, inside the SLURM script.** `srun` lets SLURM launch each MPI rank exactly on an allocated core. A bare `mpirun` tries to SSH between nodes itself and frequently conflicts with SLURM over resources (wrong task counts, doubled processes).

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

The output contained 8 `Hello from processor ...` lines (2 nodes × 4 ranks):

```bash
cat mpi_*.out
```

### Example 3: Array Jobs

An array job runs the same script across multiple parameter values:

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

> `%A` is the array job ID and `%a` the task index; each of the 10 tasks gets its own log file.

---

## 13. Command Reference

### Job Management

| Command | Purpose |
|---------|---------|
| `sinfo` | View cluster and node status |
| `squeue` | View the job queue |
| `sbatch script.sh` | Submit a batch job |
| `srun --nodes=N command` | Run an interactive job |
| `scancel JOB_ID` | Cancel a job |
| `scancel -u username` | Cancel all jobs of a user |
| `scontrol show nodes` | Detailed node information |
| `scontrol show partitions` | Detailed partition information |
| `scontrol show jobs` | Detailed job information |
| `sacct` | Job accounting (requires slurmdbd — see note) |
| `sprio` | View job priorities |
| `sping host` | Ping nodes via SLURM |

> **`sacct` needs accounting configured.** Without a running `slurmdbd` and MariaDB, `sacct` reports "No accounting storage configured" and returns nothing. That setup is out of scope here; `sacct` will work after accounting is configured.

### Useful Flags

```bash
# Submit job with a specific partition
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

### Monitoring

```bash
# Watch the queue in real time
watch -n 2 squeue

# Check node utilization
sinfo -N -l

# Check what a user is running
squeue -u username

# Check SLURM daemon logs
sudo tail -f /var/log/slurm/slurmctld.log    # On control node
sudo tail -f /var/log/slurm/slurmd.log       # On compute node
```

---

## 14. Troubleshooting

The following issues and their resolutions are recorded for future review.

### Problem: `sinfo` shows nodes in `down` state

**Resolution:**

```bash
# On the control node
sudo scontrol update nodename=worker1 state=resume
```

If the node stays down, I checked `slurmd` on that worker:

```bash
# On the worker
sudo service slurmd status
sudo service slurmd restart
# And check its log
sudo tail -20 /var/log/slurm/slurmd.log
```

### Problem: `sbatch` gives "slurmctld not running"

**Resolution:**

```bash
# On the control node
sudo service slurmctld status
sudo service slurmctld restart

# Check logs
sudo tail -20 /var/log/slurm/slurmctld.log
```

### Problem: `munge: MUNGE-CREDENTIAL not valid` or `expired`

**Root cause:** clock skew or a different key on some node.

```bash
# 1. Synchronize time on EVERY machine (common root cause)
sudo timedatectl set-ntp true
timedatectl status

# 2. Regenerate the key on the CONTROL node
sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key

# 3. Copy it to ALL compute nodes (the sudo-tee pipe from Step 3)

# 4. Restart munge everywhere
sudo systemctl restart munge    # on every machine

# 5. Verify
munge | unmunge                # should end with: MUNGE: Success
```

### Problem: Jobs stuck in `pending` state forever

**Possible causes:**

1. No nodes available — check `sinfo`
2. Resources exhausted — check `squeue`
3. Partition mismatch — the job requests the wrong partition

```bash
# Check why the job is pending
scontrol show job JOB_ID
# Look for the "Reason:" field in the output
```

### Problem: Job fails with `user not found` / `setuid: no such user`

**Resolution:** SLURM runs each job on the compute nodes as the submitting user. I created that user on **every** compute node:

```bash
sudo useradd -m -s /bin/bash alice   # same username as on the control node
```

Alternatively, submitting as a user that exists everywhere (e.g. `root`) is the easiest test path.

### Problem: SSH connection fails between nodes

**Resolution:**

```bash
# On the failing node
sudo service ssh status
sudo service ssh start

# Test connectivity
ping worker1
ping host
```

### Problem: `slurmd` won't start on a compute node

**Resolution:**

```bash
# Check if port 6817 is in use
sudo netstat -tlnp | grep 6817

# Check permissions
ls -la /var/spool/slurmd/
ls -la /etc/slurm/

# Check the computed configuration
slurmd -C
```

### Problem: Different CPU types cause issues

Because the workers have different CPU architectures, I added **Features** to each node in `slurm.conf`:

```bash
NodeName=worker1 CPUs=8 Feature="Intel_i5"
NodeName=worker2 CPUs=16 Feature="Intel_i7"
```

Jobs can then request specific features:

```bash
sbatch --constraint="Intel_i7" script.sh
```

### Problem: A node's address changed (pure DHCP)

**Resolution:** with DHCP, a lease renewal can change a machine's address, breaking `/etc/hosts` and SLURM registration.

```bash
# Find the new address on the affected machine
hostname -I

# Update /etc/hosts on EVERY machine to match, then restart slurmd:
sudo service slurmd restart
```

> **Prevention:** move to Option A or B in [Section 4.2](#42-addressing-strategy) so addresses never change.

---

## 15. Appendix: Full Setup Sequence

For reproducibility, the complete sequence I executed is summarized below.

```bash
# === ON ALL 5 MACHINES ===
# 1. Install packages
sudo apt update
sudo apt install -y slurm-wlm munge openssh-server net-tools vim sudo

# 2. Set hostname (different on each machine)
sudo hostnamectl set-hostname <hostname>

# 3. Edit /etc/hosts (add all 5 hostname/IP lines from the address plan)
sudo vim /etc/hosts

# 4. Synchronize time (Munge requires it!)
sudo timedatectl set-ntp true

# 5. Setup SSH keys (same user on every machine)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
# Copy keys between all machines with ssh-copy-id

# 6. Create SLURM dirs
sudo mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
sudo chown slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd

# === ON CONTROL NODE ONLY ===
# 7. Generate munge key
sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
sudo systemctl enable --now munge

# 8. Copy munge key to each compute node (repeat per worker)
sudo cat /etc/munge/munge.key | ssh user@worker1 \
  "sudo tee /etc/munge/munge.key > /dev/null && sudo chown munge:munge /etc/munge/munge.key && sudo chmod 400 /etc/munge/munge.key"

# 9. Create + distribute slurm.conf (repeat per worker)
sudo vim /etc/slurm/slurm.conf
cat /etc/slurm/slurm.conf | ssh user@worker1 "sudo tee /etc/slurm/slurm.conf > /dev/null"

# 10. Start controller + control-node slurmd
sudo systemctl enable --now munge
sudo service slurmctld start
sudo service slurmd start

# === ON EACH COMPUTE NODE ===
# 11. Start munge + slurmd
sudo systemctl enable --now munge
sudo service slurmd start

# === ON CONTROL NODE ===
# 12. Verify
sinfo
srun --nodes=4 hostname
```

---

*Related: see **[`slurm-docker-setup.md`](slurm-docker-setup.md)** for the Docker-based 3-node cluster I used to validate these concepts on a single laptop.*
