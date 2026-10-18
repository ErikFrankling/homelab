# Homelab

The Docker Compose homelab was migrated to the single-node k3s cluster on
2026-07-24. This public repository now holds the active, namespace-scoped Flux
deployment and preserves the old Compose deployment as rollback documentation.

Live state and operating rules are recorded in [AGENTS.md](AGENTS.md). See
[docs/architecture.md](docs/architecture.md) for the design,
[docs/cutover-runbook.md](docs/cutover-runbook.md) for cutover/rollback,
[docs/backups.md](docs/backups.md) for the backup activation gates,
[docs/nix-builder.md](docs/nix-builder.md) for the Nix build server and binary
cache, [docs/gpu-passthrough.md](docs/gpu-passthrough.md) for the GPU passed through to
VM 200 for text-to-speech, and [docs/tailscale.md](docs/tailscale.md) for
remote access via the Tailscale subnet router on the Proxmox host.

## Current state

- Proxmox VM 100 (`docker`) is stopped with `onboot=0`; its 150 GiB disk and
  stopped containers remain the rollback source.
- VM 200 (`naiaclaw`) runs k3s with 12 GiB RAM and a 160 GiB disk. The host's
  GTX 1060 is passed through for TTS; RAM dropped from 13 GiB to 12 GiB because
  passthrough pins the whole guest allocation. See
  [docs/gpu-passthrough.md](docs/gpu-passthrough.md).
- `192.168.50.100` is VM 200's address (it took over from the Docker VM), so DuckDNS names and LAN DNS
  clients did not change.
- All six migrated workloads run in namespace `homelab`; Flux reconciles public
  `main` within one minute.
- Backup CronJobs are installed but suspended until off-cluster credentials and
  a successful restore test exist.
- The [Mullvad/qBittorrent/Servarr/Jellyfin package](kubernetes/optional/media/README.md)
  is designed but deliberately inactive pending a dedicated media disk and VPN
  material.

## GitOps boundary

- Flux reads public `main` once per minute.
- The reconciler is permission-bound to namespace `homelab`.
- Shared k3s Traefik changes are tracked under `kubernetes/bootstrap` and
  applied once as cluster infrastructure.
- SOPS-encrypted application Secrets are safe to commit; the age identity is
  never stored in Git.
- PersistentVolumeClaims are protected from Flux pruning.

## Layout

```text
kubernetes/bootstrap/       one-time namespace, RBAC, Flux and Traefik setup
kubernetes/homelab/         active homelab resources
kubernetes/optional/media/  inactive Mullvad/qBittorrent/Servarr/Jellyfin package
ops/                        migration helper and tracked node-level configuration
docs/                       architecture, cutover and backup runbooks
```

## Validation

```bash
kubectl kustomize kubernetes/homelab >/tmp/homelab.yaml
kubectl kustomize kubernetes/optional/media >/tmp/media.yaml
```

CI renders both packages, validates Kubernetes schemas, rejects plaintext
Secrets, and builds the pinned Hermes image when `hermes/` changes. CI has no
kubeconfig; Flux is the deployer.
