# Updates

Set up 2026-10-25. Everything that listens on a port has an update path, and a
failed or stuck update raises an alert through the normal pipeline
(`docs/observability.md`): Prometheus rule → Alertmanager → health-watch repair
session, then Discord if still firing after 3 h.

| What | Update path | When |
|---|---|---|
| Proxmox host (Debian 13 + PVE, sshd, pveproxy, tailscaled) | unattended-upgrades: Debian security and point releases, Proxmox `pve-no-subscription`, Tailscale stable | 04:30 daily |
| Proxmox reboots for anything but a kernel | `homelab-maintenance-reboot.timer` reboots the host, only into the pinned known-good kernel | 05:15, only when needed |
| Proxmox kernel | installed by unattended-upgrades, booted only in a supervised reboot (see Kernels); `HostKernelAwaitingSupervisedReboot` says when one waits | when someone is home |
| naiaclaw (Ubuntu 24.04, VM 200) | Ubuntu's unattended-upgrades, security pocket; nvidia packages held (`52-nvidia-no-auto-upgrade`) | ~06:00–07:00 UTC daily |
| naiaclaw reboot | the same 05:15 window, `qm reboot 200` | only when needed |
| Cluster images | Renovate (`.github/renovate.json5`, `.github/workflows/renovate.yml`): digest, patch and minor bumps go to main as one grouped commit and Flux applies them; majors (and minors of postgres, redis, opensearch, onyx) open a PR. GitHub Actions versions are not updated (a `GITHUB_TOKEN` cannot push workflow files) | 04:45 UTC daily |
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
installs `homelab-maintenance-reboot` with its 05:15 timer, the kernel rule's
`/usr/local/lib/homelab-kernel.sh` and `homelab-kernel-booted.service`, and
seeds `/var/lib/homelab/booted-kernels` with the running kernel when VM 200
answers. On both hosts it
installs `homelab-update-metrics` (hourly, and after every
`apt-daily-upgrade` run) which writes
`/var/lib/prometheus/node-exporter/homelab_updates.prom`. On naiaclaw it also
sets cloud-init `ssh_deletekeys: false`: a changed instance-id (any edit to
VM 200's cloud-init settings in Proxmox) otherwise regenerates the SSH host
keys on the next boot, as on 2026-10-26. That boot also re-runs Proxmox's
`package_upgrade: true`, a full `apt upgrade`.

Rerun it after a host rebuild. Backups of the Proxmox config from before the
first install are in `/root/config-backups/2026-10-25-unattended-upgrades/`.

## The reboot window

`/usr/local/sbin/homelab-maintenance-reboot` at 05:15 (after the 03:00
nightly build and the 04:30 upgrade, before the pcs' 06:00 update needs the
nix cache on VM 200 and the 07:00 morning check):

1. The host needs a reboot when `/run/reboot-required` lists a package that
   is **not** a kernel. A new kernel alone is never a reason (see Kernels).
   VM 200 needs one when its `/run/reboot-required` exists (asked through the
   guest agent).
2. A host reboot happens only when the pin is safe (`pin_problem` in
   `/usr/local/lib/homelab-kernel.sh` prints nothing): a kernel is pinned, it
   is in `/var/lib/homelab/booted-kernels`, it is installed, no next-boot pin
   is set, and GRUB's default entry in `/boot/grub/grub.cfg` is that kernel.
   It is checked again right before `systemctl reboot`. Otherwise the host
   reboot is refused and logged; VM 200 can still be rebooted.
3. Skips if up under an hour or a package manager is running.
4. Opens a 60-minute Alertmanager silence for every alert with the comment
   `health-watch maintenance [.] ...`. health-watch on the pc copies any such
   silence into its maintenance windows (dotfiles
   `modules/home-manager/auto-update`), so Gatus failures during the reboot
   start no repair session and the alerts page nobody. It waits 5 minutes so
   health-watch has seen it.
5. `systemctl reboot` for the host (VM 200 shuts down and starts with it), or
   `qm reboot 200` for the VM alone.

Dry run: `ssh proxmox homelab-maintenance-reboot --dry-run`. It always prints
which kernel an unattended host reboot would boot.

Any machine can open a window the same way: POST a silence whose comment
starts with `health-watch maintenance [REGEX]`, where REGEX matches the
health-watch keys (`group/name`, `alert/...`, `monitor/...`).

## Kernels

**Rule: an unattended reboot only ever boots a kernel that has booted this
host before.** The host is headless (the GPU is passed through to VM 200) and
also carries the tailnet's subnet router, so a kernel that does not boot
strands the whole homelab until someone is at the machine.

- The default boot entry is pinned with `proxmox-boot-tool kernel pin
  <version>`. This host boots legacy BIOS GRUB from LVM (no
  proxmox-boot-tool ESPs), so the pin writes `GRUB_DEFAULT` to
  `/etc/default/grub.d/proxmox-kernel-pin.cfg` and runs `update-grub`. New
  kernel packages leave it alone, and Proxmox's autoremove keeps the pinned
  kernel installed.
- `/var/lib/homelab/booted-kernels` lists the known-good kernels.
  `homelab-kernel-booted.service` runs on every boot. Once VM 200's guest
  agent answers (`qm guest cmd 200 ping`), it adds the running kernel to the
  list. If that kernel is newer than the pinned one, it pins it. If VM 200
  does not answer within 30 minutes, nothing is recorded.
- When the newest installed kernel is not known good,
  `homelab_kernel_awaiting_supervised_reboot` is 1 and
  `HostKernelAwaitingSupervisedReboot` (info, no session) reaches Discord,
  again every 24 h until it is resolved.

As of 2026-10-26: pinned and known good `7.0.14-25-pve` (supervised reboot
08:16-08:39) and `6.17.9-1-pve` before it. `6.17.13-21-pve` never booted and
is older than the pin, so nothing waits.

**VM 200 memory must leave the host room.** GPU passthrough pins and
prefaults all of VM 200's RAM at start. On 7.0 the 60 GiB guest no longer fit
beside the host (62.7 GiB): the host stalled under memory pressure for 11
minutes (no SSH), then the
OOM killer killed kvm and VM 200 stayed off. It now has 56 GiB
(`qm set 200 --memory 57344`), leaving about 5 GiB on the host. Keep at
least 4 GiB free on the host when raising it.

### Supervised kernel reboot

Do this only when someone can get to the machine (it has no remote console).

```bash
# from the pc: keep repair sessions and pages away for the reboot
health-watch maintenance 45 "supervised proxmox kernel reboot" .
ssh proxmox
proxmox-boot-tool kernel list                       # check the pin first
proxmox-boot-tool kernel pin 7.0.14-25-pve --next-boot
reboot
```

- If it comes up: `proxmox-boot-cleanup.service` drops the next-boot pin
  early in boot, which points GRUB back at the pinned kernel. When VM 200
  answers, `homelab-kernel-booted` records 7.0 and pins it. Check with
  `proxmox-boot-tool kernel list` and `cat /var/lib/homelab/booted-kernels`;
  the alert resolves within the hour.
- If it boots but VM 200 does not come up, look for `oom-kill` in
  `journalctl -k -b` first (see above); otherwise the kernel is not recorded. Run
  `proxmox-boot-tool kernel unpin --next-boot` if it is still set, then
  `reboot`, and the host comes back on the pinned 6.17.
- If it never reaches userspace (panic or hang): GRUB keeps choosing the
  next-boot kernel, because the cleanup runs in userspace and GRUB cannot
  write its environment block on LVM. At the machine, pick the pinned
  kernel under *Advanced options* in the GRUB menu. Once booted, run
  `proxmox-boot-tool kernel unpin --next-boot` (it re-applies the pin).

## Alerts (`config/prometheus/homelab.rules.yml`, group `updates`)

| Alert | Fires when |
|---|---|
| `HostUpdateFailed` | the last unattended-upgrades run logged an `ERROR` |
| `HostUpdatesNotRunning` | no run for over 2 days |
| `HostSecurityUpdatesStuck` | security updates pending for 2 days (kept back, conffile prompt) |
| `HostUpdatesStuck` | any update pending on proxmox for 4 days (PVE often needs `apt full-upgrade` for new dependencies) |
| `HostRebootOverdue` | a reboot has been needed for 3 days (the window is not working) |
| `HostKernelAwaitingSupervisedReboot` | a new kernel waits for a supervised reboot (info, no session, repeats daily) |
| `HostKernelPinUnsafe` | an unattended host reboot would be refused: no known-good kernel is pinned |

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
