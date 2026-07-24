# homelab
# Homelab

This repository preserves the legacy Docker Compose deployment and contains its
replacement: a namespace-scoped Flux deployment for the single-node k3s cluster
on `naiaclaw`.

Current migration state is recorded in [AGENTS.md](AGENTS.md). The intended
architecture is described in [docs/architecture.md](docs/architecture.md), and
the exact rollback-aware procedure is in
[docs/cutover-runbook.md](docs/cutover-runbook.md).

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
kubernetes/optional/media/  inactive Mullvad/qBittorrent/*arr/Jellyfin package
ops/                        cutover-only helper and legacy-IP unit
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
