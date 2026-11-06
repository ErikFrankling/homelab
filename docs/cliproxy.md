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

Logins are OAuth and are stored on the `cliproxy-data` PVC (`/data/auths`).
From the PC (the browser that finishes the login must reach the callback port):

```sh
kubectl -n homelab port-forward deploy/cliproxy 54545:54545   # Claude
kubectl -n homelab port-forward deploy/cliproxy 1455:1455     # Codex
kubectl -n homelab exec -it deploy/cliproxy -- /CLIProxyAPI/CLIProxyAPI -config /data/config.yaml -claude-login -no-browser
kubectl -n homelab exec -it deploy/cliproxy -- /CLIProxyAPI/CLIProxyAPI -config /data/config.yaml -codex-device-login
```

(kubectl runs on naiaclaw: `ssh -L 54545:127.0.0.1:54545 naiaclaw sudo kubectl ...`.)
Open the printed URL in a browser signed in to that account. To bench an
account, set `"disabled": true` in its auth JSON.

## Clients

Dotfiles `modules/home-manager/cliproxy.nix` sets `ANTHROPIC_BASE_URL` and an
`apiKeyHelper` in `~/.claude/settings.json`, and the `cliproxy` model provider
in `~/.codex/config.toml`, on every host.
