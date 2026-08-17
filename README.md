# Paanduv HPC — SLURM Cluster Setup Guides

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![SLURM](https://img.shields.io/badge/SLURM-26.x-blue.svg)](https://slurm.schedmd.com)
[![Platform](https://img.shields.io/badge/platform-Linux-important.svg)](https://www.linux.org)

Beginner-friendly, step-by-step guides for building your own **SLURM** (Simple Linux Utility for Resource Management) cluster — from a single laptop to a full multi-machine cluster over a shared Ethernet LAN.

Both guides share the same concepts (SLURM, Munge, SSH) and the same commands, so you can learn in a Docker sandbox first and then apply it to real hardware.

## What's Inside

| Path | What it is |
|------|-----------|
| [`slurm-docker-setup.md`](slurm-docker-setup.md) | 3-node simulated cluster (1 controller + 2 workers) in Docker on your Arch Linux laptop. **Pure Arch containers, no systemd.** |
| [`slurm-physical-cluster-setup.md`](slurm-physical-cluster-setup.md) | 1 controller + 4 workers on real Ubuntu 22.04 machines over a shared Ethernet LAN — no dedicated physical network needed. |
| [`docker-cluster/`](docker-cluster/) | Ready-to-run files from the Docker guide (`Dockerfile`, `docker-compose.yml`, `slurm.conf`, `entrypoint.sh`). |

## Quick Start

### Option A — Try it on one laptop (Docker)

1. Install Docker on Arch Linux:

   ```bash
   sudo pacman -Syu docker docker-compose
   sudo systemctl enable --now docker containerd
   sudo usermod -aG docker $USER   # then re-login
   ```

2. Copy the cluster files and generate the shared Munge key:

   ```bash
   cp -r docker-cluster ~/slurm-cluster
   cd ~/slurm-cluster
   mkdir -p config/munge shared/job_scripts
   dd if=/dev/urandom bs=1024 count=1 of=config/munge/munge.key 2>/dev/null
   chmod 400 config/munge/munge.key
   ```

3. Build and start the 3 nodes:

   ```bash
   docker compose up -d
   ```

4. Open a terminal on the controller and check the cluster:

   ```bash
   docker exec -it slurm_master bash
   sinfo
   srun --nodes=2 hostname
   ```

> Full walkthrough: **[`slurm-docker-setup.md`](slurm-docker-setup.md)**

### Option B — Real cluster (Ubuntu 22.04)

Follow **[`slurm-physical-cluster-setup.md`](slurm-physical-cluster-setup.md)**. You'll need 5 machines (1 controller + 4 workers) connected to the same Ethernet LAN.

## Requirements

| Option | Hardware | Software |
|--------|----------|----------|
| Docker (laptop) | 8 GB RAM (16 GB recommended), 20 GB disk | Arch Linux, Docker + Compose |
| Physical | 5 machines, 4 GB RAM each minimum | Ubuntu 22.04 LTS |

## Concepts You'll Learn

- **SLURM** — the job scheduler (which job runs where, with what resources)
- **Munge** — the shared-secret authentication service between nodes
- **SSH** — passwordless remote login between nodes
- **Docker** — how to simulate multiple nodes on one machine
- Job submission with `sbatch`, `srun`, `squeue`, `sinfo`, and `scancel`

## Contributing

Found a bug in a guide, or a cleaner way to do something? Open an issue or a pull request. Keep changes beginner-friendly and test anything you add.

## License

[MIT](LICENSE) © Paanduv HPC Contributors