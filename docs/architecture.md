# Homelab Kubernetes architecture

## Hosts and network identity

| Role | Address | Notes |
|---|---|---|
| Proxmox | `192.168.50.10` | Physical host |
| Legacy Docker VM | `192.168.50.100` | Powered-off rollback source, `onboot=0` |
| k3s VM (`naiaclaw`) | `192.168.50.100` | Single Kubernetes node, 8 vCPU (all host threads), 58 GiB RAM, GTX 1060 passed through |
| GPU machine | `192.168.50.232` | Reached as `gpu` by Hermes/OpenClaw |

DuckDNS resolves the apex and wildcard to `192.168.50.100`, the VM's only
address. It is the k3s node IP (`ops/k3s/config.yaml`), so ServiceLB publishes
it as every LoadBalancer ingress IP and kube-proxy delivers LAN traffic on the
source-preserving path; Traefik's `lan-only` allowlist depends on that. Until
2026-10-18 the node IP was `.200` with `.100` as a second address, which needed
`node-external-ip` and an `advertise-address` pin. VM 100 is also configured
with `.100` and must never run.

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
so containerd can pull through the node-IP hairpin. Vaultwarden and Open WebUI
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

## CPU requests are zero everywhere (policy, 2026-10-23)

Erik's rule: CPU never gates scheduling on the homelab; only RAM does. Slow is
fine, `Pending` is not. On 2026-10-23 the node sat at 99% requested CPU (Onyx,
alloy, the naiaclaw sandboxes' 500m init containers) and the rollout of
`time-v2` stayed `Pending`, taking Time down.

- `kubernetes/bootstrap/policies/zero-cpu-requests.yaml` is a Kyverno
  ClusterPolicy that rewrites every container's CPU request to `0` at pod
  creation, in every namespace except `kube-system`, `kyverno`, `flux-system`
  and `cert-manager` (their small requests are the CPU weight that keeps DNS,
  ingress and the controllers ahead of everything else). It covers Helm charts,
  naiaclaw sandboxes and anything added later. It is cluster-scoped, so
  the `homelab-policies` Flux Kustomization (`kubernetes/bootstrap/flux.yaml`,
  service account `homelab-policy-reconciler`, which can write only
  ClusterPolicies and PriorityClasses) applies it from Git; after a node rebuild
  apply `namespace-rbac.yaml` and `flux.yaml` from `kubernetes/bootstrap`.
- Manifests in this repository carry no CPU requests and no CPU limits.
- Running pods can be lowered without a restart:
  `kubectl patch pod P --subresource resize --type=strategic -p '{"spec":{"containers":[{"name":"C","resources":{"requests":{"cpu":"0"}}}]}}'`.
  **Init containers cannot be resized**, and the scheduler still counts a running
  pod's init-container request. Only recreating the pod clears it.
- Recreating a long-running naiaclaw sandbox needs care: its pod template keeps
  the image it was created with and its ConfigMap the config of that time, so a
  plain pod delete can pair an old gateway with a newer config (`byoproof` went
  into `CrashLoopBackOff`, `Invalid config ... gateway.auth`). The safe way is
  what naiaclaw's own restart does: snapshot the workspace directory
  (`/var/lib/rancher/k3s/storage/<pv>_<ns>_workspace-<name>`), rewrite the
  ConfigMaps with the API's own code from inside the API pod that owns the
  tenant (`rematerializeInstance(account, name)` after
  `AppDataSource.initialize()`; `naiaclaw-api` for `nc-acme-*`, a different
  deployment and database for `nc-oc96-*`, `nc-web-*`, `nc-portal-*`), move the
  image to that API's `OPENCLAW_SANDBOX_IMAGE`, then delete the pod. Never run
  it with the wrong API for a namespace, and never move a volume already
  migrated by a newer OpenClaw (state schema 18) back to an older image. The
  `nc-acme-*` sandboxes were recreated this way on 2026-10-23; every new pod
  carries `0` CPU requests from the policy.
- Core services (`time`, `time-v2`, `notify-gateway`, `executor`, `brain`,
  `gatus`, `grafana`) run with `priorityClassName: homelab-core`, so when memory
  is short they preempt batch and search workloads. `low-priority` (-100) is for
  best-effort work such as the alloy DaemonSet.
- `time-v2` image `v2-daba5bf` (the time repo's `v2` branch) has no `[mcp]`
  config support and crash-loops on the config here; stay on `v2-70f326d` (the
  `time-mcp` line) until the branches merge.

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

Beyond keeping the manifests clean, the node is set up so CPU gates as little
as this stack allows:

- **The kubelet runs with `cpu-cfs-quota=false`** (`ops/k3s/config.yaml`,
  installed at `/etc/rancher/k3s/config.yaml`). CPU limits are never enforced;
  a limit in a manifest is dead text.
- **The VM owns all 8 host threads.** Proxmox caps a VM's vCPUs at the host's
  logical CPU count, so 8 is the hardware ceiling. vCPUs are ordinary host
  threads, not reservations — the Proxmox host (which only routes Tailscale)
  needs nothing carved out and is never starved. This doubles the request
  ledger, which only runtime-stamped workloads draw from (naiaclaw Sandboxes,
  ~500m each); nothing deployed from this repository requests CPU at all.

There is no software switch that disables CPU-request accounting entirely —
verified empirically on this cluster on 2026-08-15. The scheduler's
`NodeResourcesFit.ignoredResources` option only applies to extended resources
(a 10-CPU-request pod still failed with `Insufficient cpu`), and the kubelet
independently re-checks fit with hard-coded defaults at bind time (the same
pod pinned via `nodeName` to bypass the scheduler was rejected `OutOfcpu`).
The only software workaround is rewriting requests at admission, which was first
rejected as pod-fiddling and is now done by the Kyverno policy above. If the 8-CPU ledger ever
fills again, the honest options are lowering the sandbox catalog's CPU
requests at their source or more hardware.

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

VM 200 has 58 GiB RAM and a 160 GiB root disk. After cutover, the node reported
no memory/disk pressure and about 76 GiB disk space available. PCI passthrough
locks and prefaults the entire guest allocation at start; see
[gpu-passthrough.md](gpu-passthrough.md). Media is excluded
from root-backed storage; the optional package requires a separate static local
PV with reclaim policy `Retain`.

The powered-off Docker VM and its disk remain the first rollback layer until a
real off-cluster backup has completed and passed an isolated restore test.
