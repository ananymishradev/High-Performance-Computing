#!/usr/bin/env bash
# ============================================================
#  HPC cluster setup - WORKER (Ubuntu compute node)
#
#  Normally driven automatically by setup_host.sh over ssh
#  (env vars injected). Standalone use on one worker:
#      WORKER_NAME=worker1 ./setup_worker.sh
#  (run as a sudo user; cluster.conf must have correct IPs).
#
#  Expects ONLY openssh-server pre-installed. Installs and
#  configures everything else: user, packages, hostname,
#  hosts, time, firewall, /dev/shm, munge, NFS client mount,
#  slurmd. Idempotent - safe to re-run.
#
#  NOTE: /etc/munge/munge.key and /etc/slurm/slurm.conf are
#  pushed from the host BEFORE this runs (host-driven mode),
#  so a standalone run requires setup_host.sh to have reached
#  the distribution steps at least once.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${CLUSTER_USER:-}" ] || [ -z "${HOST_HOSTNAME:-}" ] || [ -z "${HOST_IP:-}" ] || [ -z "${WORKERS:-}" ]; then
  source "$SCRIPT_DIR/cluster.conf"
fi
CLUSTER_NAME="${CLUSTER_NAME:-paanduv}"
SHARED_DIR="${SHARED_DIR:-/mnt/hpc-shared}"
SHM_SIZE="${SHM_SIZE:-auto}"
HOST_UID="${HOST_UID:-}"; HOST_GID="${HOST_GID:-}"

log()  { echo "  [worker] $*"; }
warn() { echo "  [worker] WARNING: $*" >&2; }
die()  { echo "  [worker] ERROR: $*" >&2; exit 1; }

has_systemd() {
  [ -d /run/systemd/system ] && [ "$(ps -p 1 -o comm= 2>/dev/null || echo none)" = "systemd" ]
}
svc_enable_now() {
  local svc
  for svc in "$@"; do
    if has_systemd; then
      sudo systemctl enable --now "$svc" || warn "systemctl enable --now $svc failed"
    elif sudo service "$svc" start 2>/dev/null; then
      log "$svc started via 'service'"
    else
      case "$svc" in
        munge) sudo mkdir -p /run/munge && sudo chown munge:munge /run/munge && sudo munged --force 2>/dev/null || sudo munged || warn "munged manual start failed" ;;
        slurmd) sudo mkdir -p /var/spool/slurmd && sudo chown slurm:slurm /var/spool/slurmd && sudo slurmd 2>/dev/null || warn "slurmd manual start failed" ;;
        *) warn "no supervisor for $svc" ;;
      esac
    fi
  done
}

# --- figure out who I am ---
MY_NAME="${WORKER_NAME:-$(hostname)}"
MY_IP=""
for entry in $WORKERS; do
  if [ "${entry%%:*}" = "$MY_NAME" ]; then MY_IP="${entry##*:}"; fi
done
[ -n "$MY_IP" ] || die "'$MY_NAME' is not in WORKERS. Run as: WORKER_NAME=worker1 ./setup_worker.sh"

echo "=== configuring worker $MY_NAME ($MY_IP), cluster user=$CLUSTER_USER ==="

# --- 0. ensure the cluster user exists with host-matching UID/GID ---
if ! id "$CLUSTER_USER" >/dev/null 2>&1; then
  log "creating user $CLUSTER_USER"
  if [ -n "${HOST_GID:-}" ] && ! getent group "$HOST_GID" >/dev/null; then
    sudo groupadd -g "$HOST_GID" "$CLUSTER_USER"
  elif ! getent group "$CLUSTER_USER" >/dev/null; then
    if [ -n "${HOST_GID:-}" ]; then sudo groupadd -g "$HOST_GID" "$CLUSTER_USER"
    else sudo groupadd "$CLUSTER_USER"; fi
  fi
  GGROUP="$(getent group "${HOST_GID:-$CLUSTER_USER}" | cut -d: -f1 2>/dev/null || echo "$CLUSTER_USER")"
  if [ -n "${HOST_UID:-}" ]; then
    sudo useradd -m -s /bin/bash -u "$HOST_UID" -g "$GGROUP" -G sudo "$CLUSTER_USER"
  else
    sudo useradd -m -s /bin/bash -g "$GGROUP" -G sudo "$CLUSTER_USER"
  fi
else
  log "user $CLUSTER_USER exists (uid=$(id -u "$CLUSTER_USER") gid=$(id -g "$CLUSTER_USER"))"
  if [ -n "${HOST_UID:-}" ] && [ "$(id -u "$CLUSTER_USER")" != "$HOST_UID" ]; then
    warn "uid mismatch: worker has $(id -u "$CLUSTER_USER"), host has $HOST_UID - NFS file ownership will be wrong. Fix with usermod."
  fi
fi
if [ ! -f /etc/sudoers.d/90-hpc-cluster ]; then
  echo "$CLUSTER_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-hpc-cluster >/dev/null
  sudo chmod 440 /etc/sudoers.d/90-hpc-cluster
fi

# --- 1. all worker utilities (starts from ssh-only) ---
log "installing packages"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  slurm-wlm munge openssh-server openssh-client nfs-common \
  net-tools vim htop build-essential python3 openmpi-bin libopenmpi-dev

# --- 2. identity: hostname, /etc/hosts, time, firewall, shm ---
log "hostname /etc/hosts, time, firewall, /dev/shm"
if has_systemd; then
  sudo hostnamectl set-hostname "$MY_NAME" || warn "hostnamectl failed"
else
  echo "$MY_NAME" | sudo tee /etc/hostname >/dev/null
  sudo hostname "$MY_NAME" 2>/dev/null || true
fi
sudo sed -i -E "/[[:space:]]${HOST_HOSTNAME}\$/d" /etc/hosts
for entry in $WORKERS; do
  sudo sed -i -E "/[[:space:]]${entry%%:*}\$/d" /etc/hosts
done
sudo sed -i -E "/^127\.0\.1\.1/d" /etc/hosts
{
  echo "# --- HPC cluster (managed by setup_worker.sh) ---"
  echo "${HOST_IP} ${HOST_HOSTNAME}"
  for entry in $WORKERS; do
    echo "${entry##*:} ${entry%%:*}"
  done
} | sudo tee -a /etc/hosts >/dev/null
sudo timedatectl set-ntp true 2>/dev/null || { sudo apt-get install -y chrony && svc_enable_now chrony; } || warn "time sync setup failed - munge needs synced clocks"
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 22/tcp; sudo ufw allow 6817/tcp; sudo ufw allow 6818:6819/tcp
  sudo ufw allow 111; sudo ufw allow 2049
  sudo ufw --force enable || warn "ufw enable failed"
fi
if [ "$SHM_SIZE" != "auto" ]; then
  if grep -qE '^[[:space:]]*shm[[:space:]]+/dev/shm' /etc/fstab; then
    sudo sed -i -E "s|^[[:space:]]*shm[[:space:]]+/dev/shm.*|shm /dev/shm tmpfs defaults,size=${SHM_SIZE} 0 0|" /etc/fstab
  else
    echo "shm /dev/shm tmpfs defaults,size=${SHM_SIZE} 0 0" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo mount -o remount /dev/shm 2>/dev/null || warn "/dev/shm remount deferred to reboot"
fi

# --- 3. slurm dirs ---
log "creating SLURM directories"
sudo mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd "$SHARED_DIR"
sudo chown -R slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd

# --- 4. worker ssh key (host collects the pubkey for reverse access) ---
if [ ! -f ~/.ssh/id_rsa ]; then
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
fi
log "worker pubkey ready (host imports it for MPI/srun reverse ssh)"

# --- 5. munge (key pushed by host) ---
[ -f /etc/munge/munge.key ] || die "no Munge key. Run setup_host.sh on $HOST_HOSTNAME first."
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
sudo mkdir -p /run/munge && sudo chown munge:munge /run/munge && sudo chmod 0700 /run/munge
svc_enable_now munge
munge -n 2>/dev/null | unmunge 2>/dev/null | grep -q Success && log "munge OK" || warn "local munge test failed - check key + clock"

# --- 6. NFS shared dir (client of the host; unfs3 speaks NFSv3) ---
log "mounting $SHARED_DIR from $HOST_HOSTNAME"
if grep -qE "[[:space:]]${SHARED_DIR}[[:space:]]" /etc/fstab; then
  sudo sed -i -E "\\|[[:space:]]${SHARED_DIR}[[:space:]]|d" /etc/fstab
fi
echo "${HOST_HOSTNAME}:${SHARED_DIR} ${SHARED_DIR} nfs defaults,_netdev,vers=3,rsize=32768,wsize=32768,timeo=14 0 0" | sudo tee -a /etc/fstab >/dev/null
tries=0
until sudo mount "$SHARED_DIR" 2>/dev/null || mountpoint -q "$SHARED_DIR"; do
  tries=$((tries+1))
  [ "$tries" -ge 6 ] && die "cannot mount $SHARED_DIR from $HOST_HOSTNAME - check host NFS + firewall + HOST_IP"
  log "mount retry $tries/6 in 5s..."
  sleep 5
done
mountpoint -q "$SHARED_DIR" && log "NFS mounted: $(df -h "$SHARED_DIR" | awk 'NR==2{print $1, $2}')"
[ -f "$SHARED_DIR/.served_by" ] && log "share marker: $(cat "$SHARED_DIR/.served_by")"

# --- 7. slurmd (config pushed by host) ---
[ -f /etc/slurm/slurm.conf ] || die "no slurm.conf. Run setup_host.sh on $HOST_HOSTNAME first."
log "starting slurmd"
if has_systemd; then
  sudo systemctl enable slurmd
  sudo systemctl restart slurmd
  sudo systemctl is-active --quiet slurmd && log "slurmd active" || { sudo tail -20 /var/log/slurm/slurmd.log; die "slurmd failed"; }
else
  sudo slurmd || warn "slurmd start issue"
fi

echo "=== worker $MY_NAME ready (user=$CLUSTER_USER share=$SHARED_DIR) ==="
