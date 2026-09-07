#!/usr/bin/env bash
# ============================================================
#  Verify the HPC cluster after setup_host.sh.
#  Run on the HOST (am_user@SRMS1).
#
#  Checks: DNS/ping, SSH both ways, munge here + on workers,
#  NFS shared dir everywhere, /dev/shm, sinfo, srun across
#  all nodes, and one real sbatch job using the shared dir.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cluster.conf"
SHARED_DIR="${SHARED_DIR:-/mnt/hpc-shared}"

WORKER_NAMES=()
for entry in $WORKERS; do WORKER_NAMES+=("${entry%%:*}"); done
NUM_WORKERS=${#WORKER_NAMES[@]}
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

pass() { echo "  [OK] $*"; }
fail() { echo "  [FAIL] $*" >&2; FAILS=$((FAILS+1)); }
FAILS=0

echo "=== 1. name resolution + ping ==="
for n in "$HOST_HOSTNAME" "${WORKER_NAMES[@]}"; do
  if getent hosts "$n" >/dev/null && ping -c1 -W2 "$n" >/dev/null 2>&1; then pass "$n resolves + pings"
  else fail "$n does not resolve/ping - check /etc/hosts + IPs"; fi
done

echo "=== 2. passwordless SSH host -> workers ==="
for w in "${WORKER_NAMES[@]}"; do
  if ssh $SSH_OPTS "$CLUSTER_USER@$w" "hostname" 2>/dev/null | grep -qi "$w"; then pass "ssh $w"
  else fail "ssh $CLUSTER_USER@$w (run setup_host.sh step 4-5 again)"; fi
done

echo "=== 3. munge (here + every worker) ==="
if munge -n 2>/dev/null | unmunge 2>&1 | grep -q "Success"; then pass "munge local"
else fail "munge local - check key perms 400 + clock (timedatectl)"; fi
for w in "${WORKER_NAMES[@]}"; do
  if ssh $SSH_OPTS "$CLUSTER_USER@$w" "munge -n 2>/dev/null | unmunge 2>&1 | grep -q Success"; then pass "munge $w"
  else fail "munge $w - key mismatch or clock skew"; fi
  if echo "from-$HOST_HOSTNAME" | ssh $SSH_OPTS "$CLUSTER_USER@$w" "munge 2>/dev/null" | unmunge 2>&1 | grep -q "Success"; then pass "munge cross host->$w"
  else fail "munge cross host->$w"; fi
done

echo "=== 4. NFS shared dir $SHARED_DIR ==="
[ -d "$SHARED_DIR" ] || fail "$SHARED_DIR missing on host"
echo "verify-$(date +%s)-$HOST_HOSTNAME" > "$SHARED_DIR/.verify_test" 2>/dev/null \
  && pass "host can write $SHARED_DIR" || fail "host cannot write $SHARED_DIR"
for w in "${WORKER_NAMES[@]}"; do
  if ssh $SSH_OPTS "$CLUSTER_USER@$w" "mountpoint -q $SHARED_DIR && cat $SHARED_DIR/.verify_test >/dev/null && echo ok-$w > $SHARED_DIR/.from-$w" 2>/dev/null; then
    pass "worker $w sees shared dir"
  else fail "worker $w NFS mount broken - check 'mount | grep $SHARED_DIR' + host firewall/NFS"; fi
done
ls "$SHARED_DIR"/.from-* 2>/dev/null && pass "all workers wrote back to share" || fail "worker write-back missing"
rm -f "$SHARED_DIR/.verify_test" "$SHARED_DIR"/.from-*

echo "=== 5. /dev/shm ==="
df -h /dev/shm | awk 'NR==2{print "  /dev/shm total="$2" avail="$4}'
for w in "${WORKER_NAMES[@]}"; do
  echo "  $w: $(ssh $SSH_OPTS "$CLUSTER_USER@$w" "df -h /dev/shm | awk 'NR==2{print \$2}'" 2>/dev/null || echo unknown)"
done

echo "=== 6. SLURM status ==="
sinfo || fail "sinfo failed - is slurmctld running?"
scontrol show nodes | grep -E "NodeName|State|CPUs" || true

echo "=== 7. srun hostname on all $NUM_WORKERS workers ==="
srun --nodes="$NUM_WORKERS" --partition=normal hostname || fail "srun across workers failed"

echo "=== 8. shared-dir batch job ==="
cat > "$SHARED_DIR/slurm_test.sh" <<'EOF'
#!/bin/bash
#SBATCH --job-name=share_test
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:02:00
#SBATCH --output=/mnt/hpc-shared/test_%j.out
echo "job $SLURM_JOB_ID on $(hostname) at $(date)"
echo "share contents: $(ls /mnt/hpc-shared | head -5 | tr '\n' ' ')"
EOF
# fix --output path if SHARED_DIR differs
sed -i "s|/mnt/hpc-shared|$SHARED_DIR|g" "$SHARED_DIR/slurm_test.sh"
JOB_ID="$(sbatch --parsable --partition=normal "$SHARED_DIR/slurm_test.sh")"
echo "  submitted job $JOB_ID"
for _ in $(seq 1 30); do
  squeue -j "$JOB_ID" 2>/dev/null | grep -q "$JOB_ID" || break
  sleep 2
done
sleep 2
if [ -f "$SHARED_DIR/test_${JOB_ID}.out" ]; then pass "batch job output:"; cat "$SHARED_DIR/test_${JOB_ID}.out"
else fail "no output $SHARED_DIR/test_${JOB_ID}.out - check scontrol show job $JOB_ID"; fi
scontrol show job "$JOB_ID" 2>/dev/null | grep -E 'JobState|RunTime' || true

echo ""
if [ "$FAILS" -eq 0 ]; then echo "=== ALL CHECKS PASSED ==="
else echo "=== $FAILS CHECK(S) FAILED - see [FAIL] lines above ==="; exit 1; fi
