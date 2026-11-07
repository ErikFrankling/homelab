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

Select provider/plan, 5-hour or weekly limit, history period and forecast
horizon. One full account allowance = 100% of the selected limit on one account.
Only matching provider/plan accounts are summed; unknown plans stay isolated
until Keeper reports them. Short and weekly quotas are independent constraints;
the account cards show the other window so an available weekly allowance does
not imply a usable account while its short window is depleted.

Rate calculation uses observed percentage-point drops inside cycles, excluding
resets, intervals blocked at zero, and gaps longer than two hours. At least five
minutes of usable observations are required. The default lookback is six hours.
The resulting rate is a conditional recent unblocked pace, not guaranteed
wall-clock throughput. Both the forecast and exhaustion time respond to the
pace slider. Only the next provider-reported reset is projected, with a reset
to full quota; later reset times are not invented. Unknown rates show a dotted purple reset-only ceiling (no spending assumed),
with scheduled reset markers and no invented burn curve. Old readings (>15 minutes),
missing data and elapsed resets are marked stale. History begins where Keeper
actually observed the quota, not at an invented full starting balance.

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
