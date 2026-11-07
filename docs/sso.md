# Homelab single sign-on

Identity provider: https://auth.erikfrankling.duckdns.org. Authentik 2026.8.5,
upstream Helm chart rendered into `kubernetes/homelab/apps/authentik.yaml`.
PostgreSQL has its own retained PVC. Secrets and client credentials are SOPS
encrypted. The route is LAN/tailnet/cluster only. No public enrollment.

## Application support

| Application | Integration / limitation |
| --- | --- |
| Grafana | Native OIDC, automatic redirect, admin role only for Authentik Admins. Local login fallback: `/login?disableAutoLogin=true`. |
| CLIProxy usage (Keeper 2.0.3) | Native OIDC; use its OIDC button. `AUTH_OIDC_PROMPT_LOGIN=false` reuses the shared session; password fallback retained. |
| Executor | Native OIDC, existing owner email, SSO button. Existing password and MCP credentials retained. |
| AdGuard Home | No native SSO. Supported `users: []` behind Authentik forward-auth; NetworkPolicy allows HTTP only from Traefik. DNS stays reachable. Unused setup LoadBalancer port removed. |
| Open WebUI | Already `WEBUI_AUTH=false`; shared login at Traefik protects its existing single-user account without creating a second chat history. NetworkPolicy blocks direct HTTP access. |
| Homepage | Shared login at Traefik. |
| Vaultwarden 1.37.5 | Supports OIDC, but vault decryption still needs an unlock. Existing login remains available. |
| CLIProxy management | Management key is mandatory, including localhost; not native SSO. Do not remove API authentication or inject the management key into public frontend assets. |
| T3 Code | Existing device pairing/session retained. Do not wrap API/WebSocket routes in browser redirects. |
| OpenClaw | Existing gateway token/device approval retained. |
| ntfy | Existing user/token authentication retained for native notification clients. |
| Proxmox | Supports OpenID realms; existing host login retained. |
| Time, School, X graph, Brain, Search, Health, Prometheus, Alertmanager, Traefik, llama-swap | Already usable without a separate browser login on their private routes. No extra login gate added to machine-facing APIs. |
| Fleet, OpenCode, Naiaclaw, Planet9, p9eval | Separate applications; no unsupported SSO claims or changes to their authentication. |
| Nix cache, registry, T3 updates | Machine-facing endpoints; leave their existing access controls and clients intact. |

All configured Authentik applications bind access to `authentik Admins`.
The initial owner is `akadmin`, display name Erik, with the same email as
Executor's existing owner. A dedicated email scope asserts verification only
for that provisioned owner. Do not turn on public enrollment or broaden that
claim to arbitrary accounts.

## Login and passkeys

The default login session lasts 30 days; Remember me extends it by 60 days.
Register a discoverable passkey in Authentik's user settings, then use
"Sign in with a passkey" on the login page. Passkey authentication requires
user verification (biometric or device PIN). Authentik's bootstrap password is
stored only in `secrets/authentik.enc.yaml`; it is a recovery credential.
Device enrollment requires Erik's physical interaction.

## Maintenance

Render after changing chart values:

```sh
helm template authentik authentik --repo https://charts.goauthentik.io \
  --version 2026.8.5 --namespace homelab \
  -f kubernetes/homelab/config/authentik/values.yaml \
  > kubernetes/homelab/apps/authentik.yaml
kubectl kustomize kubernetes/homelab >/dev/null
```

Blueprints are in `config/authentik/homelab.yaml`. The named ConfigMap is not
content-hashed because Authentik discovers mounted blueprint changes. Client
secrets come from the worker environment, not plaintext blueprint content.
Changing an environment secret requires restarting the consumer via a pod
spec change. Use a health-watch maintenance window before deployment.

During the initial install, restarting midway through the first migration
left an incomplete schema and a lifecycle transaction blocking Django DDL.
The incomplete, unused `authentik` database was preserved; the clean active
database is `homelab_sso`. Let the initial server migration finish before
starting the worker or changing the server pod. Never reset an in-use SSO
database. Back up with `pg_dump -Fc` and verify with `pg_restore --list`
before maintenance that changes data.

## Sources

- https://docs.goauthentik.io/install-config/install/kubernetes/
- https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_traefik/
- https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/generic-oauth/
- https://github.com/Willxup/cpa-usage-keeper/blob/v2.0.3/docs/oidc.md
- https://github.com/UsefulSoftwareCo/executor/blob/v2/apps/hosted/self-host/compose.yaml
- https://github.com/dani-garcia/vaultwarden/blob/1.37.5/.env.template
- https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration
