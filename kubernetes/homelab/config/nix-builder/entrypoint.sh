#!/bin/bash
# Builder container. The PC builds with `--store ssh-ng://`: each SSH
# connection runs its own `nix-daemon --stdio` as root against the store on the
# volume, so every build is a child of this container and counts against its
# memory limit. The long-running nix-daemon below exists for harmonia, which
# reads path metadata through the daemon socket on the shared volume.
set -euo pipefail

state=/nix/var/builder
export PATH="$state/bin:$PATH"
export NIX_SSL_CERT_FILE="$state/ca-bundle.crt"

# Sandboxed builds drop to these users, one each, and a build waits for a free
# one ("waiting for a free build user ID"). That makes their number the one
# limit across all clients: max-jobs and cores in nix.conf count per
# connection, and every `--store ssh-ng://` client gets its own daemon. With
# 32 users, 8 concurrent wasm-box clients ran 18+ rustc at once on 2026-11-18,
# the container hit its 24 GiB limit 66 times, and the OOM killer took the
# nightly's evaluation (5 GB) and the pc build twice. 3 builds x cores 3 is
# 9 compilers for 8 node threads, ~12 GiB of rustc beside one evaluation.
getent group nixbld > /dev/null || groupadd --gid 30000 nixbld
for i in $(seq 1 3); do
  getent passwd "nixbld$i" > /dev/null \
    || useradd --no-create-home --home-dir /var/empty \
      --uid $((30000 + i)) --gid nixbld --groups nixbld \
      --shell /usr/sbin/nologin "nixbld$i"
done
getent passwd sshd > /dev/null \
  || useradd --system --no-create-home --home-dir /var/empty --shell /usr/sbin/nologin sshd

mkdir -p /etc/nix /root/.ssh /var/empty /run/sshd \
  "$state/ssh" "$state/build" /nix/var/nix/gcroots/auto-update
cp /config/nix.conf /etc/nix/nix.conf

# ConfigMap volumes are group- and world-writable, which sshd's StrictModes
# refuses for an authorized_keys file.
install -m 0600 /config/authorized_keys /root/.ssh/authorized_keys
chmod 0700 /root/.ssh

# Host keys live on the volume so the PC's known_hosts entry survives restarts.
if [ ! -f "$state/ssh/ssh_host_ed25519_key" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$state/ssh/ssh_host_ed25519_key"
fi

nix-daemon &
daemon=$!
# sshd insists on being started by absolute path.
"$(readlink -f "$state/bin/sshd")" -D -e -f /config/sshd_config &
sshd=$!

# Either one dying takes the container down, so the kubelet restarts both.
trap 'kill "$daemon" "$sshd" 2> /dev/null' TERM INT
wait -n "$daemon" "$sshd"
exit 1
