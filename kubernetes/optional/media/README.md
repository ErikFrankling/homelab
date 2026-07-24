# Optional media automation stack

This package is intentionally not referenced by
`kubernetes/homelab/kustomization.yaml`.

It contains qBittorrent behind a Gluetun WireGuard sidecar, Sonarr, Radarr,
Prowlarr, and Jellyfin. It remains fail-closed until all of these gates pass:

1. Attach and mount a dedicated media disk on the k3s VM.
2. Create a static `homelab-media` PersistentVolume with reclaim policy
   `Retain`. Downloads and the library must share this one filesystem so
   hardlinks and atomic moves work.
3. Generate a Mullvad WireGuard configuration. Create the `media-vpn` Secret
   from `media-vpn.env.example`.
4. Replace the TEST-NET endpoint in `torrent.yaml` with the exact Mullvad peer
   IP and keep it synchronized with `WIREGUARD_ENDPOINT_IP`.
5. Verify the qBittorrent public IP and DNS are Mullvad, then deliberately take
   `tun0` down and prove all torrent egress stops.
6. Change the generated qBittorrent password, bind qBittorrent to `tun0`, and
   disable UPnP/NAT-PMP.
7. Configure Prowlarr, then connect it to Sonarr/Radarr. Use
   `/data/torrents/{tv,movies}` and `/data/media/{tv,movies}` with no remote
   path mapping.
8. Confirm matching inode numbers after a test import before enabling normal
   automation.

Mullvad does not provide inbound port forwarding. Torrenting still works, but
inbound peer connectivity and seeding performance can be lower.

The GTX 1060 is attached to the Proxmox host, not this VM. Jellyfin is therefore
configured for direct play/software transcoding only until GPU passthrough and
the NVIDIA device plugin are deliberately added.
