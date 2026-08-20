#!/usr/bin/env bash
# ============================================================
#  SLURM cluster setup - CONTROL NODE (host)
#  Ubuntu 22.04 LTS over a shared Ethernet LAN.
#
#  Brings up the full cluster (1 host + N workers) end to end
#  and drives every worker automatically over passwordless SSH.
#  Idempotent - safe to re-run.
#
#  Usage:   ./setup_host.sh
#  Before:  edit cluster.conf (username, hostnames, LAN IPs)
#  During:  you will be prompted once per worker for its login
#           password (ssh-copy-id) and its sudo password.
#  After:   run ./verify.sh to test the cluster.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cluster.conf"
export CLUSTER_USER HOST_HOSTNAME HOST_IP WORKERS CLUSTER_NAME

WORKER_NAMES=()
WORKER_IPS=()
for entry in $WORKERS; do
  WORKER_NAMES+=("${entry%%:*}")
  WORKER_IPS+=("${entry##*:}")
done
NUM_WORKERS=${#WORKER_NAMES[@]}

log() { echo "  [host] $*"; }

# ------------------------------------------------------------
# helpers
# ------------------------------------------------------------

# Make /etc/hosts self-consistent: remove stale entries for the
# cluster hostnames and the 127.0.1.1 line, then append LAN IPs.
update_hosts() {
  local entry
  sudo sed -i -E "/[[:space:]]${HOST_HOSTNAME}\$/d" /etc/hosts
  for entry in $WORKERS; do
    sudo sed -i -E "/[[:space:]]${entry%%:*}\$/d" /etc/hosts
  done
  sudo sed -i -E "/^127\.0\.1\.1/d" /etc/hosts
  {
    echo "# --- SLURM cluster (managed by setup script) ---"
    echo "${HOST_IP} ${HOST_HOSTNAME}"
    for entry in $WORKERS; do
      echo "${entry##*:} ${entry%%:*}"
    done
  } | sudo tee -a /etc/hosts >/dev/null
}

configure_firewall() {
  sudo ufw allow 22/tcp
  sudo ufw allow 6817/tcp
  sudo ufw allow 6818:6819/tcp
  sudo ufw --force enable
}

# Hardware probes for the host (runs locally).
local_specs() {
  echo "cpus=$(nproc)"
  echo "cores=$(lscpu | awk -F: '/^Core\(s\) per socket:/{gsub(/ +/,"",$2); print $2}')"
  echo "mem=$(free -m | awk '/^Mem:/{print $2}')"
}

# Hardware probes for a worker (runs remotely via bash -s).
remote_specs() {
  local worker="$1"
  ssh -o BatchMode=yes "$CLUSTER_USER@$worker" 'bash -s' <<'EOF'
echo "cpus=$(nproc)"
echo "cores=$(lscpu | awk -F: '/^Core\(s\) per socket:/{gsub(/ +/,"",$2); print $2}')"
echo "mem=$(free -m | awk '/^Mem:/{print $2}')"
EOF
}

parse_specs() {
  local out="$1"
  CPUS="$(printf '%s\n' "$out" | sed -n 's/^cpus=//p')"
  CORES="$(printf '%s\n' "$out" | sed -n 's/^cores=//p')"
  MEM="$(printf '%s\n' "$out" | sed -n 's/^mem=//p')"
}

# ------------------------------------------------------------
# 0. sudo + passwordless sudo on the host itself
# ------------------------------------------------------------
echo "=== SLURM cluster bring-up (host: $HOST_HOSTNAME, workers: $NUM_WORKERS) ==="
sudo -v
if [ ! -f /etc/sudoers.d/90-slurm-cluster ]; then
  echo "$CLUSTER_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-slurm-cluster >/dev/null
  sudo chmod 440 /etc/sudoers.d/90-slurm-cluster
fi

# ------------------------------------------------------------
# 1. packages on the host
# ------------------------------------------------------------
log "installing packages"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y slurm-wlm munge openssh-server net-tools vim

# ------------------------------------------------------------
# 2. host identity: hostname, /etc/hosts, NTP, firewall
# ------------------------------------------------------------
log "setting hostname /etc/hosts, NTP, firewall"
sudo hostnamectl set-hostname "$HOST_HOSTNAME"
update_hosts
sudo timedatectl set-ntp true
configure_firewall

# ------------------------------------------------------------
# 3. SLURM directories on the host
# ------------------------------------------------------------
log "creating SLURM directories"
sudo mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
sudo chown -R slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd

# ------------------------------------------------------------
# 4. passwordless SSH: host -> every worker
# ------------------------------------------------------------
if [ ! -f ~/.ssh/id_rsa ]; then
  log "generating SSH key"
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
fi

for w in "${WORKER_NAMES[@]}"; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$CLUSTER_USER@$w" true 2>/dev/null; then
    log "SSH to $w already works"
  else
    log "copying SSH key to $w (enter its login password when prompted)"
    ssh-copy-id -i ~/.ssh/id_rsa.pub "$CLUSTER_USER@$w"
  fi
done

# ------------------------------------------------------------
# 5. passwordless sudo on every worker (one sudo prompt each)
# ------------------------------------------------------------
for w in "${WORKER_NAMES[@]}"; do
  log "enabling passwordless sudo on $w (enter its sudo password when prompted)"
  ssh -t "$CLUSTER_USER@$w" "echo '$CLUSTER_USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-slurm-cluster >/dev/null && sudo chmod 440 /etc/sudoers.d/90-slurm-cluster"
done

for w in "${WORKER_NAMES[@]}"; do
  if ! ssh -o BatchMode=yes "$CLUSTER_USER@$w" "sudo -n true" 2>/dev/null; then
    echo "  [host] ERROR: passwordless sudo failed on $w"
    exit 1
  fi
done
log "passwordless sudo verified on all workers"

# ------------------------------------------------------------
# 6. generate the shared Munge key and enable munge on the host
# ------------------------------------------------------------
if [ ! -f /etc/munge/munge.key ]; then
  log "generating Munge key"
  sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key 2>/dev/null
fi
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
sudo systemctl enable --now munge

# ------------------------------------------------------------
# 7. distribute the Munge key to every worker
# ------------------------------------------------------------
for w in "${WORKER_NAMES[@]}"; do
  log "distributing Munge key to $w"
  sudo cat /etc/munge/munge.key | ssh -o BatchMode=yes "$CLUSTER_USER@$w" \
    "sudo tee /etc/munge/munge.key >/dev/null && sudo chown munge:munge /etc/munge/munge.key && sudo chmod 400 /etc/munge/munge.key"
done

# ------------------------------------------------------------
# 8. generate slurm.conf from the live hardware of every node
# ------------------------------------------------------------
log "probing hardware and writing /etc/slurm/slurm.conf"
TMP_CONF="$(mktemp)"

{
  cat <<EOF
# === SLURM cluster configuration (generated by setup_host.sh) ===
# --- CONTROLLER ---
ClusterName=$CLUSTER_NAME
SlurmctldHost=$HOST_HOSTNAME
ControlMachine=$HOST_HOSTNAME

# --- LOGGING ---
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

# --- AUTHENTICATION ---
AuthType=auth/munge
CredType=cred/munge

# --- SCHEDULER ---
SchedulerType=sched/backfill
SelectType=select/cons_tres
ProctrackType=proctrack/linuxproc

# --- STATE STORAGE ---
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDirectory=/var/spool/slurmd

# --- TIMERS ---
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
Waittime=0

# --- CLUSTER TOPOLOGY (CPUs, CoresPerSocket, RealMemory from live hardware) ---
EOF

  parse_specs "$(local_specs)"
  echo "NodeName=$HOST_HOSTNAME CPUs=$CPUS CoresPerSocket=$CORES RealMemory=$MEM State=IDLE"

  for w in "${WORKER_NAMES[@]}"; do
    parse_specs "$(remote_specs "$w")"
    echo "NodeName=$w CPUs=$CPUS CoresPerSocket=$CORES RealMemory=$MEM State=IDLE"
  done

  # --- PARTITIONS ---
  WLIST="$(printf "%s," "${WORKER_NAMES[@]}" | sed 's/,$//')"
  echo "PartitionName=normal Nodes=$WLIST Default=YES MaxTime=INFINITE State=UP"
  echo "PartitionName=all Nodes=$HOST_HOSTNAME,$WLIST Default=NO MaxTime=INFINITE State=UP"
} > "$TMP_CONF"

sudo install -o root -g root -m 0644 "$TMP_CONF" /etc/slurm/slurm.conf
rm -f "$TMP_CONF"

if ! sudo slurmctld -t >/dev/null 2>&1; then
  echo "  [host] ERROR: slurm.conf failed validation (slurmctld -t)"
  sudo slurmctld -t
  exit 1
fi
log "slurm.conf validated"

# ------------------------------------------------------------
# 9. distribute slurm.conf to every worker
# ------------------------------------------------------------
for w in "${WORKER_NAMES[@]}"; do
  log "distributing slurm.conf to $w"
  cat /etc/slurm/slurm.conf | ssh -o BatchMode=yes "$CLUSTER_USER@$w" \
    "sudo tee /etc/slurm/slurm.conf >/dev/null"
done

# ------------------------------------------------------------
# 10. configure every worker (packages, identity, munge, slurmd)
# ------------------------------------------------------------
for w in "${WORKER_NAMES[@]}"; do
  log "configuring worker $w (this can take a while)"
  ssh "$CLUSTER_USER@$w" \
    "export CLUSTER_USER='$CLUSTER_USER' HOST_HOSTNAME='$HOST_HOSTNAME' HOST_IP='$HOST_IP' WORKERS='$WORKERS' CLUSTER_NAME='$CLUSTER_NAME'; bash -s" \
    < "$SCRIPT_DIR/setup_worker.sh"
done

# ------------------------------------------------------------
# 11. start the controller + host slurmd
# ------------------------------------------------------------
log "starting slurmctld and slurmd on the host"
sudo systemctl enable --now slurmctld slurmd

echo "=== done. Run ./verify.sh to test the cluster. ==="