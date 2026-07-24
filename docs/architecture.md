# Homelab Kubernetes architecture

## Hosts and network identity

| Role | Address | Notes |
|---|---|---|
| Proxmox | `192.168.50.169` | Physical host |
| Legacy Docker VM | `192.168.50.100` | Powered-off rollback source, `onboot=0` |
| k3s VM (`naiaclaw`) | `192.168.50.200` | Single Kubernetes node, 13 GiB RAM |
| Homelab service VIP | `192.168.50.100` | Active on k3s through systemd |
| GPU machine | `192.168.50.232` | Reached as `gpu` by Hermes/OpenClaw |

DuckDNS resolves the apex and wildcard to `192.168.50.100`. The address is
installed by `homelab-vip.service` before k3s starts and is advertised as the
node external IP through `ops/k3s/config.yaml`. This makes K3s ServiceLB use its
source-preserving path for the VIP. The VIP systemd unit must never be active
while VM 100 is running.

K3s ServiceLB owns host port 53 for AdGuard. That host-port rule also intercepts
the systemd-resolved stub address, so `/etc/resolv.conf` on `naiaclaw` points to
`/run/systemd/resolve/resolv.conf` (the uplink resolver file), not
`stub-resolv.conf`.

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

The Traefik dashboard, AdGuard, OpenClaw, and experiment passthrough routes use
`lan-only`. The registry alone uses `lan-and-cluster`, adding pod/service CIDRs
so containerd can pull through the VIP hairpin. Vaultwarden and Open WebUI
preserve their previous non-LAN-restricted behavior.

External experiment routes remain in Kubernetes as selectorless Services plus
EndpointSlices targeting the node's existing NodePorts. `p9eval` was already
unavailable on port 30080 before migration; it remains represented so the
pre-existing failure is explicit.

`opencode.*` is an external route to the opencode web/agent server on the
GPU/PC box (`192.168.50.232:4096`), also modelled as a selectorless Service plus
EndpointSlice. It carries `lan-only`, so it is reachable only from the LAN and
the `10.8.0.0/24` VPN. Serving it at its own HTTPS origin lets the browser treat
opencode as same-origin and skips opencode's cross-origin pairing handshake; the
opencode server itself runs without a password.

Images are pinned to the exact digests observed on the Docker host. Hermes is
also pinned to upstream commit
`43bca6d107c86efc7e60a4a35ca8a55e1b4b4c1e` and built by GitHub Actions.

## Storage and lifecycle

Application data uses the single-node `local-path` storage class. PVC requests
are descriptive rather than enforced quotas. Each PVC carries
`kustomize.toolkit.fluxcd.io/prune: disabled`, and the five live application PVs
were patched to reclaim policy `Retain`. Manual PVC deletion still causes an
outage and leaves a `Released` PV that must be rebound deliberately.

VM 200 has 13 GiB RAM and a 160 GiB root disk. After cutover, the node reported
no memory/disk pressure and about 76 GiB disk space available. Media is excluded
from root-backed storage; the optional package requires a separate static local
PV with reclaim policy `Retain`.

The powered-off Docker VM and its disk remain the first rollback layer until a
real off-cluster backup has completed and passed an isolated restore test.
