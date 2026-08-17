#!/bin/bash
# Starts Munge, SSH and the SLURM daemons.
# No systemd is used inside the containers, so nothing heavy boots up.
set -e

echo "=== $(hostname) starting (role: ${NODE_ROLE:-worker}) ==="

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

echo "=== $(hostname) is ready ==="
exec tail -f /dev/null