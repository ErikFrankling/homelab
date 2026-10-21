# Phone notifications (ntfy)

Agents, scripts and alerting reach Erik's phone through a self-hosted
[ntfy](https://ntfy.sh) server: `apps/ntfy.yaml`, settings in
`config/ntfy/server.yml`, users and tokens in `secrets/ntfy.enc.yaml`.

```
agent (any harness) --tools.notify.send--> Executor app `notify` --+
pc/framework scripts --notify-erik CLI-----------------------------+--> ntfy topic `erik`
Alertmanager (planned, docs/observability.md) --token `alerts`-----+        |
                                                                            v
                         ntfy Android app (instant delivery, websocket) on Erik's phone
                         tap -> t3code://threads/<environment>/<thread> opens the T3 thread
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
| `alerts` | write-only       | token `alertmanager`, for Alertmanager                |

To change them: decrypt `secrets/ntfy.enc.yaml`, edit `NTFY_AUTH_USERS`
(`name:bcrypt:user`, hash with `ntfy user hash`) or `NTFY_AUTH_TOKENS`
(`name:tk_<29 chars>:label`), encrypt again. The ACL is in `server.yml`.

## Phone setup

ntfy app (Play Store, F-Droid, or Obtainium from
`github.com/binwiederhier/ntfy-android` releases, `play` APK) -> Settings ->
Users -> add `https://ntfy.erikfrankling.duckdns.org`, user `erik`. Then
subscribe to topic `erik` on that server with **instant delivery** on. In the
topic's settings, let priority 5 override Do Not Disturb if wanted.

## Rate limits

The senders limit themselves (see the `notify` skill in the dotfiles). The
server's `visitor-message-daily-limit: 150` per client address is only a
backstop against a sender gone wrong.

## Health

Gatus `phone/ntfy` checks `/v1/health` through the tailnet.
