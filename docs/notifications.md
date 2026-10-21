# Phone notifications (ntfy backbone, Discord delivery)

**What reaches Erik's phone today is Discord**, not the ntfy app: Erik will
not install another app. The Executor app `notify` and the `notify-erik` CLI
(dotfiles, `notify` skill) post to a webhook in #notifications of his private
Discord server "Agents"; the Discord app he already has pushes it. Every send
is also mirrored to the ntfy server below, the backbone for native push in
the T3 Code Android app (in progress). **Senders that publish to ntfy only
(Time) do not reach his phone yet**; until the T3 app receives
push, send what he must see through Executor's `notify` app. Alertmanager
posts to the same Discord webhook itself (secret `alerts-discord`, see
docs/observability.md) and mirrors to ntfy.

A self-hosted [ntfy](https://ntfy.sh) server: `apps/ntfy.yaml`, settings in
`config/ntfy/server.yml`, users and tokens in `secrets/ntfy.enc.yaml`.

```
agent (any harness) --tools.notify.send--> Executor app `notify` --+--> Discord webhook --> Discord app on the phone
pc/framework scripts --notify-erik CLI-----------------------------+
                                                                   +--> ntfy topic `erik` (mirror)
Alertmanager (Discord itself + ntfy mirror), Time: plain HTTP ------------^
```

## Why ntfy

- Erik's T3 Code Android build has no Firebase project, so it cannot receive
  push while closed. ntfy's Android app keeps one websocket open in a
  foreground service ("instant delivery") and needs no Google services or
  third party; message text never leaves the house.
- It already does what agents need: priorities 1-5 (4-5 pop over the screen),
  a `copy` action button for one-time codes (Android app 1.23+), a click URL
  that opens the T3 thread, Markdown, per-topic ACLs and tokens declared in
  config.
- Route `lan-and-cluster`: the LAN, the tailnet (the phone, like T3 Code) and
  pods (Executor's `notify` app). DuckDNS points at the private address and
  the router has no port forwards, so the phone receives only while Tailscale
  is up. On top of that `auth-default-access: deny-all`: nothing works without
  a login or token, and signup is off.

## Users

| user     | access to `erik` | credentials                                           |
| -------- | ---------------- | ----------------------------------------------------- |
| `erik`   | read-write       | password; dotfiles `secrets/notify.yaml` `ntfy-erik-password` |
| `agents` | write-only       | tokens `machines` (dotfiles `ntfy-agents-token`) and `executor` (Executor app account) |
| `alerts` | write-only       | token `alertmanager`; k8s secret `alerts-ntfy`         |
| `time`   | write-only       | token `time`; k8s secret `time-ntfy` (focus nudges)    |

To change them: decrypt `secrets/ntfy.enc.yaml`, edit `NTFY_AUTH_USERS`
(`name:bcrypt:user`, hash with `ntfy user hash`) or `NTFY_AUTH_TOKENS`
(`name:tk_<29 chars>:label`), encrypt again. The ACL is in `server.yml`.

## Phone setup

None. Erik does not use the ntfy app (decided 2026-10-21); delivery is
Discord, and next the T3 Code app itself. The `erik` user stays for testing
with the ntfy app on an emulator.

## Rate limits

The senders limit themselves (see the `notify` skill in the dotfiles). The
server's `visitor-message-daily-limit: 150` per client address is only a
backstop against a sender gone wrong.

## Health

Gatus `phone/ntfy` checks `/v1/health` through the tailnet.

## Sending from a pod (plain HTTP)

Services in the cluster (Time, Alertmanager) publish straight to ntfy with
their own token; no Executor or CLI needed. Mount the secret
(`time-ntfy`, `alerts-ntfy`: keys `NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`)
and POST JSON to the **root** URL:

```sh
curl -H "Authorization: Bearer $NTFY_TOKEN" "$NTFY_URL/" -d '{
  "topic": "erik",
  "title": "45 min on YouTube",
  "message": "Back to the DA2210 homework?",
  "priority": 3,
  "tags": ["time"],
  "click": "https://time.erikfrankling.duckdns.org/",
  "sequence_id": "time-focus-nudge"
}'
```

- `priority`: 2 low (no sound), 3 normal (sound, no pop-up), 4 high (pops
  up), 5 urgent (pops up, long vibration). Nudges: 3. Alerts: 4-5. One-time
  codes use 4 with a `copy` action.
- `click`: any URL; `t3code-preview://threads/<environment>/<thread>` opens a
  T3 thread in Erik's app (the fork's preview build registers only that
  scheme).
- `sequence_id`: a later message with the same id replaces the earlier
  notification instead of stacking. `PUT $NTFY_URL/erik/<id>/clear`
  dismisses it, `DELETE $NTFY_URL/erik/<id>` removes it.
- `actions`: up to 3, e.g. `[{"action":"copy","label":"Copy code","value":"123456"}]`
  or `[{"action":"view","label":"Open","url":"https://..."}]`.
- Each sender limits itself. The server-side `visitor-message-daily-limit`
  (150 a day) counts per client address, so one pod never eats another's
  budget.
