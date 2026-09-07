#!/usr/bin/env bash
# ============================================================
#  HPC cluster setup - HOST (controller + NFS server)
#
#  Run on the HOST machine (WSL: am_user@SRMS1).
#  Drives the whole cluster end to end. Idempotent - safe to
#  re-run after fixing an IP or adding a worker.
#
#  What it does:
#    1. Asks for IPs interactively (or reads cluster.conf) and
#       saves them back to cluster.conf
#    2. Installs ALL host utilities (slurm, munge, nfs, mpi...)
#    3. Sets hostname /etc/hosts, time sync, firewall, /dev/shm
#    4. Creates passwordless SSH host -> workers
#    5. Creates $CLUSTER_USER on every worker with the SAME
#       UID/GID as the host (you only installed ssh there)
#    6. Enables passwordless sudo on every worker
#    7. Generates + distributes the shared Munge key
#    8. Sets up the NFS shared dir (kernel NFS, or unfs3 on WSL)
#    9. Probes live hardware, writes + validates slurm.conf,
#       distributes it to every worker
#   10. Drives setup_worker.sh on every worker over ssh
#   11. Starts slurmctld + slurmd (+ munge + nfs) on the host
#
#  Usage:
#      chmod +x setup_host.sh
#      ./setup_host.sh
#
#  Workers need ONLY: sudo apt install -y openssh-server
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cluster.conf"

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

log()  { echo "  [host] $*"; }
warn() { echo "  [host] WARNING: $*" >&2; }
die()  { echo "  [host] ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------
# environment detection
# ------------------------------------------------------------
is_wsl() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}
has_systemd() {
  [ -d /run/systemd/system ] && [ "$(ps -p 1 -o comm= 2>/dev/null || echo none)" = "systemd" ]
}

# Start+enable a service on systemd, sysv, or bare WSL.
svc_enable_now() {
  local svc
  for svc in "$@"; do
    if has_systemd; then
      sudo systemctl enable --now "$svc" || warn "systemctl enable --now $svc failed"
    elif command -v service >/dev/null 2>&1 && sudo service "$svc" start 2>/dev/null; then
      log "$svc started via 'service'"
    else
      case "$svc" in
        munge)     sudo mkdir -p /run/munge && sudo chown munge:munge /run/munge && sudo munged --force 2>/dev/null || sudo munged || warn "could not start munged manually" ;;
        slurmctld) sudo mkdir -p /var/spool/slurmctld && sudo chown slurm:slurm /var/spool/slurmctld && sudo slurmctld 2>/dev/null || warn "could not start slurmctld manually" ;;
        slurmd)    sudo mkdir -p /var/spool/slurmd && sudo chown slurm:slurm /var/spool/slurmd && sudo slurmd 2>/dev/null || warn "could not start slurmd manually" ;;
        *) warn "no systemd/service for $svc - start it manually" ;;
      esac
    fi
  done
}

# ------------------------------------------------------------
# 0. interactive configuration (you enter IPs manually)
# ------------------------------------------------------------
save_conf_value() { # KEY VALUE FILE
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s|^${key}=.*|${key}=\"${val}\"|" "$file"
  else
    echo "${key}=\"${val}\"" >> "$file"
  fi
}

prompt_for_config() {
  echo "=== cluster configuration (press Enter to keep [default]) ==="

  read -r -p "Cluster username (same on ALL nodes) [$CLUSTER_USER]: " ans || true
  [ -n "${ans:-}" ] && CLUSTER_USER="$ans"

  # Hostname defaults to the real WSL hostname if it looks custom.
  DETECTED_HOST="$(hostname 2>/dev/null || echo "$HOST_HOSTNAME")"
  if [ "$HOST_HOSTNAME" = "SRMS1" ] && [ -n "${DETECTED_HOST:-}" ]; then
    : # keep SRMS1 default; host may already be named SRMS1
  fi
  read -r -p "Host hostname [$HOST_HOSTNAME]: " ans || true
  [ -n "${ans:-}" ] && HOST_HOSTNAME="$ans"

  if is_wsl; then
    echo "  WSL detected. Workers reach this host via:"
    echo "    - mirrored networking: the normal LAN IP, or"
    echo "    - NAT (default): the WINDOWS LAN IP from 'ipconfig' on Windows."
    WSL_DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "${WSL_IP:-}" ] || WSL_IP="$WSL_DETECTED_IP"
    echo "  WSL-internal IP (auto-detected): ${WSL_IP:-unknown}"
  fi
  read -r -p "Host LAN IP workers must connect to [$HOST_IP]: " ans || true
  [ -n "${ans:-}" ] && HOST_IP="$ans"

  if is_wsl && [ "${WSL_MIRRORED:-auto}" = "auto" ]; then
    read -r -p "Is WSL mirrored networking enabled? (mirrored IP = Windows IP) [y/N]: " ans || true
    case "${ans:-}" in
      y|Y|yes|YES) WSL_MIRRORED="yes" ;;
      *)           WSL_MIRRORED="no" ;;
    esac
  fi

  echo "  Workers (current: $WORKERS)"
  read -r -p "Number of workers [$(echo "$WORKERS" | wc -w)]: " nans || true
  if [ -n "${nans:-}" ] && [ "$nans" -gt 0 ] 2>/dev/null; then
    NEW_WORKERS=""
    i=1
    while [ "$i" -le "$nans" ]; do
      old_entry="$(echo "$WORKERS" | tr ' ' '\n' | sed -n "${i}p" || true)"
      old_name="${old_entry%%:*}"; old_ip="${old_entry##*:}"
      [ "$old_name" = "$old_entry" ] && old_name="worker$i"
      [ "$old_ip" = "$old_entry" ] && old_ip=""
      read -r -p "  worker $i hostname [$old_name]: " wname || true
      read -r -p "  worker $i LAN IP [${old_ip:-<enter>}]: " wip || true
      wname="${wname:-$old_name}"
      wip="${wip:-$old_ip}"
      [ -z "$wip" ] && die "worker $i needs an IP"
      NEW_WORKERS="$NEW_WORKERS $wname:$wip"
      i=$((i+1))
    done
    WORKERS="$(echo "$NEW_WORKERS" | xargs)"
  fi

  if [ "${WORKER_INIT_USER:-ask}" = "ask" ]; then
    echo "  The 'initial SSH user' is the account that ALREADY exists on the"
    echo "  workers (created at Ubuntu install time, before the script runs)."
  fi
  read -r -p "Initial SSH user on workers (or 'ask' per worker) [$WORKER_INIT_USER]: " ans || true
  [ -n "${ans:-}" ] && WORKER_INIT_USER="$ans"

  read -r -p "Shared directory (same path on all nodes) [$SHARED_DIR]: " ans || true
  [ -n "${ans:-}" ] && SHARED_DIR="$ans"

  # Derive a /24 subnet default from the host IP if the placeholder is stale.
  read -r -p "Subnet allowed to mount NFS [$NFS_ALLOWED_SUBNET]: " ans || true
  [ -n "${ans:-}" ] && NFS_ALLOWED_SUBNET="$ans"

  export CLUSTER_USER HOST_HOSTNAME HOST_IP WSL_IP WSL_MIRRORED WORKERS WORKER_INIT_USER SHARED_DIR NFS_ALLOWED_SUBNET

  save_conf_value CLUSTER_USER "$CLUSTER_USER" "$SCRIPT_DIR/cluster.conf"
  save_conf_value HOST_HOSTNAME "$HOST_HOSTNAME" "$SCRIPT_DIR/cluster.conf"
  save_conf_value HOST_IP "$HOST_IP" "$SCRIPT_DIR/cluster.conf"
  save_conf_value WSL_IP "$WSL_IP" "$SCRIPT_DIR/cluster.conf"
  save_conf_value WSL_MIRRORED "$WSL_MIRRORED" "$SCRIPT_DIR/cluster.conf"
  save_conf_value WORKERS "$WORKERS" "$SCRIPT_DIR/cluster.conf"
  save_conf_value WORKER_INIT_USER "$WORKER_INIT_USER" "$SCRIPT_DIR/cluster.conf"
  save_conf_value SHARED_DIR "$SHARED_DIR" "$SCRIPT_DIR/cluster.conf"
  save_conf_value NFS_ALLOWED_SUBNET "$NFS_ALLOWED_SUBNET" "$SCRIPT_DIR/cluster.conf"
  log "configuration saved to cluster.conf"
}

# ------------------------------------------------------------
# helpers
# ------------------------------------------------------------
update_hosts() {
  sudo sed -i -E "/[[:space:]]${HOST_HOSTNAME}\$/d" /etc/hosts
  local entry
  for entry in $WORKERS; do
    sudo sed -i -E "/[[:space:]]${entry%%:*}\$/d" /etc/hosts
  done
  sudo sed -i -E "/^127\.0\.1\.1/d" /etc/hosts
  {
    echo "# --- HPC cluster (managed by setup_host.sh) ---"
    echo "${HOST_IP} ${HOST_HOSTNAME}"
    for entry in $WORKERS; do
      echo "${entry##*:} ${entry%%:*}"
    done
  } | sudo tee -a /etc/hosts >/dev/null
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not installed - skipping firewall (install ufw to restrict ports)"
    return 0
  fi
  # Ports: ssh, slurmctld/slurmd, NFSv3 (portmapper + nfsd)
  sudo ufw allow 22/tcp   || warn "ufw rule for 22 failed (normal on WSL)"
  sudo ufw allow 6817/tcp || warn "ufw rule for 6817 failed (normal on WSL)"
  sudo ufw allow 6818:6819/tcp || warn "ufw rule for 6818:6819 failed"
  sudo ufw allow 111/tcp  || true
  sudo ufw allow 111/udp  || true
  sudo ufw allow 2049/tcp || true
  sudo ufw allow 2049/udp || true
  sudo ufw --force enable || warn "ufw enable failed (expected on WSL - use Windows Firewall instead)"
}

configure_shm() {
  # Enforce /dev/shm size if SHM_SIZE is set (covers the
  # "shared memory" requirement at the OS level too).
  if [ "${SHM_SIZE:-auto}" = "auto" ]; then
    log "/dev/shm left at default ($(df -h /dev/shm 2>/dev/null | awk 'NR==2{print $2}') total)"
    return 0
  fi
  if grep -qE '^[[:space:]]*shm[[:space:]]+/dev/shm' /etc/fstab; then
    sudo sed -i -E "s|^[[:space:]]*shm[[:space:]]+/dev/shm.*|shm /dev/shm tmpfs defaults,size=${SHM_SIZE} 0 0|" /etc/fstab
  else
    echo "shm /dev/shm tmpfs defaults,size=${SHM_SIZE} 0 0" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo mount -o remount "/dev/shm" 2>/dev/null || warn "could not remount /dev/shm now; takes effect after reboot"
  log "/dev/shm sized to $SHM_SIZE"
}

local_specs() {
  echo "cpus=$(nproc)"
  echo "sockets=$(lscpu | awk -F: '/^Socket\(s\):/{gsub(/ +/,\"\",\$2); print \$2}')"
  echo "cores=$(lscpu | awk -F: '/^Core\(s\) per socket:/{gsub(/ +/,\"\",\$2); print \$2}')"
  echo "threads=$(lscpu | awk -F: '/^Thread\(s\) per core:/{gsub(/ +/,\"\",\$2); print \$2}')"
  echo "mem=$(free -m | awk '/^Mem:/{print \$2}')"
}

remote_specs() {
  ssh $SSH_OPTS "$CLUSTER_USER@$1" 'bash -s' <<'EOF'
echo "cpus=$(nproc)"
echo "sockets=$(lscpu | awk -F: '/^Socket\(s\):/{gsub(/ +/,"",$2); print $2}')"
echo "cores=$(lscpu | awk -F: '/^Core\(s\) per socket:/{gsub(/ +/,"",$2); print $2}')"
echo "threads=$(lscpu | awk -F: '/^Thread\(s\) per core:/{gsub(/ +/,"",$2); print $2}')"
echo "mem=$(free -m | awk '/^Mem:/{print $2}')"
EOF
}

parse_specs() {
  CPUS="$(printf '%s\n' "$1" | sed -n 's/^cpus=//p')"
  SOCKETS="$(printf '%s\n' "$1" | sed -n 's/^sockets=//p')"
  CORES="$(printf '%s\n' "$1" | sed -n 's/^cores=//p')"
  THREADS="$(printf '%s\n' "$1" | sed -n 's/^threads=//p')"
  MEM="$(printf '%s\n' "$1" | sed -n 's/^mem=//p')"
  [ -z "${SOCKETS:-}" ] && SOCKETS=1
  [ -z "${CORES:-}" ] && CORES=1
  [ -z "${THREADS:-}" ] && THREADS=1
}

# Write the Windows-side port-forward script for WSL2 NAT.
write_port_forward_ps1() {
  local ps1="$SCRIPT_DIR/wsl_port_forward.ps1"
  local wsl_ip="${WSL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  cat > "$ps1" <<EOF
# Run ONCE in an ELEVATED PowerShell on the Windows host.
# Forwards LAN -> WSL so workers can reach SLURM + NFS + SSH.
# Regenerate by re-running setup_host.sh (WSL IP changes on reboot).
\$WslIp = "$wsl_ip"
\$Ports = @(22, 6817, 6818, 6819, 2049, 111)
foreach (\$P in \$Ports) {
  netsh interface portproxy delete v4tov4 listenport=\$P listenaddress=0.0.0.0 | Out-Null
  netsh interface portproxy add v4tov4 listenport=\$P listenaddress=0.0.0.0 connectport=\$P connectaddress=\$WslIp
}
New-NetFirewallRule -DisplayName "HPC cluster (WSL)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22,6817-6819,2049,111 -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "HPC cluster NFS udp (WSL)" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 2049,111 -ErrorAction SilentlyContinue | Out-Null
netsh interface portproxy show v4tov4
Write-Host "Forwarded to WSL IP \$WslIp. Re-run this script if the WSL IP changes (wsl --shutdown)."
EOF
  log "wrote $ps1 (run in Admin PowerShell if workers cannot reach this host)"
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------
prompt_for_config

WORKER_NAMES=(); WORKER_IPS=()
for entry in $WORKERS; do
  WORKER_NAMES+=("${entry%%:*}")
  WORKER_IPS+=("${entry##*:}")
done
NUM_WORKERS=${#WORKER_NAMES[@]}
[ "$NUM_WORKERS" -ge 1 ] || die "no workers configured"

HOST_UID="$(id -u)"; HOST_GID="$(id -g)"
export HOST_UID HOST_GID

echo "=== HPC bring-up: host=$HOST_HOSTNAME workers=$NUM_WORKERS user=$CLUSTER_USER ==="
is_wsl && log "WSL environment detected (mirrored=${WSL_MIRRORED:-unknown})"
has_systemd && log "systemd present" || log "no systemd (WSL-style) - using service/direct fallbacks"

sudo -v
if [ ! -f /etc/sudoers.d/90-hpc-cluster ]; then
  echo "$CLUSTER_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-hpc-cluster >/dev/null
  sudo chmod 440 /etc/sudoers.d/90-hpc-cluster
fi

# --- 1. host packages (everything; workers start from ssh-only) ---
log "installing host packages"
sudo apt-get update
APT_HOST="slurm-wlm munge openssh-server openssh-client nfs-common net-tools vim htop build-essential python3 openmpi-bin libopenmpi-dev"
# shellcheck disable=SC2086
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_HOST
if is_wsl; then
  log "WSL: installing userspace NFS server (unfs3 - kernel nfsd unavailable in WSL)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unfs3 || warn "unfs3 install failed"
  command -v ufw >/dev/null 2>&1 || log "ufw absent on WSL - skipping (use Windows Firewall)"
else
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server ufw || warn "nfs/firewall install issue"
fi

# --- 2. host identity ---
log "hostname /etc/hosts, time sync, firewall, /dev/shm"
if has_systemd; then
  sudo hostnamectl set-hostname "$HOST_HOSTNAME" || warn "hostnamectl failed"
else
  echo "$HOST_HOSTNAME" | sudo tee /etc/hostname >/dev/null
  sudo hostname "$HOST_HOSTNAME" 2>/dev/null || warn "hostname set at next boot (WSL: also set in Windows hosts if needed)"
fi
update_hosts
if is_wsl; then
  log "WSL clock syncs from Windows - skipping timedatectl (run 'wsl --shutdown' if clocks drift)"
else
  sudo timedatectl set-ntp true || { sudo apt-get install -y chrony && svc_enable_now chrony; }
fi
configure_firewall
configure_shm

# --- 3. slurm spool/log dirs ---
log "creating SLURM directories"
sudo mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd "$SHARED_DIR"
sudo chown -R slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
sudo chown "$CLUSTER_USER":"$CLUSTER_USER" "$SHARED_DIR"
sudo chmod 2775 "$SHARED_DIR"

# --- 4. host ssh key ---
if [ ! -f ~/.ssh/id_rsa ]; then
  log "generating SSH key"
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
fi
PUBKEY="$(cat ~/.ssh/id_rsa.pub)"

# --- 5. create $CLUSTER_USER on every worker (same UID/GID) ---
for idx in "${!WORKER_NAMES[@]}"; do
  w="${WORKER_NAMES[$idx]}"; wip="${WORKER_IPS[$idx]}"
  if ssh $SSH_OPTS "$CLUSTER_USER@$w" true 2>/dev/null || ssh $SSH_OPTS "$CLUSTER_USER@$wip" true 2>/dev/null; then
    log "$w: $CLUSTER_USER already accessible"
    continue
  fi
  if [ "${WORKER_INIT_USER:-ask}" = "ask" ]; then
    read -r -p "  [$w] initial SSH user on $w ($wip): " init_user || true
  else
    init_user="$WORKER_INIT_USER"
  fi
  [ -n "${init_user:-}" ] || die "need the initial SSH user for $w"
  log "$w: creating user $CLUSTER_USER (uid=$HOST_UID gid=$HOST_GID) via $init_user@$wip"
  log "$w: enter the SSH password for $init_user when prompted (once)"
  # 5a. create user/group, sudoers, .ssh over the INITIAL account
  # shellcheck disable=SC2029
  ssh -o StrictHostKeyChecking=accept-new "$init_user@$wip" \
    "HOST_UID='$HOST_UID' HOST_GID='$HOST_GID' CLUSTER_USER='$CLUSTER_USER' PUBKEY='$PUBKEY' bash -s" <<'BOOTEOF'
set -e
if ! getent group "$CLUSTER_USER" >/dev/null; then
  if getent group "$HOST_GID" >/dev/null; then GNAME="$(getent group "$HOST_GID" | cut -d: -f1)"; echo "group $HOST_GID taken by $GNAME - reusing"; sudo usermod -l "$CLUSTER_USER" "$GNAME" 2>/dev/null || sudo groupadd -g "$HOST_GID" "$CLUSTER_USER";
  else sudo groupadd -g "$HOST_GID" "$CLUSTER_USER"; fi
fi
if ! id "$CLUSTER_USER" >/dev/null 2>&1; then
  if getent passwd "$HOST_UID" >/dev/null; then echo "ERROR: uid $HOST_UID taken by $(getent passwd "$HOST_UID"|cut -d: -f1) - fix manually" >&2; exit 1; fi
  sudo useradd -m -s /bin/bash -u "$HOST_UID" -g "$HOST_GID" -G sudo "$CLUSTER_USER"
fi
echo "$CLUSTER_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-hpc-cluster >/dev/null
sudo chmod 440 /etc/sudoers.d/90-hpc-cluster
sudo -u "$CLUSTER_USER" mkdir -p "/home/$CLUSTER_USER/.ssh"
echo "$PUBKEY" | sudo -u "$CLUSTER_USER" tee -a "/home/$CLUSTER_USER/.ssh/authorized_keys" >/dev/null
sudo -u "$CLUSTER_USER" chmod 700 "/home/$CLUSTER_USER/.ssh"
sudo -u "$CLUSTER_USER" chmod 600 "/home/$CLUSTER_USER/.ssh/authorized_keys"
sudo -u "$CLUSTER_USER" sort -u -o "/home/$CLUSTER_USER/.ssh/authorized_keys" "/home/$CLUSTER_USER/.ssh/authorized_keys"
BOOTEOF
  # 5b. verify new account works without password
  ssh $SSH_OPTS "$CLUSTER_USER@$wip" true \
    || ssh-copy-id -i ~/.ssh/id_rsa.pub "$CLUSTER_USER@$wip" \
    || die "cannot ssh as $CLUSTER_USER@$wip - check password/network"
  log "$w: user $CLUSTER_USER ready"
done

# --- 6. passwordless sudo already granted at creation; verify ---
for w in "${WORKER_NAMES[@]}"; do
  ssh $SSH_OPTS "$CLUSTER_USER@$w" "sudo -n true" \
    || die "passwordless sudo failed on $w"
done
log "passwordless sudo verified on all workers"

# --- 7. munge key ---
if [ ! -f /etc/munge/munge.key ]; then
  log "generating Munge key"
  sudo dd if=/dev/urandom bs=1024 count=1 of=/etc/munge/munge.key 2>/dev/null
fi
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
svc_enable_now munge

for w in "${WORKER_NAMES[@]}"; do
  log "distributing Munge key to $w"
  sudo cat /etc/munge/munge.key | ssh $SSH_OPTS "$CLUSTER_USER@$w" \
    "sudo tee /etc/munge/munge.key >/dev/null && sudo chown munge:munge /etc/munge/munge.key && sudo chmod 400 /etc/munge/munge.key"
done

# --- 8. NFS shared dir (server on the host) ---
log "exporting $SHARED_DIR to $NFS_ALLOWED_SUBNET"
EXPORT_LINE="$SHARED_DIR $NFS_ALLOWED_SUBNET(rw,sync,no_subtree_check,no_root_squash)"
if ! grep -qF "$SHARED_DIR" /etc/exports 2>/dev/null; then
  echo "$EXPORT_LINE" | sudo tee -a /etc/exports >/dev/null
else
  sudo sed -i -E "s|^${SHARED_DIR}[[:space:]].*|${EXPORT_LINE}|" /etc/exports
fi
if is_wsl; then
  sudo systemctl stop nfs-kernel-server 2>/dev/null || true
  if has_systemd; then
    sudo systemctl enable --now unfs3 2>/dev/null || sudo service unfs3 restart 2>/dev/null || true
  fi
  # unfsd serves /etc/exports directly (userspace, no kernel nfsd needed)
  if ! pgrep -x unfsd >/dev/null 2>&1; then
    sudo pkill unfsd 2>/dev/null || true
    sudo unfsd -e /etc/exports 2>/dev/null || warn "unfsd failed to start - check 'sudo unfsd -e /etc/exports'"
  fi
  pgrep -x unfsd >/dev/null 2>&1 && log "unfs3 NFS server running" || warn "unfs3 not running"
  write_port_forward_ps1
  if [ "${WSL_MIRRORED:-no}" != "yes" ]; then
    warn "WSL NAT mode: run wsl_port_forward.ps1 in Admin PowerShell so workers reach this host"
  fi
else
  svc_enable_now nfs-kernel-server
  sudo exportfs -ra || warn "exportfs failed"
  sudo exportfs -v | grep -q "$SHARED_DIR" && log "NFS export active" || warn "export not listed - check /etc/exports"
fi
# Host uses the dir locally (no self-mount needed); drop a marker.
echo "hpc-shared served from $HOST_HOSTNAME ($(date -u +%FT%TZ))" | sudo tee "$SHARED_DIR/.served_by" >/dev/null
sudo chown "$CLUSTER_USER":"$CLUSTER_USER" "$SHARED_DIR/.served_by"

# --- 9. slurm.conf from live hardware ---
log "probing hardware and writing slurm.conf"
TMP_CONF="$(mktemp)"
{
  cat <<EOF
# === SLURM cluster (generated by setup_host.sh - do not hand-edit) ===
ClusterName=$CLUSTER_NAME
SlurmctldHost=$HOST_HOSTNAME
ControlMachine=$HOST_HOSTNAME

SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

AuthType=auth/munge
CredType=cred/munge

SchedulerType=sched/backfill
SelectType=select/cons_tres
ProctrackType=proctrack/linuxproc

StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDirectory=/var/spool/slurmd
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
Waittime=0

# --- NODES (CPUs/Sockets/CoresPerSocket/ThreadsPerCore/RealMemory probed live) ---
EOF
  parse_specs "$(local_specs)"
  echo "NodeName=$HOST_HOSTNAME CPUs=$CPUS Boards=1 Sockets=$SOCKETS CoresPerSocket=$CORES ThreadsPerCore=$THREADS RealMemory=$MEM State=UNKNOWN"
  for w in "${WORKER_NAMES[@]}"; do
    parse_specs "$(remote_specs "$w")"
    echo "NodeName=$w CPUs=$CPUS Boards=1 Sockets=$SOCKETS CoresPerSocket=$CORES ThreadsPerCore=$THREADS RealMemory=$MEM State=UNKNOWN"
  done
  WLIST="$(printf "%s," "${WORKER_NAMES[@]}" | sed 's/,$//')"
  echo "PartitionName=normal Nodes=$WLIST Default=YES MaxTime=INFINITE State=UP"
  echo "PartitionName=all Nodes=$HOST_HOSTNAME,$WLIST Default=NO MaxTime=INFINITE State=UP"
} > "$TMP_CONF"

sudo install -o root -g root -m 0644 "$TMP_CONF" /etc/slurm/slurm.conf
rm -f "$TMP_CONF"
sudo slurmctld -t || { sudo slurmctld -t; die "slurm.conf failed validation"; }
log "slurm.conf validated"

for w in "${WORKER_NAMES[@]}"; do
  log "distributing slurm.conf to $w"
  sudo cat /etc/slurm/slurm.conf | ssh $SSH_OPTS "$CLUSTER_USER@$w" \
    "sudo tee /etc/slurm/slurm.conf >/dev/null"
done

# --- 10. configure every worker ---
for w in "${WORKER_NAMES[@]}"; do
  log "configuring worker $w"
  ssh $SSH_OPTS "$CLUSTER_USER@$w" \
    "export CLUSTER_USER='$CLUSTER_USER' HOST_HOSTNAME='$HOST_HOSTNAME' HOST_IP='$HOST_IP' WORKERS='$WORKERS' CLUSTER_NAME='$CLUSTER_NAME' SHARED_DIR='$SHARED_DIR' SHM_SIZE='${SHM_SIZE:-auto}' HOST_UID='$HOST_UID' HOST_GID='$HOST_GID'; bash -s" \
    < "$SCRIPT_DIR/setup_worker.sh"
done

# --- 10b. reverse SSH: workers -> host (needed for MPI/srun) ---
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
for w in "${WORKER_NAMES[@]}"; do
  WKEY="$(ssh $SSH_OPTS "$CLUSTER_USER@$w" "cat ~/.ssh/id_rsa.pub" 2>/dev/null || true)"
  if [ -n "$WKEY" ] && ! grep -qF "$WKEY" ~/.ssh/authorized_keys; then
    echo "$WKEY" >> ~/.ssh/authorized_keys
    log "imported $w ssh key for reverse access"
  fi
done

# --- 11. start controller + host slurmd ---
log "starting slurmctld and slurmd on the host"
svc_enable_now slurmctld slurmd

echo ""
echo "=== done ==="
echo "  1. Verify:  ./verify.sh"
echo "  2. Shared dir on every node: $SHARED_DIR (try: echo hello > $SHARED_DIR/test && cat $SHARED_DIR/test)"
is_wsl && [ "${WSL_MIRRORED:-no}" != "yes" ] && echo "  3. WSL NAT: run wsl_port_forward.ps1 in Admin PowerShell (once per WSL IP change)."
echo "  4. If a node shows down: sudo scontrol update nodename=<name> state=resume"
