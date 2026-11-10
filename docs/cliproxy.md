# CLIProxyAPI: one home for every Claude and Codex login

`apps/cliproxy.yaml` runs [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
at `https://cliproxy.erikfrankling.duckdns.org` (lan-only: LAN and Tailscale).
Every account is signed in here, once. The PC, the laptop and any T3 Code server
point Claude Code and Codex at it instead of logging in themselves, so:

- logins are refreshed in one place (no more random sign-outs, no grant fights
  between machines),
- all upstream traffic leaves from the home IP,
- usage across accounts is pooled: round-robin with session affinity, so a
  thread stays on one account (prompt cache) and moves only when that account
  hits its limit (`session-affinity-rebind-on: quota`).

Rules (Theo's, and ours): never serve anyone else's traffic with the subs, and
only use the Claude subs from Claude Code / the Claude Agent SDK.

## Keys

- Client access key: `config.yaml` `access.api-keys` in `secrets/cliproxy.enc.yaml`;
  the same value is the dotfiles sops secret `cliproxy-client-key`.
- Management key: `management.secret-key` (dotfiles sops `cliproxy-management-key`).
  The panel is at `https://cliproxy.erikfrankling.duckdns.org/management.html`.

Never print management usage responses unfiltered: they contain upstream tokens.

## Sign an account in

Use the built-in panel: https://cliproxy.erikfrankling.duckdns.org/management.html
(opens directly on the private network; the server-side gateway holds its key).
OAuth login, pick Claude or Codex, open the link in a browser signed in to that
account, authorize, then paste the localhost callback URL the browser lands on
back into the panel. Logins are stored on the `cliproxy-data` PVC
(`/data/auths`). To bench an account, disable it in the panel.

## Clients

Dotfiles `modules/home-manager/cliproxy.nix` sets `ANTHROPIC_BASE_URL` and an
`apiKeyHelper` in `~/.claude/settings.json`, and the `cliproxy` model provider
in `~/.codex/config.toml`, on every host.

## Usage and quota dashboard

CPA Usage Keeper (`apps/cpa-usage-keeper.yaml`) at
https://cliproxy-usage.erikfrankling.duckdns.org (lan-only): cost and tokens
over time per account and model, and each account's 5-hour and weekly limits
with reset times. It drains the proxy's usage queue (needs
`observability.usage.usage-statistics-enabled: true`) into SQLite on its PVC,
so it is the only consumer of that queue. Authentication is disabled on the
private-network dashboard; no separate login.

## Remaining allowance and forecast

https://cliproxy-usage.erikfrankling.duckdns.org/runway/ is the quota runway view,
also linked as **Quota runway** on Homepage. It adds the missing pooled
remaining-capacity graph: observed drops, scheduled reset jumps, projected burn,
per-account status, and an adjustable consumption multiplier. Keeper remains
available at the original root for costs, requests and token charts.

The view is static HTML/CSS/ES modules under `config/quota-runway/`, served by
upstream nginx as a small sidecar in the Keeper pod. It reads Keeper's existing
same-origin `/api/v1/usage/identities`, `/quota/cache` and `/quota/history/:id`
APIs with `x-cpa-usage-keeper-request: fetch`. It never reads proxy credentials,
creates another queue consumer, or fabricates missing historical observations.
All routes remain LAN/Tailscale-only. No image build or additional database.

The default graph compares Claude and Codex on one percentage axis with separate
lines per provider/plan. Each line averages matching account allowances; it does
not claim that different subscriptions have equal token budgets. The selector
filters chart lines only: all accounts remain visible underneath, including
disabled accounts. Cards list every normalized quota row (including model-scoped
Fable), provider reset times, inactive/restricted states, and explicit missing
readings. Main graph windows use exact quota keys, never the first weekly row.

When a cache is empty, failed, older than five minutes, or past reset, the page
POSTs `/quota/refresh` and polls `/quota/refresh/:auth_index` to completion
(up to 45 seconds). Provider attempts have a one-minute cooldown. Cache/history
reads repeat every minute, with bounded retry after network errors and immediate
recovery on reconnect/focus. Last good readings retain their original timestamps.
Account cards appear before a slow provider refresh completes. Refresh buttons
force provider reads rather than merely rereading the cache.

Reset usage reads current `/quota/claude-reset-grants/:id` or
`/quota/reset-credits/:id`. Claude presents every usable grant and its cleared
limits, then posts `auth_index`, `grant_id` and `organization_id` to `/quota/reset`.
Codex confirms consuming one credit. No reset request is retried: an ambiguous
response can still have consumed a credit. Result codes and routing recovery
failure remain visible while quota is refreshed. No-credit and unavailable-grant
states are explicit.

Rate calculation uses observed percentage-point drops inside cycles, excluding
resets, intervals blocked at zero, and gaps longer than two hours. At least five
minutes of usable observations are required. Only the next provider reset is
projected. Missing rates show current dots and reset markers without invented
burn. Old readings (>15 minutes), missing data and elapsed resets are marked stale.

### Claude scoped limits compatibility

Upstream Keeper 2.1.0 discards Anthropic's `limits[]`. The provider currently puts
Fable in `weekly_scoped` with `scope.model.display_name`, `percent`, `resets_at`
and `is_active`; it may report 0% used while inactive. Legacy `five_hour` can be
null. Never invent a 5-hour allowance from that or conflate Fable with `seven_day`.
`config/keeper-limits/scoped-limits.patch` preserves those scoped rows and inactive
flags while retaining legacy keys and history. Its Dockerfile pins upstream
41b34f12dbef209292765415b860583aad5afc09 and runs a parser/normalizer regression
test. Build on k8s and import before pushing the deployment (the local image uses
`imagePullPolicy: Never`):

```sh
rsync -a kubernetes/homelab/config/keeper-limits/ k8s:quota-keeper-build/
ssh k8s 'cd quota-keeper-build && sudo docker build --memory=3g --cpuset-cpus=0,1 -t docker.io/library/cpa-usage-keeper:2.1.0-scoped1 . && sudo docker save docker.io/library/cpa-usage-keeper:2.1.0-scoped1 | sudo k3s ctr -n k8s.io images import -'
```

Rebuild/import after node replacement. Bump the tag when changing the patch.
The upstream image remains the rollback. No database schema changes.

Keeper's own background refresh was enabled at five-minute intervals. This is
stored on its existing PVC, so it survives restarts. After replacing that DB,
restore it using its supported setting API:

```sh
curl -fsS -X PUT \
  -H 'x-cpa-usage-keeper-request: fetch' -H 'Content-Type: application/json' \
  -d '{"enabled":true,"schedule":{"unit":"minute","value":5}}' \
  https://cliproxy-usage.erikfrankling.duckdns.org/api/v1/quota/auto-refresh/settings
```

The normalized quota cache is in memory: after a Keeper restart some plans and
readings can be missing until its refresh or a new provider response. The view
uses persisted history where possible and does not merge unknown-plan accounts.

Validate changes with `node --test config/quota-runway/model.test.mjs` (from
`kubernetes/homelab`). Tests cover reset boundaries, staggered pooled resets,
rate-limited time, stale readings, missing quota windows, data gaps, and the
pace multiplier. Kustomize hashes assets to roll the sidecar on changes.
