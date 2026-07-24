# Docker-to-k3s cutover runbook

## Invariants

- Do not stop VM 100 before the registry route works through cluster Traefik.
- Never activate `192.168.50.100` on both VMs.
- Never start stateful applications against the same copied data in both
  environments.
- Keep the Docker VM disk intact for rollback.

## Stage

1. Confirm Docker `main` contains preservation commit `e16ee23`.
2. Apply `kubernetes/bootstrap/namespace-rbac.yaml`.
3. Install the offline age identity as `homelab/sops-age`.
4. Decrypt/apply the DuckDNS Secret, then apply the Traefik
   `HelmChartConfig`.
5. Confirm Traefik rollout and persistent data PVC.
6. Push the zero-replica application commit and apply
   `kubernetes/bootstrap/flux.yaml`.
7. Apply `ops/migration-helper.yaml`; wait for every PVC to bind.
8. Validate the cluster routes against `.200` with `curl --resolve`. At this
   stage application routes should be unavailable, but dashboard, TLS issuance,
   and external registry/Naiaclaw/P9 routes must behave as expected.

## Copy and switch

1. Stop the seven Compose containers cleanly. Do not delete them or their data.
2. Stream each data directory into the matching migration-helper mount,
   preserving numeric owners:
   - AdGuard `data/adguard/*` to `/mnt/adguard`
   - Hermes `data/hermes/*` to `/mnt/hermes`
   - OpenClaw `data/openclaw/config/*` to `/mnt/openclaw`, then
     `data/openclaw/workspace/*` to `/mnt/openclaw/workspace`
   - Open WebUI `data/openwebui/*` to `/mnt/openwebui`
   - Vaultwarden `data/vaultwarden/*` to `/mnt/vaultwarden`
3. Check SQLite integrity for Vaultwarden and Open WebUI inside the copied
   volumes.
4. Delete the migration helper.
5. Push the commit that changes application replicas to one and Flux
   `wait: true`.
6. Test all applications against `.200` using `curl --resolve`, including
   registry `/v2/`, wildcard SAN/issuer/expiry, data presence, and authentication
   state.
7. Shut down VM 100 in Proxmox.
8. Install and start `ops/systemd/homelab-vip.service` on VM 200.
9. Re-test using normal DuckDNS resolution to `.100`.
10. Set VM 100 `onboot=0`. Keep its disk and `onboot=1` for VM 200.
11. Restart one noncritical private-registry workload and prove it can pull
    through the new registry route.

## Verification matrix

| Host | Expected |
|---|---|
| `traefik.*` | 302/dashboard, LAN only |
| `adguard.*` | 302/login, LAN only |
| `vault.*` | 200 and existing vault data |
| `chat.*` | 200 and existing Open WebUI data |
| `claw.*` | 200 and existing OpenClaw state, LAN only |
| `naiaclaw-api.*` | 200, LAN only |
| `planet9-test.*` | 200, LAN only |
| `registry.*` | `/v2/` reachable, LAN only |
| `p9eval.*` | Known pre-migration failure until its workload returns |

Also verify DNS 53 over TCP and UDP, direct OpenClaw port 18789, pod
readiness/restarts, node memory, root disk, Flux readiness, and Traefik ACME
logs.

## Rollback

1. Scale homelab Deployments to zero.
2. Stop and disable `homelab-vip.service`; verify `.100` is absent from VM 200.
3. Start VM 100 and its Compose project.
4. Verify `.100`, wildcard TLS, registry, DNS, and application routes.
5. Do not copy Kubernetes data back without a deliberate conflict-free restore
   plan; choose one environment as authoritative.
