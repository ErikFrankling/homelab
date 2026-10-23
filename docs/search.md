# Search over everything (Onyx)

One search for agents and Erik over mail, every agent session, notes, the
Canvas archive, saved X posts, Discord chats and the company brain. Adopted
2026-10-23 instead of building one: [Onyx](https://github.com/onyx-dot-app/onyx)
(MIT, ex-Danswer), manifests in `kubernetes/homelab/apps/onyx.yaml`.

- Web UI and admin: https://search.erikfrankling.duckdns.org (lan-and-cluster).
  User `erik.frankling@frankling.se`; password in the dotfiles sops secret
  `onyx-admin-password`.
- MCP: `https://search.erikfrankling.duckdns.org/mcp/`, tool
  `search_indexed_documents` (also `search_web`, `open_urls`). Bearer: an Onyx
  personal access token. Agents reach it through Executor as the app
  `app-search` (`tools["app-search"].search_indexed_documents`); the personal
  agent also has it directly (dotfiles `personalAgent.mcpServers.search`).

## How it is put together

| Piece | What |
|---|---|
| onyx-api, onyx-background, onyx-web, onyx-mcp | Onyx v4.9.4, upstream's docker-compose as plain manifests (no Helm: the chart installs cluster-scoped operators) |
| onyx-db, onyx-cache, onyx-opensearch | Postgres 15 (also the file store), Redis, OpenSearch 3.6 (hybrid BM25 + vector index) |
| onyx-embed | EmbeddingGemma-300M on llama.cpp Vulkan on the GTX 1060, shared with kokoro-tts without a device-plugin request. Onyx calls it as a LiteLLM embedding provider (`http://onyx-embed:8080/v1/embeddings`, no prefixes) |
| onyx-model | Onyx's own model server (CPU). Its PyTorch has no sm_61 kernels, so it cannot use the 1060 |
| LLM | Onyx's search asks an LLM to pick the relevant results. Default provider "PC llama-swap (local)": `http://192.168.50.232:8000/v1`, model `read-aloud-summary` (Gemma 4 E4B, always loaded next to dictation on the PC). If the PC is off, search returns an error |

Search settings, the embedding provider and the LLM provider live in Onyx's
Postgres (set through its admin API), not in git.

## Getting data in

Built-in connectors (Gmail, Drive, GitHub, Outlook...) need OAuth apps in
Onyx; none are configured yet. Everything indexed today is pushed by
`search-sync` on the PC (github.com/ErikFrankling/search-sync, dotfiles
`modules/home-manager/search-sync.nix`, hourly) through Onyx's ingestion API:

- T3 Code threads (`~/.t3/userdata/statev2.sqlite`), Claude Code and Codex
  transcripts that did not run under T3
- mail from Thunderbird's IMAP caches: KTH, both Gmail accounts, frankling.se,
  outlook.com
- the Obsidian vault, the KTH Canvas archive (md/txt/html/pdf), x-graph (saved
  X posts and Discord chats), the company brain

Ingested documents belong to paused placeholder connectors, one per source
type (cc_pair ids: file 2, web 3, discord 4, imap 5, canvas 6). MCP search only
offers source types that have a connector, and the built-in "Ingestion API"
source is hidden. Placeholders that cannot be created through the API (IMAP,
Canvas and Discord validate credentials) were inserted into
`connector_credential_pair` in SQL. Never unpause them: they have no real
credentials and would only fail.

Throughput: about 3.6k tokens/s on the 1060, so a full re-index of the ~170 M
characters takes 4-6 hours. Reset with `rm ~/.local/state/search-sync/state.db`
on the PC and start `systemctl --user start search-sync`.

## Pitfalls met

- Onyx API keys are a paid feature; personal access tokens are not. The sync
  uses an unscoped PAT (needs manage-connectors), agents a `read:search` one.
- A cloud embedding provider (LiteLLM) rejects query/passage prefixes:
  "Prefix string is not valid for cloud models". Set them empty.
- The node had 110 pods and was full; `max-pods=200` in `ops/k3s/config.yaml`.
- CPU requests are 2m: the node is ~99% CPU-requested.
- Admin setting `auto_detect_search_filters` is off (PATCH /api/admin/settings).
  With it on, the LLM guessed a source filter (often `github`) for unfiltered
  queries and returned unrelated PRs or nothing.
- Onyx's GitHub connector (cc_pair 7, daily) indexes ErikFrankling PRs and
  issues with Erik's `gh` token; it is the only connector that fetches itself.
