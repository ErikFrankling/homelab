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
[ -f /run/reboot-required ] && reboot=1
# A kernel installed before unattended-upgrades' postinst hook existed, or
# by a package that does not run it, leaves no reboot-required file.
newest=$(ls /boot/vmlinuz-* 2> /dev/null | sed 's|^/boot/vmlinuz-||' | sort -V | tail -n 1)
[ -n "$newest" ] && [ "$newest" != "$(uname -r)" ] && reboot=1

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
# HELP homelab_reboot_required 1 while /run/reboot-required exists.
# TYPE homelab_reboot_required gauge
homelab_reboot_required $reboot
# HELP homelab_unattended_upgrades_last_run_timestamp_seconds Start of the last unattended-upgrades run.
# TYPE homelab_unattended_upgrades_last_run_timestamp_seconds gauge
homelab_unattended_upgrades_last_run_timestamp_seconds $ts
# HELP homelab_unattended_upgrades_last_run_success 0 when the last run logged an ERROR.
# TYPE homelab_unattended_upgrades_last_run_success gauge
homelab_unattended_upgrades_last_run_success $ok
METRICS
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
ARGS="--web.listen-address=192.168.50.10:9100 --collector.textfile.directory=/var/lib/prometheus/node-exporter --collector.systemd --collector.systemd.unit-include=(apt-daily|apt-daily-upgrade|homelab-maintenance-reboot|tailscaled|pveproxy|pvedaemon|pve-cluster)\.service"
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

  cat > /usr/local/sbin/homelab-maintenance-reboot <<'EOF'
#!/bin/sh
# The 05:15 reboot window (homelab ops/updates, docs/updates.md). Reboots the
# Proxmox host when an upgrade asked for it, which restarts VM 200 too;
# otherwise reboots only VM 200 when its Ubuntu asked for it. Before either,
# a 60-minute Alertmanager silence that health-watch on the pc also reads as
# a maintenance window, so the restart pages nobody and starts no session.
set -eu
dry=0
[ "${1:-}" = --dry-run ] && dry=1
say() { echo "homelab-maintenance-reboot: $*"; }

host=0
[ -f /run/reboot-required ] && host=1
newest=$(ls /boot/vmlinuz-* 2> /dev/null | sed 's|^/boot/vmlinuz-||' | sort -V | tail -n 1)
[ -n "$newest" ] && [ "$newest" != "$(uname -r)" ] && host=1
vm=0
if qm guest exec 200 --timeout 30 -- test -f /run/reboot-required 2> /dev/null | grep -q '"exitcode" *: *0'; then
  vm=1
fi
if [ "$host" = 0 ] && [ "$vm" = 0 ]; then
  say "nothing needs a reboot"
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
  what="proxmox host (kernel $(uname -r) -> $newest; $(cat /run/reboot-required.pkgs 2> /dev/null | sort -u | paste -sd' ' -)); VM 200 restarts with it"
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
