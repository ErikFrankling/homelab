# Phone notifications (T3 app push, Discord, ntfy backbone)

Erik's phone gets notifications as **native pushes in his T3 Code app** (FCM,
sent by the T3 server on his PC) with a copy in #notifications of his private
Discord server "Agents" (silent when the push went out, loud when it did not).
He installs nothing else. Agents use the Executor app `notify` or the
`notify-erik` CLI (dotfiles, `notify` skill). **Services in the cluster use
notify-gateway** (below). Every agent send is also mirrored to the ntfy server
below; publishing to ntfy alone does not reach the phone. Alertmanager
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
| `time`   | write-only       | token `time`; unused (Time sends through notify-gateway) |

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

## Sending from a pod: notify-gateway (reaches the phone)

Services in the cluster notify Erik through `notify-gateway`
(`apps/notify-gateway.yaml`, code `config/notify-gateway/server.mjs`). It
delivers like the agents' `notify`: a native push in the T3 Code app (through
the T3 server on the PC) and a copy in Discord #notifications, silent when the
push went out. It reaches only Erik: the Discord copy never mentions anyone.
Cluster-internal, no route.

```sh
curl -H "Authorization: Bearer $NOTIFY_TOKEN" -H "Content-Type: application/json" "$NOTIFY_URL" -d '{
  "title": "45 min on YouTube",
  "message": "Back to the DA2210 homework?",
  "priority": "normal",
  "url": "https://time.erikfrankling.duckdns.org/",
  "tag": "focus-nudge"
}'
# 200 {"sent":true,"app":true,"discordMessageId":"..."}
# 429 {"sent":false,"reason":"3 in the last hour"}  -> do not retry
```

- `NOTIFY_URL` is `http://notify-gateway.homelab.svc/v1/notify`. Each source
  has its own token and secret: Time mounts `time-notify` (`NOTIFY_URL`,
  `NOTIFY_TOKEN`). To add a source, add it to `NOTIFY_SOURCES` in
  `secrets/notify-gateway.enc.yaml` (`{"name": {"token": "...", "perHour":
  3, "perDay": 8}}`) and give it a secret like `time-notify`.
- `priority`: `normal` (sound) or `low` (silent). Sources get no urgent,
  high or code; those belong to agents and alerts.
- Tap target: `url` (http(s)) or `thread: {environmentId, threadId}` (opens
  the T3 thread).
- `tag`: a later send with the same tag replaces the earlier notification
  (same push id on the phone; the Discord copy is deleted and reposted).
- Limits per source (Time: 3 an hour, 8 a day), and the same title and
  message within 15 minutes is refused. Limits live in memory: a pod restart
  resets them. A failed delivery (502) does not use budget.

## Publishing to ntfy only (does not reach the phone)

Services can also publish straight to ntfy with their own token; that is a
mirror, not a notification. Mount the secret
(`alerts-ntfy`: keys `NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`)
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
