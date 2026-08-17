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
