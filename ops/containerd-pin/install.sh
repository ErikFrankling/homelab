#!/bin/sh
# Pins the images that cannot be pulled again, so the kubelet's image GC never
# deletes them. Idempotent; run as root:
#   ssh naiaclaw 'sudo sh -s' < ops/containerd-pin/install.sh
#
# brain, fleet-*, cliproxy-management-network and cpa-usage-keeper are built on
# this node (imagePullPolicy: Never, no registry holds them). On 2026-11-18 the
# disk passed the old image-GC start (85%), the kubelet removed the ones no
# running container used at that moment, and those pods could not start again.
# cliproxy's own image is pinned too: it must start even if Docker Hub is
# unreachable.
#
# containerd labels an image io.cri-containerd.pinned=pinned; the CRI reports it
# as `pinned: true` and the kubelet's image GC skips pinned images. k3s has no
# setting for this (containerd's pinned_images only takes the sandbox image).
# A re-import of a tag can drop the label, so a timer applies it every 10 minutes.
set -eu

cat > /etc/systemd/system/containerd-pin.service <<'UNIT'
[Unit]
Description=Pin the local-only images against kubelet image GC (homelab ops/containerd-pin)

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'k3s ctr -n k8s.io images ls -q | grep -E "^docker\\.io/(library/(brain|fleet-[a-z-]+|cliproxy-management-network|cpa-usage-keeper):|eceasy/cli-proxy-api[:@])" | while read -r ref; do k3s ctr -n k8s.io images label "$ref" io.cri-containerd.pinned=pinned > /dev/null; done'
UNIT

cat > /etc/systemd/system/containerd-pin.timer <<'UNIT'
[Unit]
Description=Pin the local-only images every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now containerd-pin.timer
systemctl start containerd-pin.service
k3s crictl images -o json | grep -c '"pinned": *true' || true
