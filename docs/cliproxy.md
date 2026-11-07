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
(management key: `cat /run/secrets/cliproxy-management-key` on the PC or laptop).
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
so it is the only consumer of that queue. Log in with the management key.
