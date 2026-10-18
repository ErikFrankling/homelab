# Home router

TP-Link **Archer AX12** (AX1500), LAN MAC `20:e1:5d:e4:2e:e0`, firmware
`AX12v1_1.10.2` (2026-06). Admin page: http://192.168.50.1. Passwords and the
Wi-Fi name are not recorded here.

The homelab uses static addresses on `192.168.50.0/24`. A factory-reset router
comes back on `192.168.0.1/24`, which strands Proxmox and naiaclaw (`.100`)
until the settings below are restored. This happened on 2026-08-05
and again on 2026-10-17.

## Settings

Menus are under **Advanced → Network**.

| Setting | Value |
|---|---|
| LAN IP (Network → LAN) | `192.168.50.1` / `255.255.255.0` |
| DHCP pool (Network → DHCP Server) | `192.168.50.110` – `192.168.50.254` |
| Default gateway | `192.168.50.1` |
| Primary DNS | `192.168.50.100` (AdGuard) |
| Secondary DNS | `9.9.9.9` (keeps internet working if the homelab is down; clients may sometimes bypass AdGuard) |
| Lease time | 120 minutes |
| Port forwards | none |

The router only accepts reservations inside the pool.

| Reservation | MAC | IP |
|---|---|---|
| pc | `E8-9C-25-46-5C-84` | `192.168.50.232` |
| framework (KVM ethernet) | `34-1B-22-83-55-87` | `192.168.50.133` |

The framework reservation uses the USB ethernet adapter in the KVM. The laptop
keeps its real MAC on wired links (dotfiles, `hosts/framework`); a random MAC
would miss the reservation.

Static addresses sit below the pool and need no reservation. **Never move the
pool below `.110`.**

| Static | Address | MAC |
|---|---|---|
| Proxmox host | `192.168.50.10` | `1C-1B-0D-A4-40-C0` |
| naiaclaw (VM 200): Traefik, AdGuard DNS, nix-builder, binary cache | `192.168.50.100` | `BC-24-11-37-6C-2C` |

No port forwards are needed. `*.erikfrankling.duckdns.org` points at the private
`192.168.50.100` and is only reachable at home or over Tailscale. Do not recreate
the old OpenVPN UDP 1194 forward.

## After a reset

1. Create the admin password and finish quick setup with the old Wi-Fi name and
   password, so devices reconnect without changes.
2. Set the LAN IP, then reconnect at http://192.168.50.1.
3. Set the DHCP pool, DNS and reservations above. Reload the page to confirm
   they saved.
4. On the PC, renew the lease and check:

   ```bash
   nmcli connection up "$(nmcli -g GENERAL.CONNECTION device show eno1)"
   ip -br a show eno1          # 192.168.50.232
   ping -c1 192.168.50.10
   curl -I https://t3code.erikfrankling.duckdns.org
   ```

   `nmcli device reapply` keeps the old lease; bringing the connection up again
   gets the reservation. On 2026-08-05 Proxmox only answered after a reboot.
5. Save a config backup: **Advanced → System → Backup & Restore**. Keep the file
   outside this public repo.
