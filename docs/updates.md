# Updates

Set up 2026-10-25. Everything that listens on a port has an update path, and a
failed or stuck update raises an alert through the normal pipeline
(`docs/observability.md`): Prometheus rule → Alertmanager → health-watch repair
session, then Discord if still firing after 3 h.

| What | Update path | When |
|---|---|---|
| Proxmox host (Debian 13 + PVE, sshd, pveproxy, tailscaled) | unattended-upgrades: Debian security and point releases, Proxmox `pve-no-subscription`, Tailscale stable | 04:30 daily |
| Proxmox kernel, libc, anything that asks for a reboot | `homelab-maintenance-reboot.timer` reboots the host | 05:15, only when needed |
| naiaclaw (Ubuntu 24.04, VM 200) | Ubuntu's unattended-upgrades, security pocket; nvidia packages held (`52-nvidia-no-auto-upgrade`) | ~06:00–07:00 UTC daily |
| naiaclaw reboot | the same 05:15 window, `qm reboot 200` | only when needed |
| Cluster images | Renovate (`.github/renovate.json5`, `.github/workflows/renovate.yml`): digest/patch bumps merge to main, Flux applies; minor/major open a PR | 04:45 UTC daily |
| Tailscale on Proxmox | apt (above) plus Tailscale's own auto-update (`AutoUpdate.Apply`) | daily |
| Tailscale on the framework | dotfiles `nixpkgs_unstable` input, moved by the nightly flake update; never held back with nixpkgs | nightly |
| Tailscale in the Gatus probe | Renovate (image `ghcr.io/tailscale/tailscale`) | daily |
| pc, framework | dotfiles nightly update | nightly |

Not on an automatic path, on purpose:

- **k3s** itself (`v1.35.5+k3s1`, installed by the k3s script). Upgrading it
  restarts the only control plane and every pod; do it by hand (or add a
  system-upgrade-controller Plan) once the reboot window has a track record.
- **Router** (TP-Link AX12) firmware: no port forwards and no UPnP (verified
  2026-10-25 with `upnpc -l`: no IGD), so nothing on it faces the internet.
  Check for firmware in its UI now and then; the admin password is Erik's.
- **Docker VM** (VM 100): powered off rollback artifact, never started.
- Images built from Erik's own repos (`ghcr.io/erikfrankling/*`, `brain`):
  their own deploy scripts update them.

## Installing or repairing

All host-side files come from one idempotent script:

```bash
ssh proxmox 'sh -s proxmox' < ops/updates/install.sh
ssh naiaclaw 'sudo sh -s naiaclaw' < ops/updates/install.sh
```

On Proxmox it installs `unattended-upgrades`, `apt-listchanges` and
`prometheus-node-exporter`, writes `/etc/apt/apt.conf.d/20auto-upgrades` and
`52homelab-unattended-upgrades`, moves `apt-daily-upgrade.timer` to 04:30, and
installs `homelab-maintenance-reboot` with its 05:15 timer. On both hosts it
installs `homelab-update-metrics` (hourly, and after every
`apt-daily-upgrade` run) which writes
`/var/lib/prometheus/node-exporter/homelab_updates.prom`.

Rerun it after a host rebuild. Backups of the Proxmox config from before the
first install are in `/root/config-backups/2026-10-25-unattended-upgrades/`.

## The reboot window

`/usr/local/sbin/homelab-maintenance-reboot` at 05:15 (after the 03:00
nightly build and the 04:30 upgrade, before the pcs' 06:00 update needs the
nix cache on VM 200 and the 07:00 morning check):

1. Host needs a reboot when `/run/reboot-required` exists or the newest
   `/boot/vmlinuz-*` is not the running kernel. VM 200 needs one when its
   `/run/reboot-required` exists (asked through the guest agent).
2. Skips if up under an hour or a package manager is running.
3. Opens a 60-minute Alertmanager silence for every alert with the comment
   `health-watch maintenance [.] ...`. health-watch on the pc copies any such
   silence into its maintenance windows (dotfiles
   `modules/home-manager/auto-update`), so Gatus failures during the reboot
   start no repair session and the alerts page nobody. It waits 5 minutes so
   health-watch has seen it.
4. `systemctl reboot` for the host (VM 200 shuts down and starts with it), or
   `qm reboot 200` for the VM alone.

Dry run: `ssh proxmox homelab-maintenance-reboot --dry-run`.

Any machine can open a window the same way: POST a silence whose comment
starts with `health-watch maintenance [REGEX]`, where REGEX matches the
health-watch keys (`group/name`, `alert/...`, `monitor/...`).

**Risk:** the host is headless (the GPU is passed through) and boots with GRUB
from LVM, so there is no one-shot `grub-reboot` fallback: GRUB cannot write
its environment block on LVM. A kernel that does not boot needs someone at the
machine to pick the previous kernel under *Advanced options* in GRUB.

## Alerts (`config/prometheus/homelab.rules.yml`, group `updates`)

| Alert | Fires when |
|---|---|
| `HostUpdateFailed` | the last unattended-upgrades run logged an `ERROR` |
| `HostUpdatesNotRunning` | no run for over 2 days |
| `HostSecurityUpdatesStuck` | security updates pending for 2 days (kept back, conffile prompt) |
| `HostUpdatesStuck` | any update pending on proxmox for 4 days (PVE often needs `apt full-upgrade` for new dependencies) |
| `HostRebootOverdue` | a reboot has been needed for 3 days (the window is not working) |

Prometheus scrapes the Proxmox host at `192.168.50.10:9100` (job `proxmox`)
and naiaclaw's textfile through the node-exporter DaemonSet. A dead exporter
raises the existing `ScrapeTargetDown`.

## Checking by hand

```bash
ssh proxmox 'systemctl status unattended-upgrades apt-daily-upgrade.timer homelab-maintenance-reboot.timer'
ssh proxmox 'apt-config dump | grep -E "Unattended-Upgrade::(Origins-Pattern|Automatic-Reboot)|APT::Periodic"'
ssh proxmox 'unattended-upgrade --dry-run --debug 2>&1 | tail'
ssh proxmox 'cat /var/lib/prometheus/node-exporter/homelab_updates.prom'
ssh proxmox 'journalctl -u homelab-maintenance-reboot'
```
