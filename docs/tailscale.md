# Tailscale remote access (replaces router OpenVPN)

Set up 2026-08-12. The old router's OpenVPN server (`10.8.0.0/24`) is gone;
remote access now runs over Tailscale with the **Proxmox host** acting as a
subnet router that advertises the whole LAN (`192.168.50.0/24`) to the tailnet.

Why the Proxmox host and not the cluster or a VM: it is the lowest layer that
is always on, and it is headless (the GPU is passed through to VM 200, so there
is no console). If VM 200 or k3s breaks while away, Tailscale on the hypervisor
still gets you in to fix it. Tailscale SSH (`--ssh`) is enabled as break-glass
access to the host itself.

This host-level setup is deliberately **not** declarative — it is a one-time
bootstrap-tier step like creating the `sops-age` secret. This document is the
authoritative record. Everything else (allowlists, clients on NixOS machines,
tailnet policy if adopted later) stays in Git.

## How it works

- The Proxmox host (`192.168.50.169`) runs `tailscaled` and advertises
  `192.168.50.0/24` as a subnet route.
- Remote devices (phone, laptop) join the same tailnet with "use subnet
  routes" enabled. They can then reach every LAN IP, including the service VIP
  `192.168.50.100`. DuckDNS already resolves `*.erikfrankling.duckdns.org` to
  that private IP, so all HTTPS routes work unchanged when remote.
- The subnet router SNATs forwarded traffic by default, so requests arrive on
  the LAN appearing to come from `192.168.50.169` — the Traefik `lan-only`
  allowlist passes without depending on the Tailscale range. The Tailscale
  CGNAT range `100.64.0.0/10` is also in the allowlists (replacing the old
  `10.8.0.0/24`) so nothing breaks if SNAT is ever disabled to preserve
  client IPs.
- **The router needs no configuration at all.** Tailscale only makes outbound
  connections. (Optional: if `tailscale ping <device>` shows traffic relayed
  via DERP instead of "direct", enable UPnP/NAT-PMP on the router or forward
  UDP 41641 to `192.168.50.169`.)

## Full setup from scratch (Proxmox host, Debian 13)

All as root on the Proxmox host (`ssh root@192.168.50.169`).

1. Install Tailscale from the official apt repo:

   ```bash
   curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
     -o /usr/share/keyrings/tailscale-archive-keyring.gpg
   curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
     -o /etc/apt/sources.list.d/tailscale.list
   apt-get update
   apt-get install tailscale
   ```

   The package enables and starts `tailscaled` automatically. (For a Debian
   release newer than trixie, substitute its codename in both URLs.)

2. Enable IP forwarding (required for subnet routing):

   ```bash
   printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
     > /etc/sysctl.d/99-tailscale.conf
   sysctl -p /etc/sysctl.d/99-tailscale.conf
   ```

3. Enable UDP GRO forwarding on the bridge (Tailscale's recommended
   forwarding-throughput tuning for kernel ≥ 6.2). `ethtool` settings do not
   survive reboot, so a oneshot systemd unit reapplies them; Proxmox uses
   ifupdown2, not networkd-dispatcher, hence a unit rather than a dispatcher
   hook:

   ```bash
   ethtool -K vmbr0 rx-udp-gro-forwarding on rx-gro-list off
   cat > /etc/systemd/system/tailscale-offload.service <<'EOF'
   [Unit]
   Description=Enable UDP GRO forwarding on vmbr0 for Tailscale subnet routing
   After=network-online.target tailscaled.service
   Wants=network-online.target

   [Service]
   Type=oneshot
   ExecStart=/usr/sbin/ethtool -K vmbr0 rx-udp-gro-forwarding on rx-gro-list off
   RemainAfterExit=yes

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl enable --now tailscale-offload.service
   ```

4. Bring the node up as a subnet router:

   ```bash
   tailscale up --advertise-routes=192.168.50.0/24 --ssh --accept-dns=false
   ```

   - `--advertise-routes=192.168.50.0/24`: offer the LAN to the tailnet.
   - `--ssh`: enable Tailscale SSH into the hypervisor as break-glass access.
   - `--accept-dns=false`: the hypervisor keeps its own resolver; if the
     tailnet's DNS is ever pointed at AdGuard, the hypervisor must not depend
     on a VM to resolve names.

   The command prints a `https://login.tailscale.com/a/...` URL. Open it in a
   browser, log in (first login creates the tailnet), and click **Connect**
   to authorize the machine.

5. Admin console steps, click by click (<https://login.tailscale.com/admin>):

   1. **Approve the subnet route**: go to the **Machines** page → click the
      `proxmox` machine row → in the **Subnets** section on the machine page
      (or the **⋯** menu at the right of the row → **Edit route settings**)
      → toggle `192.168.50.0/24` on → **Save**. Until approved, the
      advertised route does nothing.
   2. **Disable key expiry**: **Machines** page → **⋯** menu on the `proxmox`
      row → **Disable key expiry**. Otherwise the node's key expires (default
      180 days) and remote access silently dies until re-authentication.
      (Client machines enrolled with a *tagged* auth key — see below — get
      expiry disabled automatically and need no such click.)
   3. Optional, **tailnet-wide ad blocking**: **DNS** page → **Nameservers**
      → **Add nameserver** → **Custom** → `192.168.50.100` (AdGuard) → enable
      **Override DNS servers**. Remote clients then resolve through AdGuard
      like LAN clients do. Skip if AdGuard downtime while remote is a concern.

6. Verify (see below).

## Adding client devices

- **Phone / other computers**: install the Tailscale app, log in with the same
  account. In the app, enable using subnet routes if prompted (Android/iOS
  accept routes automatically).
- **Linux CLI clients**: `tailscale up --accept-routes` (routes are not
  accepted by default on Linux).
- **NixOS machines (dotfiles repo)**: `modules/nixos/tailscale.nix` (replaces
  `modules/nixos/openvpn.nix`). It enrolls unattended from a SOPS-stored
  pre-auth key and accepts subnet routes via `extraSetFlags`. Note Tailscale's
  WireGuard MTU is 1280, which makes the old `mssfix 1280` OpenVPN workaround
  unnecessary.

  The stored secret is an **OAuth client secret**, not a normal auth key:
  OAuth secrets never expire, and because enrollment is tagged, node-key
  expiry is disabled automatically — set the secret up once and both running
  machines and future reinstalls work indefinitely. One-time console setup:

  1. **Access controls** → **JSON editor** (or the Definitions page) → add:

     ```jsonc
     "tagOwners": {
       "tag:client": ["autogroup:admin"],
     },
     ```

     → **Save**.
  2. **Settings** → **OAuth clients** → **Generate OAuth client** → grant the
     **Auth Keys** (write) scope, assign **tag:client** → **Generate** → copy
     the `tskey-client-...` secret (shown once).
  3. Put it in each importing host's sops file as `tailscale-authkey`
     (currently only the framework laptop — the pc deliberately stays off
     the tailnet, since it sits inside the routed LAN):

     ```bash
     sops ~/.dotfiles/hosts/framework/secrets/secrets.yaml
     ```

  (A *tagged reusable* normal auth key from **Settings → Keys** also works —
  same module, same sops entry — but expires after 90 days for the purpose of
  enrolling new machines. Enrolled machines are unaffected either way.)
- Free "Personal" plan limits: 3 users, 100 devices — far above what this
  setup needs.

## Verification

From the Proxmox host:

```bash
tailscale status          # node listed, no Health warnings
tailscale ip -4           # the node's 100.x.y.z address
```

From a remote client (off Wi-Fi, e.g. phone on mobile data, Tailscale on):

1. `https://vault.erikfrankling.duckdns.org` loads (route through subnet
   router to the VIP works; certificate is the normal wildcard).
2. A `lan-only` route such as `https://adguard.erikfrankling.duckdns.org`
   loads (SNAT makes the request LAN-sourced).
3. `tailscale ping proxmox` reports `direct` (relayed via DERP also works but
   is slower; see the router note above).
4. Break-glass: `ssh root@proxmox` from a tailnet device using Tailscale SSH
   works even with LAN SSH keys absent.

## Failure modes and recovery

- **Monitoring can be green while a phone on mobile data cannot connect.**
  Gatus's `phone` group uses a Tailscale HTTP proxy on the k3s node. It
  checks subnet routing through Proxmox. Since 2026-10-16, the probe forces
  its encrypted peer connection through an internet DERP relay, so it cannot
  pass solely over the home LAN. It still does not check the phone's mobile
  internet path or the phone's DNS resolver. Since that date, the T3
  checks cover its real HTTPS hostname, certificate and `/ws` upgrade;
  previously both T3 checks only fetched the PC's HTTP homepage by IP.
  Native Gatus TCP/SSH checks do not use the HTTP proxy. Its HTTP CONNECT
  requests also use an absolute URL that the Tailscale proxy rejects; do not
  use either as a test of SSH through the tailnet.
  Do not call a mobile-only incident repaired based on these checks alone.
  Capture the failing attempt on Proxmox's `tailscale0` interface and compare
  with T3's HTTP traces on the PC to distinguish DNS/routing/TLS failures
  from backend failures. Capture headers only; do not retain user payloads.
- **Proxmox reboots**: everything comes back automatically (`tailscaled`
  enabled, sysctl and offload unit persist, Tailscale state in
  `/var/lib/tailscale`).
- **Node key expired** (if step 5.2 was skipped): run `tailscale up` again on
  the host and re-authenticate via the printed URL.
- **Full reinstall**: repeat this document from step 1. Approving the route
  and disabling expiry must be redone in the console for the new machine
  entry; delete the stale machine from the Machines page.
- **Redundancy option (not currently done)**: the same subnet route may
  additionally be advertised from `naiaclaw` or a cluster pod; Tailscale
  fails over between routers advertising identical routes.

## Relation to the old OpenVPN setup

| OpenVPN era | Now |
|---|---|
| Server config in router UI (lost with router) | This document + `/var/lib/tailscale` state; router untouched |
| Client range `10.8.0.0/24` in Traefik allowlists | `100.64.0.0/10` (Tailscale CGNAT range) |
| `.ovpn` + credentials distributed to clients | Tailscale app login |
| DNS pushed by server (`updateResolvConf`) | Optional tailnet DNS → AdGuard (step 5.3) |
| Full-tunnel option | Not enabled; add `--advertise-exit-node` on the host and approve it in the console if wanted |
