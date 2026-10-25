#!/bin/sh
# Unattended updates for the Debian/Ubuntu hosts, with metrics for the alerts
# and one nightly reboot window. Idempotent; run as root (docs/updates.md):
#   ssh proxmox 'sh -s proxmox' < ops/updates/install.sh
#   ssh naiaclaw 'sudo sh -s naiaclaw' < ops/updates/install.sh
#
# proxmox:  unattended-upgrades for Debian (security and point releases),
#           Proxmox (pve-no-subscription) and Tailscale at 04:30; a
#           node-exporter on 192.168.50.10:9100 that Prometheus scrapes; the
#           05:15 reboot window for the host and VM 200.
# naiaclaw: keeps Ubuntu's own unattended-upgrades (security pocket, nvidia
#           blacklisted by 52-nvidia-no-auto-upgrade) and adds the metrics,
#           read by the node-exporter DaemonSet (apps/node-exporter.yaml).
set -eu
role=${1:?usage: install.sh proxmox|naiaclaw}
textfile=/var/lib/prometheus/node-exporter
export DEBIAN_FRONTEND=noninteractive

# --- metrics: homelab_apt_upgrades_pending, homelab_reboot_required,
# homelab_unattended_upgrades_last_run_{timestamp_seconds,success} -----------
cat > /usr/local/sbin/homelab-update-metrics <<'EOF'
#!/bin/sh
# Writes this host's update state for node-exporter's textfile collector.
# Run hourly and after every apt-daily-upgrade (homelab ops/updates).
set -eu
dir=/var/lib/prometheus/node-exporter
mkdir -p "$dir"
tmp=$(mktemp "$dir/.homelab_updates.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# Packages unattended-upgrades is told to leave alone are not "pending".
skip=$(apt-config dump Unattended-Upgrade::Package-Blacklist \
  | sed -n 's/^Unattended-Upgrade::Package-Blacklist:: "\(.*\)";$/\1/p' | paste -sd'|' -)
pending=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2> /dev/null | grep '^Inst ' \
  | { if [ -n "$skip" ]; then grep -Ev "^Inst ($skip)"; else cat; fi; } || true)
all=$(printf '%s' "$pending" | grep -c '^Inst ' || true)
sec=$(printf '%s' "$pending" | grep -ci 'security' || true)

reboot=0
kernel_metrics=
if [ -f /usr/local/lib/homelab-kernel.sh ]; then
  # Proxmox: a new kernel is not a reason for an unattended reboot (it waits
  # for a supervised one); other packages that asked for a reboot are.
  . /usr/local/lib/homelab-kernel.sh
  if [ -n "$(reboot_reasons)" ]; then reboot=1; fi
  newest=$(newest_kernel)
  waiting=0
  if [ -n "$newest" ] && ! known_good "$newest"; then waiting=1; fi
  safe=1
  if [ -n "$(pin_problem)" ]; then safe=0; fi
  kernel_metrics="# HELP homelab_kernel_awaiting_supervised_reboot 1 while the newest installed kernel has never booted this host.
# TYPE homelab_kernel_awaiting_supervised_reboot gauge
homelab_kernel_awaiting_supervised_reboot{kernel=\"$newest\",pinned=\"$(pinned_kernel)\"} $waiting
# HELP homelab_kernel_pin_safe 1 when an unattended reboot would boot a known-good pinned kernel.
# TYPE homelab_kernel_pin_safe gauge
homelab_kernel_pin_safe $safe"
elif [ -f /run/reboot-required ]; then
  reboot=1
fi

# The last unattended-upgrades run: its start time, and whether it logged an
# ERROR (a package that failed to install). Logrotate may have just moved it.
ts=0
ok=0
for log in /var/log/unattended-upgrades/unattended-upgrades.log /var/log/unattended-upgrades/unattended-upgrades.log.1; do
  [ -f "$log" ] || continue
  line=$(grep -n 'Starting unattended upgrades script' "$log" | tail -n 1 | cut -d: -f1)
  [ -n "$line" ] || continue
  started=$(sed -n "${line}p" "$log" | cut -c1-19)
  ts=$(date -d "$started" +%s)
  if tail -n "+$line" "$log" | grep -q ' ERROR '; then ok=0; else ok=1; fi
  break
done

cat > "$tmp" <<METRICS
# HELP homelab_apt_upgrades_pending Packages apt would upgrade now (blacklisted ones excluded).
# TYPE homelab_apt_upgrades_pending gauge
homelab_apt_upgrades_pending{kind="all"} $all
homelab_apt_upgrades_pending{kind="security"} $sec
# HELP homelab_reboot_required 1 while an update waits for an unattended reboot.
# TYPE homelab_reboot_required gauge
homelab_reboot_required $reboot
# HELP homelab_unattended_upgrades_last_run_timestamp_seconds Start of the last unattended-upgrades run.
# TYPE homelab_unattended_upgrades_last_run_timestamp_seconds gauge
homelab_unattended_upgrades_last_run_timestamp_seconds $ts
# HELP homelab_unattended_upgrades_last_run_success 0 when the last run logged an ERROR.
# TYPE homelab_unattended_upgrades_last_run_success gauge
homelab_unattended_upgrades_last_run_success $ok
METRICS
if [ -n "$kernel_metrics" ]; then echo "$kernel_metrics" >> "$tmp"; fi
chmod 0644 "$tmp"
mv "$tmp" "$dir/homelab_updates.prom"
trap - EXIT
EOF
chmod 0755 /usr/local/sbin/homelab-update-metrics

cat > /etc/systemd/system/homelab-update-metrics.service <<'EOF'
[Unit]
Description=Write update metrics for node-exporter (homelab ops/updates)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-update-metrics
EOF
cat > /etc/systemd/system/homelab-update-metrics.timer <<'EOF'
[Unit]
Description=Refresh update metrics hourly

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF
mkdir -p /etc/systemd/system/apt-daily-upgrade.service.d
cat > /etc/systemd/system/apt-daily-upgrade.service.d/homelab-metrics.conf <<'EOF'
# Fresh metrics right after each unattended-upgrades run, failed or not.
[Service]
ExecStopPost=-/usr/local/sbin/homelab-update-metrics
EOF

if [ "$role" = proxmox ]; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends unattended-upgrades apt-listchanges prometheus-node-exporter > /dev/null

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  # Appends to the origins in Debian's 50unattended-upgrades (security only).
  cat > /etc/apt/apt.conf.d/52homelab-unattended-upgrades <<'EOF'
// homelab ops/updates/install.sh. Proxmox's packages need Debian's point
// releases, so take those too, and keep tailscaled (UDP 41641) current.
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${distro_codename},label=Debian";
  "origin=Debian,codename=${distro_codename}-updates,label=Debian";
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
  "origin=Proxmox,codename=${distro_codename}";
  "origin=Tailscale,codename=${distro_codename}";
};
// Reboots happen in the 05:15 window (homelab-maintenance-reboot.timer).
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::SyslogEnable "true";
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
};
EOF
  # 04:30: after the 03:00 nightly build, before the 05:15 window.
  mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d /etc/systemd/system/apt-daily.timer.d
  cat > /etc/systemd/system/apt-daily-upgrade.timer.d/homelab.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:30
RandomizedDelaySec=0
EOF
  cat > /etc/systemd/system/apt-daily.timer.d/homelab.conf <<'EOF'
# Fresh package lists shortly before the 04:30 upgrade.
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00,16:00
RandomizedDelaySec=10min
EOF

  # LAN address only; the systemd collector shows failed apt/update units.
  cat > /etc/default/prometheus-node-exporter <<'EOF'
# homelab ops/updates/install.sh; Prometheus job "proxmox".
ARGS="--web.listen-address=192.168.50.10:9100 --collector.textfile.directory=/var/lib/prometheus/node-exporter --collector.systemd --collector.systemd.unit-include=(apt-daily|apt-daily-upgrade|homelab-maintenance-reboot|homelab-kernel-booted|tailscaled|pveproxy|pvedaemon|pve-cluster)\.service"
EOF
  mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
  cat > /etc/systemd/system/prometheus-node-exporter.service.d/homelab.conf <<'EOF'
# Binds 192.168.50.10, which exists only once vmbr0 is up.
[Unit]
Wants=network-online.target
After=network-online.target
[Service]
Restart=always
RestartSec=10
EOF

  # Kernel rule (docs/updates.md, "Kernels"): an unattended reboot only ever
  # boots a kernel that has booted this host before, the one pinned with
  # proxmox-boot-tool. A new kernel waits for a supervised reboot.
  mkdir -p /usr/local/lib /var/lib/homelab
  cat > /usr/local/lib/homelab-kernel.sh <<'EOF'
# Sourced by homelab-update-metrics, -maintenance-reboot and -kernel-booted
# (homelab ops/updates). Kernels that have booted this host and brought VM 200
# up, one per line, written by homelab-kernel-booted:
booted=/var/lib/homelab/booted-kernels

pinned_kernel() { head -n 1 /etc/kernel/proxmox-boot-pin 2> /dev/null || true; }
known_good() { [ -n "$1" ] && grep -qxF "$1" "$booted" 2> /dev/null; }
newest_kernel() {
  ls /boot/vmlinuz-*-pve 2> /dev/null | sed 's|^/boot/vmlinuz-||' | sort -V | tail -n 1
}
# Prints why an unattended reboot would not be safe; nothing when it is.
pin_problem() {
  p=$(pinned_kernel)
  if [ -z "$p" ]; then echo "no kernel is pinned"; return; fi
  if ! known_good "$p"; then echo "pinned kernel $p has never booted this host"; return; fi
  if [ ! -e "/boot/vmlinuz-$p" ]; then echo "pinned kernel $p is not installed"; return; fi
  if [ -e /etc/kernel/next-boot-pin ]; then
    echo "a supervised reboot is prepared (next-boot pin $(head -n 1 /etc/kernel/next-boot-pin))"
    return
  fi
  if ! grep -q "^[[:space:]]*set default=\".*gnulinux-$p-advanced" /boot/grub/grub.cfg; then
    echo "GRUB's default entry is not the pinned kernel $p"
  fi
}
# Packages other than kernels that asked for a reboot (kernels never count).
reboot_reasons() {
  [ -f /run/reboot-required ] || return 0
  if [ -f /run/reboot-required.pkgs ]; then
    grep -Ev '^(proxmox-kernel|pve-kernel|linux-image)-' /run/reboot-required.pkgs | sort -u | paste -sd' ' -
  else
    echo "unknown package"
  fi
}
EOF
  # Seed: the kernel running now has booted this host and runs VM 200.
  if [ ! -s /var/lib/homelab/booted-kernels ] && timeout 15 qm guest cmd 200 ping > /dev/null 2>&1; then
    uname -r > /var/lib/homelab/booted-kernels
  fi

  cat > /usr/local/sbin/homelab-kernel-booted <<'EOF'
#!/bin/sh
# Once per boot (homelab ops/updates): when VM 200's guest agent answers, the
# GPU-passthrough VM runs on this kernel, so the kernel has booted this host
# successfully. Record it, and pin it when it is newer than the pinned one,
# so unattended reboots use it from now on.
set -eu
. /usr/local/lib/homelab-kernel.sh
k=$(uname -r)
i=0
while ! timeout 15 qm guest cmd 200 ping > /dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "VM 200 did not answer for 30 minutes on kernel $k: not recording it as known good" >&2
    exit 1
  fi
  sleep 20
done
known_good "$k" || echo "$k" >> "$booted"
p=$(pinned_kernel)
if [ "$k" != "$p" ] && [ "$(printf '%s\n%s\n' "$p" "$k" | sort -V | tail -n 1)" = "$k" ]; then
  proxmox-boot-tool kernel pin "$k" > /dev/null
  echo "pinned $k (was ${p:-none})"
fi
echo "kernel $k booted and VM 200 is up: known good"
/usr/local/sbin/homelab-update-metrics || true
EOF
  chmod 0755 /usr/local/sbin/homelab-kernel-booted
  cat > /etc/systemd/system/homelab-kernel-booted.service <<'EOF'
[Unit]
Description=Record the running kernel as known good once VM 200 is up (homelab ops/updates)
After=pve-guests.service proxmox-boot-cleanup.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=40min
ExecStart=/usr/local/sbin/homelab-kernel-booted

[Install]
WantedBy=multi-user.target
EOF

  cat > /usr/local/sbin/homelab-maintenance-reboot <<'EOF'
#!/bin/sh
# The 05:15 reboot window (homelab ops/updates, docs/updates.md). Reboots the
# Proxmox host when a package other than a kernel asked for it, and only into
# the pinned kernel that has booted this host before; a new kernel waits for a
# supervised reboot. Otherwise reboots only VM 200 when its Ubuntu asked for
# it. Before either, a 60-minute Alertmanager silence that health-watch on
# the pc also reads as a maintenance window, so the restart pages nobody and
# starts no session.
set -eu
. /usr/local/lib/homelab-kernel.sh
dry=0
[ "${1:-}" = --dry-run ] && dry=1
say() { echo "homelab-maintenance-reboot: $*"; }

pinned=$(pinned_kernel)
newest=$(newest_kernel)
problem=$(pin_problem)
if [ -z "$problem" ]; then
  say "kernel: an unattended host reboot boots the pinned known-good kernel $pinned (running $(uname -r))"
else
  say "kernel: no unattended host reboot: $problem"
fi
if [ -n "$newest" ] && ! known_good "$newest"; then
  say "kernel: $newest has never booted this host; it waits for a supervised reboot (docs/updates.md)"
fi

host=0
reasons=$(reboot_reasons)
if [ -n "$reasons" ]; then
  if [ -z "$problem" ]; then
    host=1
  else
    say "host reboot for $reasons refused: $problem"
  fi
fi
vm=0
if qm guest exec 200 --timeout 30 -- test -f /run/reboot-required 2> /dev/null | grep -q '"exitcode" *: *0'; then
  vm=1
fi
if [ "$host" = 0 ] && [ "$vm" = 0 ]; then
  say "nothing to reboot"
  exit 0
fi
if [ "$(cut -d. -f1 /proc/uptime)" -lt 3600 ]; then
  say "up less than an hour; leaving it for tomorrow"
  exit 0
fi
if pgrep -x 'apt|apt-get|dpkg' > /dev/null || pgrep -f '/unattended-upgrade( |$)' > /dev/null; then
  say "a package manager is running; leaving it for tomorrow"
  exit 0
fi
if [ "$host" = 1 ]; then
  what="proxmox host into pinned kernel $pinned ($reasons); VM 200 restarts with it"
else
  what="VM 200 naiaclaw (Ubuntu asked for it)"
fi
if [ "$dry" = 1 ]; then
  say "would open a 60-minute window and reboot: $what"
  exit 0
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
end=$(date -u -d '+60 min' +%Y-%m-%dT%H:%M:%SZ)
if curl -fsS --max-time 20 -X POST -H 'Content-Type: application/json' \
  https://alertmanager.erikfrankling.duckdns.org/api/v2/silences \
  -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\".+\",\"isRegex\":true,\"isEqual\":true}],\"startsAt\":\"$now\",\"endsAt\":\"$end\",\"createdBy\":\"proxmox homelab-maintenance-reboot\",\"comment\":\"health-watch maintenance [.] nightly update reboot: $what\"}"; then
  echo
  # health-watch polls every 2 minutes; give it time to copy the window.
  sleep 300
else
  say "could not open the Alertmanager window; rebooting anyway"
fi

say "rebooting $what"
if [ "$host" = 1 ]; then
  # Checked again right before: nothing may have changed the boot entry.
  problem=$(pin_problem)
  if [ -n "$problem" ]; then
    say "host reboot refused at the last moment: $problem"
    exit 1
  fi
  systemctl reboot
else
  qm reboot 200 --timeout 600
fi
EOF
  chmod 0755 /usr/local/sbin/homelab-maintenance-reboot
  cat > /etc/systemd/system/homelab-maintenance-reboot.service <<'EOF'
[Unit]
Description=Nightly reboot window for the host and VM 200 (homelab ops/updates)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-maintenance-reboot
EOF
  # 05:15: after the 04:30 upgrade, before the pcs' 06:00 update needs the
  # nix cache on VM 200 and before the 07:00 morning check.
  cat > /etc/systemd/system/homelab-maintenance-reboot.timer <<'EOF'
[Unit]
Description=Nightly reboot window, 05:15

[Timer]
OnCalendar=*-*-* 05:15
Persistent=false

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now homelab-maintenance-reboot.timer > /dev/null
  systemctl enable homelab-kernel-booted.service > /dev/null 2>&1
  systemctl enable prometheus-node-exporter > /dev/null
  systemctl restart prometheus-node-exporter
fi

if [ "$role" = naiaclaw ]; then
  systemctl daemon-reload
fi

systemctl enable --now homelab-update-metrics.timer > /dev/null
systemctl start homelab-update-metrics.service
systemctl restart apt-daily-upgrade.timer apt-daily.timer
cat "$textfile/homelab_updates.prom" | grep -v '^#'
