# Homelab Kubernetes architecture

## Hosts and network identity

| Role | Address | Notes |
|---|---|---|
| Proxmox | `192.168.50.169` | Physical host |
| Legacy Docker VM | `192.168.50.100` | Powered-off rollback source, `onboot=0` |
| k3s VM (`naiaclaw`) | `192.168.50.200` | Single Kubernetes node, 12 GiB RAM, GTX 1060 passed through |
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
the Tailscale tailnet (`100.64.0.0/10`, see
[tailscale.md](tailscale.md)). Serving it at its own HTTPS origin lets the
browser treat
opencode as same-origin and skips opencode's cross-origin pairing handshake; the
opencode server itself runs without a password.

Images are pinned to the exact digests observed on the Docker host. Hermes is
also pinned to upstream commit
`43bca6d107c86efc7e60a4a35ca8a55e1b4b4c1e` and built by GitHub Actions.

## CPU requests and limits are deliberately unset

Manifests in this repository set memory requests and limits but **no CPU
requests and no CPU limits**. This is intentional and specific to a single-node
cluster.

A CPU request is a reservation the scheduler subtracts from allocatable capacity
whether or not the pod uses it. Its purpose is bin-packing across machines. With
one node there is nothing to pack, so the number buys nothing and only creates
`Pending` pods: on 2026-08-06 the node sat at 99% requested CPU while actual
usage was a fraction of that, and nothing new could schedule.

Removing only the requests is not enough: **a container with a CPU limit and no
CPU request gets its request defaulted to the limit**, silently recreating the
reservation. That is exactly what happened after the first pass — the node
showed 92% requested CPU and four pods sat `Pending` for days with no CPU
request written anywhere in this repository. A CPU limit also imposes CFS quota
throttling, a hard ceiling that idles cores while a pod is starved. So both go.

CPU is compressible. With no requests and no limits, the Linux CFS scheduler
time-shares the node the way a normal operating system does — under load
everything gets slower in proportion, and nothing fails to schedule. For a
homelab that is the correct trade: contention is cheap, `Pending` is expensive.

Beyond keeping the manifests clean, the cluster enforces this stance at the
node level so a forgotten CPU request or limit in a future manifest can never
bring back `Pending` pods or throttling:

- **The kubelet runs with `cpu-cfs-quota=false`** (`ops/k3s/config.yaml`,
  installed at `/etc/rancher/k3s/config.yaml`). CPU limits are never enforced;
  a limit in a manifest is dead text.
- **A Kyverno `ClusterPolicy` (`zero-cpu-requests`,
  `kubernetes/bootstrap/kyverno/`) forces `requests.cpu: "0"` onto every pod at
  admission** outside `kube-system`/`kyverno`/`flux-system`. This also covers
  workloads stamped at runtime by an API rather than a manifest, such as the
  naiaclaw `agents.x-k8s.io` Sandboxes. Forcing `0` rather than deleting the
  field matters: the apiserver defaults an absent CPU request from the limit
  *after* mutating webhooks, so deletion silently reinstates the reservation.
  The policy is admin-applied like Traefik (the `homelab` Kustomization has no
  cluster-scoped rights) and fails open, so a broken Kyverno cannot block
  admission — it merely returns the cluster to manifests-only behavior.

Rules that go with this choice:

- **Memory requests stay.** Memory is incompressible. Removing memory requests
  invites OOM kills and breaks eviction ordering. Keeping them also holds pods
  in `Burstable` QoS rather than `BestEffort`, which is evicted first.
- **`kube-system` is untouched.** CFS shares derive from requests, so if
  everything requests nothing, everything gets an equal share. CoreDNS and
  Traefik should win under contention, so their requests are left alone.
- **Do not copy this to a multi-node or cloud cluster.** There the requests are
  load-bearing: they drive placement, cluster autoscaler scale-up and
  scale-down, and any per-tenant guarantee. Removing them there causes
  unschedulable workloads and silent performance cliffs, not savings.

## Storage and lifecycle

Application data uses the single-node `local-path` storage class. PVC requests
are descriptive rather than enforced quotas. Each PVC carries
`kustomize.toolkit.fluxcd.io/prune: disabled`, and the five live application PVs
were patched to reclaim policy `Retain`. Manual PVC deletion still causes an
outage and leaves a `Released` PV that must be rebound deliberately.

VM 200 has 12 GiB RAM and a 160 GiB root disk. After cutover, the node reported
no memory/disk pressure and about 76 GiB disk space available. RAM was reduced
from 13 GiB on 2026-08-06: PCI passthrough locks and prefaults the entire guest
allocation, so 13 GiB of the host's 15.6 GiB no longer fit alongside Proxmox.
See [gpu-passthrough.md](gpu-passthrough.md). Media is excluded
from root-backed storage; the optional package requires a separate static local
PV with reclaim policy `Retain`.

The powered-off Docker VM and its disk remain the first rollback layer until a
real off-cluster backup has completed and passed an isolated restore test.
