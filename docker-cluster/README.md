# SLURM Cluster in Docker (Pure Arch) — Quick Start

Ready-to-run files for a 3-node SLURM cluster (1 controller + 2 workers) using **pure Arch Linux** containers — no Ubuntu, no systemd inside the containers.

See the full walkthrough in [`../slurm-docker-setup.md`](../slurm-docker-setup.md).

## Quick Start

```bash
mkdir -p config/munge shared/job_scripts
dd if=/dev/urandom bs=1024 count=1 of=config/munge/munge.key 2>/dev/null
chmod 400 config/munge/munge.key

docker compose up -d
docker exec -it slurm_master bash
sinfo
```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the pure-Arch image (SLURM + Munge + SSH via pacman) |
| `docker-compose.yml` | Defines master / worker1 / worker2 + shared volumes |
| `config/slurm.conf` | SLURM cluster config, mounted on all 3 nodes |
| `setup/entrypoint.sh` | Starts munged / sshd / slurmctld / slurmd (no systemd) |

## Notes

- The `config/munge/munge.key` secret is **never committed** (see `.gitignore`).
- Job scripts and outputs go in `shared/job_scripts/` — visible on all nodes.
- To stop everything: `docker compose down`