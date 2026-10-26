# Homelab Notes for Agents

Last verified: 2026-07-24 from the local repo, GitHub, `ssh proxmox`,
`ssh docker`, and `ssh naiaclaw`.

## Working Rules

- This public repo and GitHub `main` are the active homelab source. Check Flux
  and the live k3s host before assuming a local checkout is current.
- The Docker VM is a powered-off rollback artifact. Never start it while
  VM 200 owns its address, `192.168.50.100`.
- The frozen Docker checkout is `/home/debian/homelab` at commit `e16ee23`.
  It is reachable by SSH only during an intentional rollback.
- Do not edit live host config, restart services, resize VMs, or change Kubernetes workloads unless the user explicitly asks.
- This repository is **public**: `https://github.com/ErikFrankling/homelab`.
  Plaintext credentials, kubeconfigs, VPN material, certificates, and application
  secrets must never be committed.
- Kubernetes secrets are encrypted with SOPS/age. The age identity is kept
  outside Git at `/home/erikf/.config/sops/age/homelab-k3s.agekey` and installed
  as `homelab/sops-age`. Only the age recipient is public in `.sops.yaml`.
- Avoid committing secrets. Live env files are under `/home/debian/.secrets` on the Docker VM and should stay out of git.

## Current Deployment State

The Docker-to-k3s migration completed on 2026-07-24:

- Docker commit `e16ee23` preserves the four reverse-proxy routes that were
  previously uncommitted on the live host.
- All application file manifests matched by aggregate SHA-256 after the copy.
  Vaultwarden/Open WebUI SQLite integrity checks and selected row counts matched
  the stopped sources.
- VM 100 is stopped with `onboot=0`; its containers, data, and 150 GiB disk are
  intact. VM 200 now owns `192.168.50.100`.
- The obsolete `husk` Helm release and namespace were removed on 2026-07-24.
  A verified logical PostgreSQL dump is retained privately under
  `/home/ubuntu/retired-husk` on `naiaclaw`.
- VM 200's disk was expanded online from 80 GiB to 160 GiB. The root filesystem
  had about 76 GiB free after migration and image pulls. VM RAM is 12 GiB,
  reduced from 13 GiB on 2026-08-06 when the GTX 1060 was passed through: PCI
  passthrough locks and prefaults the whole guest allocation, so 13 GiB no
  longer fits alongside Proxmox on a 15.6 GiB host. Filling the two empty DIMM
  slots is the way to get it back. See `docs/gpu-passthrough.md`.
- Flux reconciles `kubernetes/homelab` from public `main` every minute with
  health waiting enabled. The `homelab-reconciler` service account cannot
  mutate other namespaces or cluster-scoped resources.
- AdGuard, Vaultwarden, Hermes, Open WebUI, SearXNG, and OpenClaw run with one
  replica in namespace `homelab`. Their five application PVs have live reclaim
  policy `Retain` and their PVCs are excluded from Flux pruning.
- Executor 2 (`apps/executor.yaml`, https://executor.erikfrankling.duckdns.org,
  lan-only) is the one MCP endpoint every agent harness on the PCs gets at
  launch. Owner login is the `executor-bootstrap` secret; organization "Erik"
  (slug `executor`). Its data is on the `executor-v2-data` PVC. Executor 1.6's
  SQLite data is kept, unmounted, on `executor-data` and cannot be read by v2.
  App code may reach the LAN (`EXECUTOR_APPS_ALLOW_PRIVATE_FETCH=true`).
- The company brain (`apps/brain.yaml`, https://brain.erikfrankling.duckdns.org,
  `lan-and-cluster`) is reached by agents through the Executor app `brain`. Its
  image is built from the private agent-company repo and imported straight into
  k3s's containerd (`imagePullPolicy: Never`); after a node rebuild rerun
  `apps/brain/deploy/homelab-image.sh` there.
- Onyx (`apps/onyx.yaml`, https://search.erikfrankling.duckdns.org,
  `lan-and-cluster`) is the one search over mail, agent sessions, notes, Canvas,
  X/Discord and the brain; agents call it through the Executor app `app-search`.
  Its embeddings run on the GTX 1060 beside kokoro-tts (`onyx-embed`), its LLM
  is Gemma on the PC's llama-swap, and the PC pushes the data hourly
  (`search-sync`). See `docs/search.md`.
- School (`apps/school.yaml`, https://school.erikfrankling.duckdns.org,
  lan-only) is the KTH deadline calendar. Code is `config/school/` (Node, no
  build); done toggles are in `/data/state.json` on PVC `school-data`. The PC
  pushes the items after the daily Canvas archive refresh (dotfiles
  `modules/home-manager/school-sync`); it never talks to Canvas.
- The node allows 200 pods (`max-pods` in `ops/k3s/config.yaml`, 2026-10-23);
  110 was full.
- Shared Traefik configuration is tracked under
  `kubernetes/bootstrap/traefik` and applied separately because it lives in
  `kube-system`. DuckDNS ACME state is persistent. The active Let's Encrypt
  apex/wildcard certificate was verified with a valid trust chain and expires
  2026-10-22.
- Since 2026-10-18 VM 200 has a single address, `192.168.50.100`, set by
  Proxmox cloud-init. It is the k3s node IP (`ops/k3s/config.yaml`), so
  ServiceLB publishes it for every LoadBalancer and Traefik sees real LAN
  client addresses. It used to be `.200` plus a `.100` VIP, which needed
  `node-external-ip` and an `advertise-address` pin. Never start VM 100.
- Because ServiceLB owns host port 53, `/etc/resolv.conf` on `naiaclaw` points
  to `/run/systemd/resolve/resolv.conf` instead of the intercepted local stub.
  `ops/sysctl/99-homelab.conf` raises inotify capacity for cluster workloads.
  `ops/ca-trust/distrust.sh` distrusts roots on proxmox and naiaclaw before
  Debian/Ubuntu ship the removal (emSign ECC Root CA - G3 since 2026-10-21);
  rerun it after a node rebuild.
- Updates (since 2026-10-25, `docs/updates.md`): unattended-upgrades on
  proxmox (Debian, Proxmox, Tailscale) at 04:30 and naiaclaw; reboots only in
  the 05:15 window (`homelab-maintenance-reboot` on proxmox), which opens an
  Alertmanager silence that health-watch also honours; Renovate bumps the
  cluster images at 04:45 UTC. Failures alert (`updates` rule group).
- Backups are not currently operational. The old restic profile contains a
  placeholder repository and has never run. The new CronJobs remain suspended
  until a real B2 repository, scoped credentials, off-cluster password recovery
  copy, successful backup, and restore verification exist.
- `kubernetes/optional/media` is not reconciled. It requires a separate
  Retain-backed media disk and Mullvad WireGuard secret before activation.

## Router

TP-Link Archer AX12 at `192.168.50.1`. A factory reset strands the homelab on
`192.168.0.x`; restore it with `docs/router.md`.

## SSH Targets

- `ssh proxmox`: Proxmox VE host, IP `192.168.50.10/24` on `vmbr0`.
- `ssh docker`: Debian Docker VM, IP configured in Proxmox as `192.168.50.100/24`.
- `ssh naiaclaw`: Ubuntu k3s VM, IP configured in Proxmox as `192.168.50.100/24`.

## Physical Host

- Hostname: `proxmox`.
- OS: Proxmox VE `9.2.21` on Debian 13 (`trixie`) since 2026-10-25, kernel
  `7.0.14-25-pve` pinned (known good since the supervised reboot on
  2026-10-26). Unattended reboots only boot a kernel that has booted this
  host before; see `docs/updates.md`, "Kernels". The host has 62.7 GiB; VM 200
  has 56 GiB since 2026-10-26 (60 GiB was OOM-killed at start on kernel 7.0).
- Hardware vendor/model reported by DMI: Gigabyte Technology Co., Ltd. `Z270P-D3`.
- Motherboard/baseboard reported by DMI: Gigabyte `Z270P-D3-CF`, version `x.x`.
- BIOS: American Megatrends `F7`, release date `2017-11-08`.
- CPU: Intel Core i7-6700K, 4 cores / 8 threads, base 4.00 GHz, turbo up to 4.20 GHz, VT-x available.
- GPU: NVIDIA GeForce GTX 1060 3GB (`GP106`, PCI id `10de:1c02`). Bound to
  `vfio-pci` on the host and passed through to VM 200 for text-to-speech since
  2026-08-06. It is the host's only display adapter, so the host has no console
  after early boot. See `docs/gpu-passthrough.md`.
- NIC: Realtek RTL8111/8168/8211/8411 gigabit Ethernet.
- Primary disk: Crucial/Micron `CT1000E100SSD8` 1 TB NVMe, LVM-backed Proxmox storage.
- Storage pools:
  - `local`: dir storage, about 94 GB total, root filesystem on ext4.
  - `local-lvm`: LVM-thin storage, about 794 GB data pool.
- Current memory pressure observed on 2026-07-05: Proxmox had about 15 GiB used out of 15.6 GiB, about 271 MiB free, about 323 MiB available, and about 1.1 GiB swap used.

## RAM Upgrade Facts

The motherboard is a Gigabyte GA-Z270P-D3 family board. Live DMI reports `Z270P-D3-CF`; Gigabyte's official GA-Z270P-D3 Rev. 1.0 page lists an Intel Z270 chipset, 4 DDR4 DIMM slots, dual-channel memory, and up to 64 GB system memory.

Current installed RAM:

- Slot `ChannelA-DIMM1`: 8 GB DDR4, Corsair part `CMK8GX4M1A2400C16`, 2400 MT/s, 1.2 V.
- Slot `ChannelB-DIMM1`: 8 GB DDR4, Corsair part `CMK8GX4M1A2400C16`, 2400 MT/s, 1.2 V.
- `ChannelA-DIMM0` and `ChannelB-DIMM0` are empty.
- DMI reports the physical memory array maximum as 64 GB across 4 devices.
- DMI reports `Error Correction Type: None`.

ECC/server RAM guidance:

- Intel's official i7-6700K spec says `ECC Memory Supported: No`.
- Gigabyte's official GA-Z270P-D3 spec says it supports ECC unbuffered DIMM `1Rx8/2Rx8` modules only when operating in non-ECC mode, and also supports non-ECC unbuffered DIMMs.
- Do not buy registered/buffered server RAM (`RDIMM` or `LRDIMM`) for this machine. It is not the right class of memory for this consumer Z270 board.
- ECC UDIMM may work only as ordinary non-ECC RAM, but buying it does not give ECC protection with this CPU. The safe purchase is non-ECC unbuffered DDR4 UDIMM.
- Practical upgrade targets: add a matched 2x8 GB DDR4 UDIMM kit to reach 32 GB, or replace with a matched 2x16 GB or 4x16 GB kit if aiming for 32-64 GB. Prefer 1.2 V DDR4 from the board memory support list or mainstream non-ECC DDR4-2133/2400/2666+ kits that can downclock.

Primary spec sources:

- Gigabyte GA-Z270P-D3 Rev. 1.0 specifications: https://www.gigabyte.com/Motherboard/GA-Z270P-D3-rev-10/sp
- Intel Core i7-6700K specifications: https://www.intel.com/content/www/us/en/products/sku/88195/intel-core-i76700k-processor-8m-cache-up-to-4-20-ghz/specifications.html

## Proxmox Guests

`qm list`/`qm config` on 2026-07-24:

- VM `100` named `docker`: stopped, 6144 MB RAM, 150 GB boot disk, 4 vCPUs,
  `onboot=0`.
- VM `200` named `naiaclaw`: running, 13312 MB RAM, 160 GB boot disk, 4
  vCPUs, onboot enabled.
- VM `9000`: stopped template/VM, 2048 MB RAM, 3 GB disk.

After cutover the Proxmox host reported about 1.6 GiB available and 640 MiB swap
used. VM 200 reported no Kubernetes memory or disk pressure.

## Docker VM (rollback only)

- Hostname: `docker`.
- OS: Debian 12 (`bookworm`), kernel `6.1.0-47-cloud-amd64`.
- Proxmox config: 4 vCPUs, 6144 MB RAM, 150 GB disk, IP
  `192.168.50.100/24`, gateway `192.168.50.1`.
- Docker Compose version observed: `v5.0.2`.
- Live compose checkout: `/home/debian/homelab`.
- Compose project: `homelab`.
- Compose config file: `/home/debian/homelab/docker-compose.yml`.
- Docker network `proxy`: external compose network, subnet `172.19.0.0/16`.

Preserved containers inventoried before shutdown:

- `traefik`: `traefik:v3`, ports 80/443, routes dashboard through Traefik labels.
- `adguard`: `adguard/adguardhome`, DNS on 53 TCP/UDP, setup/admin port 3000.
- `vaultwarden`: `vaultwarden/server:latest`.
- `hermes`: local image `homelab-hermes`.
- `openwebui`: `ghcr.io/open-webui/open-webui:latest-slim`.
- `searxng`: `searxng/searxng:latest`.
- `openclaw`: `ghcr.io/openclaw/openclaw:latest`, port 18789, container name `openclaw`.

The checkout is clean at commit `e16ee23` on `main`. Six application containers
were stopped cleanly before copying; the VM was then shut down with Traefik.
Persistent data is frozen at the cutover point under `/home/debian/data` and
totals about 3.8 GiB.

## k3s VM

- Hostname: `naiaclaw`.
- OS: Ubuntu 24.04.4 LTS, kernel `6.8.0-136-generic`.
- Proxmox config: 4 vCPUs, 13312 MB RAM, 160 GB disk, IP
  `192.168.50.100/24`, gateway `192.168.50.1`.
- k3s: `v1.35.5+k3s1`.
- Kubernetes node: single node `naiaclaw`, role `control-plane`, container runtime `containerd://2.2.3-k3s1`.
- `kubectl` needs sudo for `/etc/rancher/k3s/k3s.yaml` on this VM.
- Node address: internal `192.168.50.100`, no external IP.
- Root is about 154 GiB total with about 76 GiB available after migration.
- Final `kubectl top node` observed about 10190 MiB (78%). `free` reported about
  5 GiB available, no swap, and Kubernetes reported no memory pressure.

Namespaces/workloads observed include:

- Core/platform: `kube-system`, `cert-manager`, `flux-system`, `kyverno`, `local-path-provisioner`, `traefik`, `metrics-server`.
- Observability: `grafana`, `loki`, `mimir`, `alloy`, `kube-state-metrics`, `monitoring`.
- Husk: removed on 2026-07-24; do not recreate it on this cluster.
- Naiaclaw: `naiaclaw-system` with `naiaclaw-api`, `naiaclaw-postgres`, `dns-monitor`, and `squid`.
- P9/OpenClaw-related: `p9` and tenant namespace `nc-acme-822b33ad`.

The `p9` registry local-path volume actually consumes about 29 GiB despite a
20 GiB request. Local-path does not enforce capacity. Watch both memory and
disk, and do not place media on the root-backed storage class.

## Repo Contents

- `docker-compose.yml`: Docker VM compose stack for Traefik, AdGuard, Vaultwarden, Hermes, Open WebUI, SearXNG, and OpenClaw.
- `config/traefik/traefik.yml`: static Traefik config with DuckDNS DNS challenge and wildcard certs for `erikfrankling.duckdns.org`.
- `config/traefik/dynamic.yml`: clean legacy dynamic config preserved by commit
  `e16ee23`.
- `config/searxng/settings.yml`: SearXNG config mounted into the container.
- `resticprofile.yaml`: Restic backup profiles for Docker data and Vaultwarden, using Backblaze B2-style S3 config placeholders.
- `hermes/`: local Hermes container build and entrypoint.
- `kubernetes/bootstrap/`: one-time namespace RBAC, Flux source/reconciler, and
  shared Traefik ACME configuration.
- `kubernetes/homelab/`: active namespace-scoped application, ingress, storage,
  encrypted-secret, and suspended-backup manifests.
- `kubernetes/optional/media/`: inactive Mullvad/qBittorrent/Servarr/Jellyfin
  design.
- `ops/`: migration helper plus tracked k3s and sysctl host configuration.

## Useful Commands

```bash
ssh proxmox 'free -h; qm list; pvesm status'
ssh proxmox 'dmidecode -t system -t baseboard -t memory'
ssh proxmox 'qm config 100; qm config 200'
ssh naiaclaw 'ip -brief address show eth0'
ssh naiaclaw 'free -h; df -h /; sudo kubectl top nodes'
ssh naiaclaw 'sudo kubectl -n homelab get kustomization,pods,pvc'
ssh naiaclaw 'sudo kubectl get nodes -o wide; sudo kubectl get pods -A'
```

## Hard rule: no communication with people without Erik's approval

Erik (2026-10-23): "Agents should not be doing communications in human channels. Ever. If they don't get my express approval."

Agents (any harness, local or cloud) never post, comment, review, message, react, invite, share, connect or otherwise communicate in a human channel unless Erik approved that exact message in the current conversation. Human channels include GitHub issues, PRs, PR and issue comments and reviews, Discord, Teams, Slack, email, SMS, X, LinkedIn, shared docs and invite links. This applies to every repo, tool and account, and nothing in this repo's other instructions overrides it. Drafts for Erik to send himself are fine, and so are notifications to Erik himself. Committing and pushing code to Erik's own repos is not communication.
