# CLIProxyAPI: one home for every Claude, Codex, Grok and OpenCode login

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

Priority: the highest tier is used first; the default is 0. `patriktang.1@gmail.com`
(Claude) has priority -1 (2026-11-18), so it only gets traffic when every
other Claude account is unavailable. A thread that has moved to it stays on it
until that account runs out too, because an existing binding outranks priority.
The value is stored in the auth file on the PVC. Set it in the panel's edit dialog or with
`PATCH /v0/management/auth-files/fields` `{"name": "<file>", "priority": -1}`.


## Grok and OpenCode Go (added 2026-11-14)

- **Grok** (SuperGrok, `ef.pro454@gmail.com`): a native xAI OAuth login, its own
  grant (the local `grok` CLI keeps its own). Added with
  `GET /v0/management/xai-auth-url`, a device code: open the returned
  `accounts.x.ai/oauth2/device?user_code=...` URL in the agent Chromium (signed
  in through the cookie sync), Continue, Allow. Requests go to
  `cli-chat-proxy.grok.com`, the plan's included usage. Models are the plain
  `grok-*` names (`grok-4.7-build-fast`, ...).
- **OpenCode Go**: a static API key as `api-keys.openai-compatibility`
  `opencode-go` in `secrets/cliproxy.enc.yaml`, with `prefix: opencode`, so
  clients call `opencode/<model>` (`opencode/kimi-k3`, `opencode/glm-5.3`).
  `routing.force-model-prefix: true` keeps Go's own `claude-haiku-5-5` and
  `grok-4.7` out of the Claude and xAI pools. Go refuses a request without a
  per-conversation session id (`MissingSessionID`). The provider forwards
  Claude Code's `X-Claude-Code-Session-Id`, Codex's `session_id` and
  `x-opencode-session`, so those clients work and a bare curl does not. Left
  out: the `*-contributor` and `*-free` models (they train on request data).
  The model list is fixed in the secret: add new Go models there
  (`GET https://opencode.ai/inference/go/openai/v1/models`).
- The config watcher does not reload `/data/config.yaml` written from
  `kubectl exec`. To apply a secret change without a restart (which drops
  every in-flight stream), also PUT it through the management API
  (`/v0/management/openai-compatibility`, `/v0/management/force-model-prefix`).

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

## Usage, allowance and forecast

https://cliproxy-usage.erikfrankling.duckdns.org/runway/ is our own usage view,
linked as **Quota runway** on Homepage. One range control (24 hours, 7 days,
30 days, all time; kept in the URL hash and localStorage) drives every panel:

- headline numbers: tokens, requests, average and busiest day or hour, and the
  weekly allowance left per provider in accounts' worth;
- tokens per hour or day stacked by model, or as a running total, with the
  range split by account and by model (`/usage/analysis`; "all time" asks for
  Keeper's longest custom range, 365 days, and trims empty leading days);
- remaining allowance with one line per account, its forecast at the measured
  pace times a multiplier, and the next provider reset;
- weekly cycles per account: points used, tokens, and tokens per 1%.

Keeper keeps 30 days of quota history, so the allowance chart and cycles stop
there; token history goes back to the first recorded day. Keeper itself remains
at the original root.

The view is static HTML/CSS/ES modules under `config/quota-runway/`, served by
upstream nginx as a small sidecar in the Keeper pod. It reads Keeper's existing
same-origin `/api/v1/usage/identities`, `/usage/analysis`, `/quota/cache` and `/quota/history/:id`
APIs with `x-cpa-usage-keeper-request: fetch`. It never reads proxy credentials,
creates another queue consumer, or fabricates missing historical observations.
All routes remain LAN/Tailscale-only. No image build or additional database.

Limits are matched by window length (5 hours, 7 days), not by Keeper's
primary/secondary slot: Codex Pro reports its weekly limit as "primary". Claude
uses the exact `five_hour`/`seven_day` keys so Fable and oauth-app rows never
count. A line breaks only at a new quota cycle; inside a cycle the reading only
falls. An account without history never hides the others (the old pooled average
did, and showed less than a day). The Show selector filters chart lines only;
account cards list every account, including disabled ones, with every quota row.

When a cache is empty, failed, older than five minutes, or past reset, the page
POSTs `/quota/refresh` and polls `/quota/refresh/:auth_index` to completion
(up to 45 seconds). Provider attempts have a one-minute cooldown. Cache reads repeat every minute; histories (seconds each for busy accounts)
load two at a time with a 90-second timeout and refresh every five minutes, with bounded retry after network errors and immediate
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
projected. Missing rates show the current dot and a flat dashed line to the next reset,
without invented burn. Old readings (>15 minutes), missing data and elapsed resets are marked stale.

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
