# Pure Arch Linux base image - no Ubuntu, no apt
FROM archlinux:latest

# Refresh the package database and install everything with pacman
RUN pacman -Syu --noconfirm \
    slurm-llnl \
    munge \
    openssh \
    sudo \
    vim \
    iputils \
    iproute2 \
    net-tools \
    inetutils \
    && rm -rf /var/cache/pacman/pkg

# The slurm-llnl and munge packages already create the slurm + munge
# users/groups through pacman's sysusers hook, so only create them if the
# packages did not. slurm uses the same UID/GID (64030) as a real Arch install.
RUN id slurm >/dev/null 2>&1 || { groupadd -r -g 64030 slurm \
    && useradd -r -u 64030 -g 64030 -d /var/lib/slurm-llnl -s /bin/nologin slurm; } \
    && id munge >/dev/null 2>&1 || { groupadd -r munge \
    && useradd -r -g munge -d /var/log/munge -s /bin/nologin munge; }

# Munge runtime + lib directories, owned by the munge user
RUN mkdir -p /run/munge /var/lib/munge \
    && chown munge:munge /run/munge /var/lib/munge \
    && chmod 0700 /run/munge

# SSH: runtime dir + allow root login (needed for passwordless SSH between nodes)
RUN mkdir -p /var/run/sshd \
    && echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config

# SLURM spool directories
RUN mkdir -p /var/spool/slurm /var/spool/slurmd

# Entrypoint starts the daemons directly (no systemd inside the containers)
COPY setup/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
