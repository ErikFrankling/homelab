# Homelab Kubernetes architecture

## Hosts and network identity

| Role | Address | Notes |
|---|---|---|
| Proxmox | `192.168.50.169` | Physical host |
| Legacy Docker VM | `192.168.50.100` | Rollback source; stopped after cutover |
| k3s VM (`naiaclaw`) | `192.168.50.200` | Single Kubernetes node |
| Homelab service VIP | `192.168.50.100` | Moves to k3s after Docker stops |
| GPU machine | `192.168.50.232` | Reached as `gpu` by Hermes/OpenClaw |

DuckDNS currently resolves the apex and wildcard to `192.168.50.100`. Moving
that address to k3s preserves every hostname, existing LAN DNS configuration,
and any router rules. The VIP systemd unit must never be active while VM 100 is
running.

## Reconciliation and trust boundary

The cluster already provides source-controller, kustomize-controller, and
helm-controller. Bootstrap creates a public `GitRepository` and one
`Kustomization` in `homelab`.

The Kustomization impersonates `homelab-reconciler`, which has namespaced admin
rights plus namespaced access to Traefik CRDs. It cannot change shared cluster
infrastructure or another experiment. A one-minute pull interval provides CD
without exposing a webhook receiver.

Shared Traefik is a deliberate exception: its `HelmChartConfig` and encrypted
DuckDNS Secret live under `kubernetes/bootstrap/traefik` and are applied by a
cluster administrator. Traefik stores ACME state on a retained local-path PVC,
redirects HTTP to HTTPS, and obtains one apex/wildcard Let's Encrypt certificate
through DuckDNS DNS-01.

## Applications

| Application | Kubernetes persistence | Route |
|---|---|---|
| AdGuard Home | `adguard-data` | `adguard.*`, DNS 53 TCP/UDP, setup 3000 |
| Vaultwarden | `vaultwarden-data` | `vault.*` |
| Hermes | `hermes-data` | No HTTP route |
| Open WebUI | `openwebui-data` | `chat.*` |
| SearXNG | Encrypted settings, ephemeral cache | Internal only |
| OpenClaw | `openclaw-data` | `claw.*`, direct 18789 |

The Traefik dashboard, AdGuard, OpenClaw, and the four experiment passthrough
routes use `lan-only`. Vaultwarden and Open WebUI preserve their previous
non-LAN-restricted behavior.

External experiment routes remain in Kubernetes as selectorless Services plus
EndpointSlices targeting the node's existing NodePorts. `p9eval` was already
unavailable on port 30080 before migration; it remains represented so the
pre-existing failure is explicit.

Images are pinned to the exact digests observed on the Docker host. Hermes is
also pinned to upstream commit
`43bca6d107c86efc7e60a4a35ca8a55e1b4b4c1e` and built by GitHub Actions.

## Storage and lifecycle

Application data uses the single-node `local-path` storage class. PVC requests
are descriptive rather than enforced quotas. Each PVC carries
`kustomize.toolkit.fluxcd.io/prune: disabled`; deleting a PVC manually still
deletes its local data.

VM 200's root disk is 160 GiB. Media is excluded from this storage. The optional
media package requires a separate static local PV with reclaim policy `Retain`.

The powered-off Docker VM and its disk remain the first rollback layer until a
real off-cluster backup has completed and passed an isolated restore test.
