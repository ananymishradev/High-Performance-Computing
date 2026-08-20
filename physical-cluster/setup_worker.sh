#!/usr/bin/env bash
# ============================================================
#  SLURM cluster setup - COMPUTE NODE (worker)
#  Ubuntu 22.04 LTS over a shared Ethernet LAN.
#
#  Idempotent - safe to re-run.
#  Normally driven automatically by setup_host.sh over ssh.
#
#  Manual use on a single worker:
#      WORKER_NAME=worker1 ./setup_worker.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Env vars are injected when setup_host.sh runs this over ssh;
# fall back to cluster.conf when run by hand.
if [ -z "${CLUSTER_USER:-}" ] || [ -z "${HOST_HOSTNAME:-}" ] || [ -z "${HOST_IP:-}" ] || [ -z "${WORKERS:-}" ]; then
  source "$SCRIPT_DIR/cluster.conf"
fi
export CLUSTER_USER HOST_HOSTNAME HOST_IP WORKERS CLUSTER_NAME="${CLUSTER_NAME:-}"

WORKER_NAMES=()
WORKER_IPS=()
for entry in $WORKERS; do
  WORKER_NAMES+=("${entry%%:*}")
  WORKER_IPS+=("${entry##*:}")
done

MY_NAME="${WORKER_NAME:-$(hostname)}"
MY_IP=""
for i in "${!WORKER_NAMES[@]}"; do
  if [ "${WORKER_NAMES[$i]}" = "$MY_NAME" ]; then
    MY_IP="${WORKER_IPS[$i]}"
  fi
done
if [ -z "$MY_IP" ]; then
  echo "ERROR: '$MY_NAME' is not in the WORKERS list of cluster.conf."
  echo "Run this as:  WORKER_NAME=worker1 ./setup_worker.sh"
  exit 1
fiop

log() { echo "  [$MY_NAME] $*"; }

# Make /etc/hosts self-consistent for every node in the cluster.
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

echo "=== configuring worker $MY_NAME ($MY_IP) ==="

# ------------------------------------------------------------
# 1. packages
# ------------------------------------------------------------
log "installing packages"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y slurm-wlm munge openssh-server net-tools vim

# ------------------------------------------------------------
# 2. identity: hostname, /etc/hosts, NTP, firewall
# ------------------------------------------------------------
log "setting hostname /etc/hosts, NTP, firewall"
sudo hostnamectl set-hostname "$MY_NAME"
update_hosts
sudo timedatectl set-ntp true
configure_firewall

# ------------------------------------------------------------
# 3. passwordless sudo for this user (idempotent)
# ------------------------------------------------------------
if [ ! -f /etc/sudoers.d/90-slurm-cluster ]; then
  echo "$CLUSTER_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-slurm-cluster >/dev/null
  sudo chmod 440 /etc/sudoers.d/90-slurm-cluster
fi

# ------------------------------------------------------------
# 4. SLURM directories
# ------------------------------------------------------------
log "creating SLURM directories"
sudo mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
sudo chown -R slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd

# ------------------------------------------------------------
# 5. munge (key is pushed by setup_host.sh - must exist already)
# ------------------------------------------------------------
if [ ! -f /etc/munge/munge.key ]; then
  echo "ERROR: no Munge key found. Run setup_host.sh on $HOST_HOSTNAME first."
  exit 1
fi
sudo mkdir -p /run/munge
sudo chown munge:munge /run/munge
sudo chmod 0700 /run/munge
sudo systemctl enable --now munge

# ------------------------------------------------------------
# 6. slurmd
# ------------------------------------------------------------
if [ ! -f /etc/slurm/slurm.conf ]; then
  echo "ERROR: no slurm.conf found. Run setup_host.sh on $HOST_HOSTNAME first."
  exit 1
fi
log "starting slurmd"
sudo systemctl enable slurmd
sudo systemctl restart slurmd

echo "=== worker $MY_NAME ready ==="