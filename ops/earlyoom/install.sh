#!/bin/sh
# Kills the biggest expendable process on naiaclaw before the node starts to
# thrash. Idempotent; run as root:
#   ssh naiaclaw 'sudo sh -s' < ops/earlyoom/install.sh
#
# The node has 52 GiB, no swap, and memory limits adding up to over 300% of it.
# When it fills up, the kernel drops all page cache and keeps reclaiming long
# before its own OOM killer fires: on 2026-11-02 that took about 25 minutes at
# load 800-990, with no SSH, Gatus or API server. k3s's kubelet does not evict
# on memory either (its default evictionHard only covers disk).
#
# earlyoom reads MemAvailable and picks by oom_score, as the kernel would, so
# low memory requests still go first: SIGTERM under 6% (3.1 GiB), SIGKILL under
# 3%. There is no swap, so -s 100,100 leaves memory as the only condition.
# --prefer puts Nix evaluations and compilers first, since builds can be rerun.
# --avoid keeps the control plane out of it. It logs each kill to the journal.
set -eu
export DEBIAN_FRONTEND=noninteractive

command -v earlyoom > /dev/null || apt-get install -y --no-install-recommends earlyoom

cat > /etc/default/earlyoom <<'CONF'
# Managed by the homelab repo, ops/earlyoom/install.sh.
EARLYOOM_ARGS="-m 6,3 -s 100,100 -r 3600 --prefer ^(nix|rustc|cc1|cc1plus|clang|ld|ld.lld)$ --avoid ^(k3s-server|k3s|containerd|containerd-shim|sshd|systemd|systemd-.*|tailscaled|qemu-ga)$"
CONF

# The packaged unit runs as a dynamic user, which cannot raise its own priority
# (-p). It must still run when load is in the hundreds, so systemd sets it.
mkdir -p /etc/systemd/system/earlyoom.service.d
cat > /etc/systemd/system/earlyoom.service.d/homelab.conf <<'CONF'
[Service]
Nice=-20
OOMScoreAdjust=-1000
CONF
systemctl daemon-reload

systemctl enable earlyoom
systemctl restart earlyoom
