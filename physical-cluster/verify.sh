#!/usr/bin/env bash
# ============================================================
#  Verify the SLURM cluster after setup_host.sh.
#  Run on the control node (host).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cluster.conf"

WORKER_NAMES=()
for entry in $WORKERS; do
  WORKER_NAMES+=("${entry%%:*}")
done
NUM_WORKERS=${#WORKER_NAMES[@]}

echo "=== cluster status (sinfo) ==="
sinfo

echo
echo "=== detailed node state (scontrol show nodes) ==="
scontrol show nodes

echo
echo "=== run 'hostname' on all $NUM_WORKERS workers ==="
srun --nodes="$NUM_WORKERS" hostname

echo
echo "=== submit a test batch job ==="
cat > /tmp/slurm_cluster_test.sh <<'EOF'
#!/bin/bash
#SBATCH --job-name=cluster_test
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:02:00
#SBATCH --output=/tmp/cluster_test_%j.out
echo "Test job $SLURM_JOB_ID running on $(hostname) at $(date)"
EOF

JOB_ID="$(sbatch --parsable /tmp/slurm_cluster_test.sh)"
echo "submitted job $JOB_ID"

for _ in $(seq 1 30); do
  if ! squeue -j "$JOB_ID" 2>/dev/null | grep -q "$JOB_ID"; then
    break
  fi
  sleep 2
done
sleep 2

echo
echo "=== job result ==="
cat "/tmp/cluster_test_${JOB_ID}.out"

echo
echo "=== final job state ==="
scontrol show job "$JOB_ID" | grep -E 'JobState|RunTime'