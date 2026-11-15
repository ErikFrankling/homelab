#!/bin/bash
# Worker container: sshd for `heavy` on the PC, plus a janitor that keeps
# /work and old emulators from piling up. Jobs run as root over SSH against
# this pod's own store (no daemon needed for root), inside its memory limit.
set -euo pipefail

state=/nix/var/worker
# /tmp is a subPath of the volume (apps/agent-worker.yaml), root-made 0755 and
# holding the dead jobs' temp files of the last run: world-writable and sticky
# again, and empty, as the container's own layer was at every start.
chmod 1777 /tmp
find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2> /dev/null || true
export PATH="$state/bin:$PATH"
export NIX_SSL_CERT_FILE="$state/ca-bundle.crt"

getent group nixbld > /dev/null || groupadd --gid 30000 nixbld
for i in $(seq 1 16); do
  getent passwd "nixbld$i" > /dev/null \
    || useradd --no-create-home --home-dir /var/empty \
      --uid $((30000 + i)) --gid nixbld --groups nixbld \
      --shell /usr/sbin/nologin "nixbld$i"
done
getent passwd sshd > /dev/null \
  || useradd --system --no-create-home --home-dir /var/empty --shell /usr/sbin/nologin sshd
# The emulator wants the kvm group's device; root has it anyway.
getent group kvm > /dev/null || groupadd --system kvm

mkdir -p /etc/nix /root/.ssh /root/.config/nixpkgs /var/empty /run/sshd \
  "$state/ssh" "$state/build" "$state/work" "$state/android"
# A link into the unhashed scripts ConfigMap: a nix.conf edit reaches running
# jobs in about a minute instead of restarting the pod and killing them.
ln -sfn /scripts/nix.conf /etc/nix/nix.conf
# Jobs over SSH do not see the container environment.
echo "$NIXPKGS_REV" > "$state/nixpkgs-rev"
echo "$WORKER_BIG_MEMORY" > "$state/memory-big"
echo "$WORKER_SMALL_MEMORY" > "$state/memory-small"
cp /scripts/nixpkgs-config.nix /root/.config/nixpkgs/config.nix
# Workspaces are synced with the PC user's files; let git and nix use them.
git config --global safe.directory "*"
install -m 0600 /config/authorized_keys /root/.ssh/authorized_keys
chmod 0700 /root/.ssh
ln -sfn "$state/work" /work
# Gradle, pnpm and friends keep their caches on the volume, not the container layer.
for cache in .gradle .cache .local .npm .android; do
  mkdir -p "$state/home/$cache"
  ln -sfn "$state/home/$cache" "/root/$cache"
done

if [ ! -f "$state/ssh/ssh_host_ed25519_key" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$state/ssh/ssh_host_ed25519_key"
fi

touch /run/heavy-workspace-leases-ready
mkdir -p /work/.queue /work/.slots
rm -f /work/.queue/* /work/.slots/*.job
# A failure here must not keep the pod from starting; jobs then just run
# without their own limits.
bash /config/cgroups.sh || { echo "cgroups: setup failed; jobs run without their own limits" >&2; rm -f "$state/cgroup"; }

"$(readlink -f "$state/bin/sshd")" -D -e -f /config/sshd_config &
sshd=$!

# One cleanup authority: hot-updated housekeeping.sh uses persistent leases.
# No second embedded janitor can bypass those locks. Ephemeral marker also
# gates admission until an existing pod's old janitor is explicitly fenced.
trap 'kill "$sshd" 2> /dev/null; pkill -f qemu-system 2> /dev/null' TERM INT
wait "$sshd"
exit 1
