# Home router

TP-Link **Archer AX12** (AX1500), LAN MAC `20:e1:5d:e4:2e:e0`, firmware
`AX12v1_1.10.2` (2026-06). Admin page: http://192.168.50.1. Passwords and the
Wi-Fi name are not recorded here.

The homelab uses static addresses on `192.168.50.0/24`. A factory-reset router
comes back on `192.168.0.1/24`, which strands Proxmox, naiaclaw and the `.100`
VIP until the settings below are restored. This happened on 2026-08-05 and
again on 2026-10-17.

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
| proxmox | `1C-1B-0D-A4-40-C0` | `192.168.50.169` |
| naiaclaw (VM 200) | `BC-24-11-37-6C-2C` | `192.168.50.200` |

Proxmox and naiaclaw are static on the machines and never ask for a lease; their
reservations only stop the router from giving those addresses to another device.

**Never put `.100` in the pool or reserve it.** It is the extra address on VM 200
for Traefik, AdGuard DNS, nix-builder and the binary cache.

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
   ping -c1 192.168.50.169
   curl -I https://t3code.erikfrankling.duckdns.org
   ```

   `nmcli device reapply` keeps the old lease; bringing the connection up again
   gets the reservation. On 2026-08-05 Proxmox only answered after a reboot.
5. Save a config backup: **Advanced → System → Backup & Restore**. Keep the file
   outside this public repo.
