# SLURM HPC Cluster Setup

> **Architecture:** 1 Control Node + 4 Compute Nodes

Here the machines are connected to a **common Ethernet LAN**

### 3.1 Discover Your Network Details

Run this on each machine:

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

Record the address, gateway, and DNS for every machine. You will need them for the address plan below.

### 3.2 Choose an Addressing Strategy

SLURM requires **stable node identity**: every node must always be reachable under the same hostname. Since the LAN hands out addresses dynamically, choose one of these strategies:

| Option | Description | Recommendation |
|--------|-------------|----------------|
| **A. DHCP reservations** | Ask the network administrator to reserve a fixed address for each of the five machines. | **Recommended.** Stable, and stays inside the LAN subnet. |
| **B. Manual static addresses** | With the administrator's permission, assign five unused addresses inside the LAN subnet. Keep the gateway and DNS from step 3.1. | Good when the admin cannot add reservations. |
| **C. Pure DHCP** | Let the DHCP server assign addresses automatically. | **Not recommended.** A lease renewal can change a machine's address and silently break the cluster until `/etc/hosts` is updated. |

### 3.3 Example Address Plan

Replace the example addresses below with the actual addresses your LAN assigns:

| Machine | Hostname | Example Address | Role |
|---------|----------|-----------------|------|
| Control | `host` | 192.168.1.100 | Controller |
| Compute 1 | `worker1` | 192.168.1.101 | Compute |
| Compute 2 | `worker2` | 192.168.1.102 | Compute |
| Compute 3 | `worker3` | 192.168.1.103 | Compute |
| Compute 4 | `worker4` | 192.168.1.104 | Compute |

> **Note:** If your LAN already resolves hostnames through its own DNS, you may skip `/etc/hosts` entries — but adding them anyway is harmless and makes the cluster independent of that DNS.

---

## 4. Pre-flight Checks

These checks avoid most of the "why is it down?" problems later.

### 4.1 Synchronize Time on Every Machine

Munge credentials are timestamped; a skewed clock causes `MUNGE-CREDENTIAL expired` errors immediately.

```bash
sudo timedatectl set-ntp true
timedatectl status        # NTP service: active
```

### 4.2 Consistent Username and `sudo`

Every machine must use the same username with `sudo` rights (see [Section 2](#2-prerequisites)).

### 4.3 Allow the Required Ports in the Firewall

Because the LAN is **shared**, leave the firewall enabled and expose only the ports SLURM needs:

```bash
sudo ufw allow 22/tcp         # SSH
sudo ufw allow 6817/tcp       # slurmctld <-> slurmd
sudo ufw allow 6818:6819/tcp  # slurmd <-> slurmstepd (job I/O)
sudo ufw status               # verify
```

> **Security note:** Anyone on a shared LAN who obtains your Munge key can join the cluster. Keep the key readable only by `munge` (mode `0400`) and never share it outside your five machines.

---

## 5. Step 1: Configure Hostnames and Network

### 5.1 Set the Hostname (on each machine)

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

### 5.2 Edit `/etc/hosts` (on every machine)

```bash
sudo vim /etc/hosts
```

Add the actual addresses from your [address plan](#33-example-address-plan) to **all five machines**:

```
192.168.1.100   host
192.168.1.101   worker1
192.168.1.102   worker2
192.168.1.103   worker3
192.168.1.104   worker4
```

> **Important:** The hostname of each machine **must exactly match** the `NodeName=` entries in `slurm.conf` ([Step 4](#8-step-4-configure-slurmconf)). SLURM is strict about this.
>
> **If you use pure DHCP (Option C):** keep these lines in sync with the addresses currently leased to each machine, and check them again after any lease change.

### 5.3 Verify Hostname Resolution (on each machine)

```bash
ping -c 2 host
ping -c 2 worker1
ping -c 2 worker2
ping -c 2 worker3
ping -c 2 worker4
```

All pings must succeed. If not, re-check `/etc/hosts`, the firewall rules, and the physical cable connections.

---

## 6. Step 2: Configure Passwordless SSH

SSH lets the control node reach the compute nodes (and vice versa) without a password. It is also what you will use to distribute configuration files.

### 6.1 On the Control Node: Generate an SSH Key

```bash
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
```

### 6.2 On the Control Node: Copy the Key to All Compute Nodes

```bash
ssh-copy-id user@worker1
ssh-copy-id user@worker2
ssh-copy-id user@worker3
ssh-copy-id user@worker4
```

You will be prompted for the password once per machine. Replace `user` with the shared username.

### 6.3 On Each Compute Node: Copy the Key Back to the Control Node

```bash
# On worker1
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
ssh-copy-id user@host

# Repeat on worker2, worker3, worker4
```

### 6.4 Test SSH (from the Control Node)

```bash
ssh worker1 hostname
ssh worker2 hostname
ssh worker3 hostname
ssh worker4 hostname
```

Each command must return that machine's hostname without asking for a password.

> **Note:** If your account needs to become root during later steps, confirm `sudo` works without errors on every machine (`sudo -v`).

---

## 7. Step 3: Install and Configure Munge

Munge provides authentication for SLURM. All nodes **must** share the **same Munge key**, with correct ownership (`munge:munge`) and mode **0400**.

> **`chmod 400`, not `0700`:** Munge expects the key file to be readable only by the `munge` user (`0400`). An overly-open mode makes `munged` refuse to start.

### 7.1 On the Control Node: Generate the Munge Key

```bash
sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key

sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key

sudo systemctl enable --now munge
```

### 7.2 On the Control Node: Copy the Key to All Compute Nodes

The key is only readable by root, so it must be piped through your SSH connection and written with `sudo tee` on each compute node. This reuses your user's SSH keys and leaves no plaintext copy behind:

```bash
# From the control node, run once per compute node:
sudo cat /etc/munge/munge.key | ssh user@worker1 \
  "sudo tee /etc/munge/munge.key > /dev/null && \
   sudo chown munge:munge /etc/munge/munge.key && \
   sudo chmod 400 /etc/munge/munge.key"
```

Repeat for `worker2`, `worker3`, and `worker4`.

> **Why not `sudo scp`?** `sudo scp` runs as root and uses *root's* SSH keys, which were never set up in [Step 2](#6-step-2-configure-passwordless-ssh) — it fails or prompts for passwords unexpectedly. The pipe above reuses your user's keys.

### 7.3 On Each Compute Node: Start Munge

```bash
sudo mkdir -p /run/munge
sudo chown munge:munge /run/munge
sudo chmod 0700 /run/munge

sudo systemctl enable --now munge
```

### 7.4 Verify Munge (on any machine)

```bash
# Test munge authentication
munge --version
# Should output: MUNGE UTTU 0.9.x

# Test munge credential
munge | unmunge
# Should end with: MUNGE: Success
```

---

## 8. Step 4: Configure slurm.conf

### 8.1 On the Control Node: Create slurm.conf

```bash
sudo vim /etc/slurm/slurm.conf
```

Paste this entire configuration:

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

### 8.2 Find Your Hardware Specs

Run these commands on each machine to fill in the correct values:

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

**Example:** if `nproc` returns 16, `Core(s) per socket` returns 8, and `Socket(s)` returns 1, then:

```
NodeName=worker2 CPUs=16 CoresPerSocket=8 RealMemory=15800 State=IDLE
```

### 8.3 Copy slurm.conf to All Compute Nodes

`/etc/slurm/` is root-owned, so you cannot `scp` straight into it. Pipe the file through SSH and write it with `sudo tee` instead:

```bash
# From the control node, run once per compute node:
cat /etc/slurm/slurm.conf | ssh user@worker1 "sudo tee /etc/slurm/slurm.conf > /dev/null"

# Repeat for worker2, worker3, worker4
```

---

## 9. Step 5: Start SLURM Services

> `service` is a friendly wrapper around `systemctl` on Ubuntu; both work. Start order matters: **munge first, then `slurmctld` on the control node, then `slurmd` everywhere.**

### 9.1 On the Control Node: Start the Controller

```bash
# Start slurmctld (controller daemon)
sudo service slurmctld start

# The control node is also a compute node (partition "all"), so it needs slurmd too
sudo service slurmd start

# Check status
sudo service slurmctld status
sudo service slurmd status
```

### 9.2 On Each Compute Node: Start slurmd

```bash
# On worker1
sudo service slurmd start
sudo service slurmd status

# Repeat on worker2, worker3, worker4
```

### 9.3 Verify Cluster Status (from the Control Node)

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

If nodes show `down` or `drain`, see the [Troubleshooting](#13-troubleshooting) section.

> **Not using the control node for jobs?** Remove `host` from the `all` partition (or leave it — jobs just won't be scheduled there unless requested).

---

## 10. Step 6: Test the Cluster

### Test 1: Run hostname on all compute nodes

```bash
srun --nodes=4 hostname
```

Expected output:

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

Wait a few seconds, then check the output:

```bash
cat result_*.out
```

---

## 11. Step 7: Write and Submit Jobs

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

First install MPI on all nodes:

```bash
sudo apt install -y openmpi-bin libopenmpi-dev
```

Create the MPI program:

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

Compile it:

```bash
mpicc -o hello_mpi hello_mpi.c
```

Create the SLURM script:

> **Use `srun`, not `mpirun`, inside a SLURM script.** `srun` lets SLURM launch each MPI rank exactly on an allocated core. A bare `mpirun` tries to SSH between nodes itself and frequently fights SLURM for resources (wrong task counts, doubled processes).

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

### Example 3: Array Jobs (Same Script, Different Parameters)

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

> `%A` = array job ID, `%a` = task index. Each of the 10 tasks gets its own log file.

---

## 12. Command Reference

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

> **`sacct` needs accounting configured.** Without a running `slurmdbd` and MariaDB, `sacct` reports "No accounting storage configured" and returns nothing. That setup is out of scope here; `sacct` will work after you configure accounting later.

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

## 13. Troubleshooting

### Problem: `sinfo` shows nodes in `down` state

**Fix:**

```bash
# On the control node
sudo scontrol update nodename=worker1 state=resume
```

If the node stays down, check `slurmd` on that worker:

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
# On the control node
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
3. Partition mismatch — ensure the job requests the correct partition

```bash
# Check why the job is pending
scontrol show job JOB_ID
# Look for the "Reason:" field in the output
```

### Problem: Job fails with `user not found` / `setuid: no such user`

**Fix:** SLURM runs each job on the compute nodes as your submitting user. Create that user on **every** compute node:

```bash
sudo useradd -m -s /bin/bash alice   # same username you use on the control node
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

### Problem: `slurmd` won't start on a compute node

**Fix:**

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

If your workers have different CPU architectures, add **Features** to each node in `slurm.conf`:

```bash
NodeName=worker1 CPUs=8 Feature="Intel_i5"
NodeName=worker2 CPUs=16 Feature="Intel_i7"
```

Then submit jobs requesting specific features:

```bash
sbatch --constraint="Intel_i7" script.sh
```

### Problem: A node's address changed (pure DHCP)

**Fix:** With DHCP, a lease renewal can change a machine's address, breaking `/etc/hosts` and SLURM registration.

```bash
# Find the new address on the affected machine
hostname -I

# Update /etc/hosts on EVERY machine to match, then restart slurmd:
sudo service slurmd restart
```

> **Prevention:** Move to Option A or B in [Section 3.2](#32-choose-an-addressing-strategy) so addresses never change.

---

## 14. Appendix: Full Setup Sequence

Run these in order on all machines:

```bash
# === ON ALL 5 MACHINES ===
# 1. Install packages
sudo apt update
sudo apt install -y slurm-wlm munge openssh-server net-tools vim sudo

# 2. Set hostname (different on each machine)
sudo hostnamectl set-hostname <hostname>

# 3. Edit /etc/hosts (add all 5 hostname/IP lines from your address plan)
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

*Want to practice the same concepts on a single laptop first? See **[`slurm-docker-setup.md`](slurm-docker-setup.md)** — a Docker-based 3-node cluster using pure Arch containers.*
