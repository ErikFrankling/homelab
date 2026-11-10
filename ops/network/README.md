# Ablo laptop route

`70-t3code-ablo.yaml` adds only the Samsung laptop's Tailscale host route on
the k3s VM, through the existing Proxmox subnet router. Install mode 0600 in
`/etc/netplan/`, then `sudo netplan generate` and `sudo netplan apply`.
The existing default route and LAN address remain unchanged.

Traefik serves https://t3code-ablo.erikfrankling.duckdns.org with the existing
wildcard TLS certificate and `lan-only` middleware. The laptop's Tailscale
Serve TCP listener forwards port 3773 to its authenticated loopback T3 server.
The laptop must be awake and connected to Tailscale; the phone must reach the
homelab through LAN or Tailscale. Pairing remains T3's native device flow.
