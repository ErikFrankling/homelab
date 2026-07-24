# Homelab Notes for Agents

Last verified: 2026-07-24 from the local repo, GitHub, `ssh proxmox`,
`ssh docker`, and `ssh naiaclaw`.

## Working Rules

- This public repo and GitHub `main` are the active homelab source. Check Flux
  and the live k3s host before assuming a local checkout is current.
- The Docker VM is a powered-off rollback artifact. Never start it while
  `homelab-vip.service` is active on VM 200.
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
  intact. VM 200 owns the active `192.168.50.100` VIP.
- The obsolete `husk` Helm release and namespace were removed on 2026-07-24.
  A verified logical PostgreSQL dump is retained privately under
  `/home/ubuntu/retired-husk` on `naiaclaw`.
- VM 200's disk was expanded online from 80 GiB to 160 GiB. The root filesystem
  had about 76 GiB free after migration and image pulls. VM RAM is 13 GiB.
- Flux reconciles `kubernetes/homelab` from public `main` every minute with
  health waiting enabled. The `homelab-reconciler` service account cannot
  mutate other namespaces or cluster-scoped resources.
- AdGuard, Vaultwarden, Hermes, Open WebUI, SearXNG, and OpenClaw run with one
  replica in namespace `homelab`. Their five application PVs have live reclaim
  policy `Retain` and their PVCs are excluded from Flux pruning.
- Shared Traefik configuration is tracked under
  `kubernetes/bootstrap/traefik` and applied separately because it lives in
  `kube-system`. DuckDNS ACME state is persistent. The active Let's Encrypt
  apex/wildcard certificate was verified with a valid trust chain and expires
  2026-10-22.
- `ops/systemd/homelab-vip.service` installs `.100` before k3s starts;
  `ops/k3s/config.yaml` advertises it as the node external IP so ServiceLB
  preserves LAN source addresses. Never start VM 100 while the VIP is active.
- Because ServiceLB owns host port 53, `/etc/resolv.conf` on `naiaclaw` points
  to `/run/systemd/resolve/resolv.conf` instead of the intercepted local stub.
  `ops/sysctl/99-homelab.conf` raises inotify capacity for cluster workloads.
- Backups are not currently operational. The old restic profile contains a
  placeholder repository and has never run. The new CronJobs remain suspended
  until a real B2 repository, scoped credentials, off-cluster password recovery
  copy, successful backup, and restore verification exist.
- `kubernetes/optional/media` is not reconciled. It requires a separate
  Retain-backed media disk and Mullvad WireGuard secret before activation.

## SSH Targets

- `ssh proxmox`: Proxmox VE host, IP `192.168.50.169/24` on `vmbr0`.
- `ssh docker`: Debian Docker VM, IP configured in Proxmox as `192.168.50.100/24`.
- `ssh naiaclaw`: Ubuntu k3s VM, IP configured in Proxmox as `192.168.50.200/24`.

## Physical Host

- Hostname: `proxmox`.
- OS: Proxmox VE `9.1.5` on Debian 13 (`trixie`), kernel `6.17.9-1-pve`.
- Hardware vendor/model reported by DMI: Gigabyte Technology Co., Ltd. `Z270P-D3`.
- Motherboard/baseboard reported by DMI: Gigabyte `Z270P-D3-CF`, version `x.x`.
- BIOS: American Megatrends `F7`, release date `2017-11-08`.
- CPU: Intel Core i7-6700K, 4 cores / 8 threads, base 4.00 GHz, turbo up to 4.20 GHz, VT-x available.
- GPU: NVIDIA GeForce GTX 1060 3GB (`GP106`, PCI id `10de:1c02`).
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
  `192.168.50.200/24`, gateway `192.168.50.1`.
- k3s: `v1.35.5+k3s1`.
- Kubernetes node: single node `naiaclaw`, role `control-plane`, container runtime `containerd://2.2.3-k3s1`.
- `kubectl` needs sudo for `/etc/rancher/k3s/k3s.yaml` on this VM.
- Node addresses are internal `192.168.50.200` and external/VIP
  `192.168.50.100`.
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
- `ops/`: migration helper plus tracked VIP, k3s, and sysctl host configuration.

## Useful Commands

```bash
ssh proxmox 'free -h; qm list; pvesm status'
ssh proxmox 'dmidecode -t system -t baseboard -t memory'
ssh proxmox 'qm config 100; qm config 200'
ssh naiaclaw 'systemctl status homelab-vip; ip -brief address show eth0'
ssh naiaclaw 'free -h; df -h /; sudo kubectl top nodes'
ssh naiaclaw 'sudo kubectl -n homelab get kustomization,pods,pvc'
ssh naiaclaw 'sudo kubectl get nodes -o wide; sudo kubectl get pods -A'
```
