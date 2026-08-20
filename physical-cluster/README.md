# SLURM Physical Cluster — End-to-End Setup Scripts

Automated bring-up for a **1 host (control) + 3 worker** SLURM cluster on
**Ubuntu 22.04 LTS** machines connected over a **shared Ethernet LAN**.
Implements [`slurm-physical-cluster-setup.md`](../slurm-physical-cluster-setup.md)
as runnable scripts.

## Files

| File | Purpose |
|------|---------|
| `cluster.conf` | **Edit this first.** Username, hostnames, and LAN IPs. |
| `setup_host.sh` | Run on the control node. Configures the host and drives all workers end to end. |
| `setup_worker.sh` | Worker setup. Run automatically by `setup_host.sh`; usable standalone on one worker. |
| `verify.sh` | Run on the control node after setup to test the cluster. |

## Usage

1. On the control node, edit `cluster.conf`:

   - `CLUSTER_USER` — the identical username (with sudo) on **every** machine.
   - `HOST_HOSTNAME`, `HOST_IP` — the control node.
   - `WORKERS` — `hostname:lan-ip` entries for your compute nodes.
   - `CLUSTER_NAME` — optional display name.

2. Run the bring-up on the control node:

   ```bash
   ./setup_host.sh
   ```

   You will be prompted **once per worker** for its login password
   (`ssh-copy-id`) and **once per worker** for its sudo password
   (to enable passwordless sudo). Everything after that runs unattended.

3. Verify:

   ```bash
   ./verify.sh
   ```

### Manual worker setup (optional)

If you prefer not to have the host script drive a worker, run on that worker:

```bash
WORKER_NAME=worker1 ./setup_worker.sh
```

The Munge key and `slurm.conf` are only pushed from the host, so
`setup_host.sh` must run (at least through the key/distribution steps)
before a worker script can start its daemons.

## What the scripts do

- Install `slurm-wlm`, `munge`, `openssh-server`, `net-tools`, `vim`
- Set hostname and `/etc/hosts` (all nodes) — LAN-independent name resolution
- Enable NTP (Munge credentials are timestamped)
- Open firewall ports `22`, `6817`, `6818:6819`
- Passwordless SSH from host to workers
- Generate one shared Munge key on the host, distribute it securely
- Probe **live hardware** (`nproc`, `lscpu`, `free`) on every node and
  generate `slurm.conf` automatically — no manual `NodeName=` editing
- Validate the config with `slurmctld -t` before distributing it
- Start `slurmctld` + `slurmd` on the host and `slurmd` on each worker

Partitions created: `normal` (all workers, default) and `all`
(host + workers). `host` therefore also runs `slurmd` so it can compute.

## Troubleshooting

Use [Section 14 of the setup guide](../slurm-physical-cluster-setup.md).
Quick checks:

```bash
sinfo                      # node state - look for idle vs down/drain
scontrol show nodes        # details per node
sudo tail -f /var/log/slurm/slurmctld.log   # controller log (host)
sudo tail -f /var/log/slurm/slurmd.log      # worker log
munge | unmunge            # should end with: MUNGE: Success
```

If a node shows `down`: `sudo scontrol update nodename=worker1 state=resume`.
If Munge fails: clock skew — `sudo timedatectl set-ntp true` on every node.