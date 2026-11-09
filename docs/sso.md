# Homelab single sign-on

Identity provider: https://auth.erikfrankling.duckdns.org. Authentik 2026.8.5,
upstream Helm chart rendered into `kubernetes/homelab/apps/authentik.yaml`.
PostgreSQL has its own retained PVC. Secrets and client credentials are SOPS
encrypted. The route is LAN/tailnet/cluster only. No public enrollment.

## Application support

| Application | Private-network entry |
| --- | --- |
| Keeper | Upstream `AUTH_ENABLED=false`; dashboard opens directly. |
| AdGuard | Upstream `users: []`; opens directly. HTTP NetworkPolicy still restricts backend access; DNS stays reachable. |
| Open WebUI | Upstream `WEBUI_AUTH=false`; existing single-user history retained. Opens directly. |
| Homepage | Opens directly; LAN/Tailscale route restriction remains. |
| OpenClaw | Upstream `--auth none --bind loopback`, with nginx in the same pod. Upstream refuses `none` on a LAN bind. WebSocket upgrade supported; no key in the browser. |
| ntfy | `enable-login: false`, `auth-default-access: read-write`. Existing sender tokens remain valid. |
| CLIProxy management | Pinned upstream frontend with a small automatic-session patch. nginx supplies the management key server-side, only on `/v0/management/` and `/v8/management/`. Model APIs still require API keys. |
| Grafana | Native OIDC, automatic redirect, owner-only administrator role. Recovery: `/login?disableAutoLogin=true`. |
| Executor | Native OIDC linked to the existing owner. `/login` automatically starts the supported SSO API; account data and MCP grants retained. |
| Fleet | `/login` automatically calls its existing name-only login as `erik`; existing sessions are retained. |
| Proxmox | Native default OpenID realm `homelab`; owner `akadmin@homelab` has Administrator at `/`. Small UI patch automatically starts OIDC. `?manual=1` retains recovery realms. |
| Vaultwarden | Native OIDC, `SSO_ONLY=true`, existing account matched by verified email, no new-account signup. Vault **decryption** remains: enroll device/biometric unlock with Erik rather than weakening encryption. |
| T3 Code | Existing device pairing/session; no application password added. API/WebSocket routes stay direct. |
| Time, School, X graph, Brain, Search, Health, Prometheus, Alertmanager, Traefik, llama-swap, OpenCode | Existing direct private-network entry; no extra login gate. |
| Nix cache, T3 updates | Machine endpoints retain existing access controls; no browser password added. |

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

## Verification and recovery

Verified on 2026-11-07: Keeper dashboard in a fresh incognito session; subsequent
protocol checks use a fresh cookie jar. One shared session completes Executor
login as the existing owner, Proxmox login as `akadmin@homelab`, and Vaultwarden's
OIDC round trip to its SSO connector. OpenClaw accepts a protocol-4 operator
WebSocket connection with no credentials. CLIProxy v0/v8 management config
responds 200 without a browser key; `/v1/models` still returns 401 without an API
key. ntfy config disables login and an anonymous topic poll returns 200.

Homepage, Chat and AdGuard return their application directly without SSO
redirects. Their previous forward-auth gates were removed to follow Erik's
preference for auth-off settings. The LAN/Tailscale ingress restriction and
AdGuard/Open WebUI backend NetworkPolicies remain. Open WebUI `/health` is a
LAN/cluster-only health route used by Gatus.

Executor uses `/api/auth/callback/sso` (its social login route), not the generic
OAuth plugin's alternative callback. Existing password accounts must explicitly
link SSO first; the owner was linked and verified through the supported API.

Initial PostgreSQL dump: `~/.local/state/homelab-sso/initial-config-2026-11-07.dump`
on the PC, private permissions, archive checked with `pg_restore --list`. This
is an initial recovery copy, not a replacement for regular off-machine backups.

## Small compatibility changes

`config/cliproxy-management/network-login.mjs` patches only the upstream auth
store, and fails its build if the expected source markers change. Upstream SHA
is `953fb2444350c6c36052dda46cac0abce6b23ea6`. To rebuild after a node replacement
or an upstream update, copy that directory to k8s, then run there:

```sh
docker build -t docker.io/library/cliproxy-management-network:953fb244-1 .
docker save docker.io/library/cliproxy-management-network:953fb244-1 | sudo k3s ctr -n k8s.io images import -
```

Use sudo for Docker where required. Bump the image tag in the deployment after
changing the patch. Its nginx configuration is SOPS-encrypted because it holds
the server-side management key. Rotate it with `CPA_MANAGEMENT_KEY`; never put
that key in the HTML. Inference routes continue to use the original server.

`config/executor-login/` contains the automatic-entry pages for Executor and
Fleet, served by upstream nginx. They use supported same-origin APIs and hold
no secrets. The specific `/login` routes leave callbacks, APIs and WebSockets
on the original services. Executor sign-out reloads `/`, returning through this
entry page. Errors show a retry button rather than entering a redirect loop.

Proxmox configuration is in `ops/proxmox/sso/`: copy `configure.py` to the host
and pipe the decrypted `PROXMOX_CLIENT_SECRET` from `sso-extra.enc.yaml` to it.
It backs up `/etc/pve/domains.cfg` and `user.cfg` under
`/root/homelab-sso-backups/` before adding/modifying the native realm. Install
`automatic-entry.py` at `/usr/local/lib/homelab-sso/automatic-entry.py` (0755)
and `99-homelab-sso` at `/etc/apt/apt.conf.d/99-homelab-sso`. The package hook
reapplies the guarded patch on updates and fails if upstream changes the target.
No Proxmox password is stored in a browser or proxy.

Vaultwarden's verified pre-change SQLite backup is on k8s at
`/home/ubuntu/homelab-sso/backups/vaultwarden-before-sso.sqlite3` (0600).
Authentik's issuer has a trailing slash: `SSO_AUTHORITY` must match it exactly,
despite Vaultwarden's generic `.env.template` advice. Otherwise discovery fails
with an issuer mismatch. The owner email is shared with the existing vault.
