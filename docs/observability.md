# Observability and incident response

Status: **proposal, 2026-10-21.** Only the Gatus metrics and the `lan/llama-swap`
check are live. Everything else below waits for Erik's decisions (end of file).

Goal: every service Erik runs (homelab k3s, the pc, the framework laptop) is
health-checked, logs and metrics land in one place over OpenTelemetry, and
when something breaks Erik gets one push notification and an agent session
is already investigating. One incident is one session.

## What exists today

| Piece | Where | State |
|---|---|---|
| Gatus | `apps/gatus.yaml`, `config/gatus/config.yaml` | In git. Black-box checks from the LAN and through the tailnet. Results in memory only. |
| health-watch | dotfiles `modules/home-manager/auto-update` | Reads Gatus every 2 min, starts a repair session (systems-check skill, "health incident" T3 project) when a check keeps failing. Cooldown 1 h, 6 a day, maintenance windows, headless `claude` fallback. Never notifies Erik. |
| Morning check | same module, 07:00 | One summary per day, as a desktop notification (`notify-send`). Never reaches the phone. |
| Grafana 11.5, Loki 3 (7 d), Mimir 2.16, Alloy, kube-state-metrics, node-exporter | namespaces `grafana`, `loki`, `mimir`, `alloy`, `monitoring` | **Not in this repo.** Applied by hand from the old naiaclaw work project (`naiaclaw-old/monitoring/azure-mirror`). Plaintext admin password, tenant `naiaclaw-local`, Mimir has no retention set, no Alertmanager, no alert rules. Collects k3s pod logs and node syslog only. |
| Tempo, Prometheus, Alertmanager | — | Not present. |
| pc / framework | — | No log or metric shipping. journald only. |

Blind spots, all three of the currently failing things fall in them:

- **Scheduled jobs.** Gatus only probes endpoints. A failing CronJob
  (`homelab/duckdns-updater` had three failed runs, `naiaclaw-system/*-sweep`
  and `*-drain` fail every minute) or systemd timer (pc
  `brand-push-periodic`, failing every 30 min since midnight) is invisible.
- **Error logs.** Nothing reads logs, so a dictation error or a T3 Code
  exception is only found when Erik hits it.
- **Services bound to localhost on the pc** (local-stt on 8781, executor,
  time-agent) cannot be probed from the homelab.

## Design

```
pc, framework:  apps (OTLP) + journald + node/systemd metrics
                  -> local Alloy (disk queue) --OTLP-->
homelab:        Alloy gateway (+ k3s pod logs, kube-state-metrics, Gatus /metrics)
                  -> Prometheus (metrics, rules)  -> Alertmanager -> ntfy -> Erik's phone
                  -> Loki (logs, ruler rules)     ->      ^
pc:             health-watch polls Gatus + Alertmanager
                  -> one T3 session per incident (cooldown, caps, maintenance = silences)
```

### 1. Collection: Alloy everywhere, OTLP in

- **Homelab:** one Alloy, owned by this repo, as the OTLP gateway: a
  Deployment with a PVC, reached at `https://otlp.erikfrankling.duckdns.org`
  (OTLP/HTTP, `lan-only`, so LAN and tailnet: pc, laptop, phone) and
  `http://alloy.homelab:4318` in the cluster. The same Alloy tails k3s pod
  logs through the Kubernetes API (single node, so no DaemonSet) and scrapes
  kube-state-metrics, node-exporter and Gatus `/metrics`. The hand-applied Alloy in namespace
  `alloy` is not the ingest: it runs with `--stability.level=generally-available`
  and keeps its state in `/tmp`, so it cannot hold the persistent queue
  Time needs (below).
- **pc and framework:** `services.alloy` in the dotfiles. It reads journald
  (system and user units, so every service gets central logs without code
  changes), exports node and systemd-unit metrics, and receives OTLP on
  `127.0.0.1:4318` for apps that speak it. It forwards to the gateway with a
  disk-backed queue, so the laptop catches up after being away or asleep.
- **Apps:** T3 Code (fork), local-stt, time-agent, brain and executor emit OTel
  logs and metrics to the local Alloy. Logs must carry a `level` so error
  rules work. Instrumenting the T3 fork happens there, not here.
- **Labels kept small:** `host` (pc, framework, naiaclaw), `service`
  (`service.name`), `level`. No per-request labels.

### 2. Health checks

- **Gatus stays the prober** for things reachable over the network, from
  both vantage points. New services keep getting a check there (see the
  deploy workflow).
- **Localhost-only pc services** get a `/health` probed by the pc's own
  Alloy (`prometheus.exporter.blackbox`), so they show up as metrics
  `probe_success{host,service}`.
- **Jobs:** alert on `kube_job_status_failed` (latest run of a CronJob
  failed) and on `node_systemd_unit_state{state="failed"}` for pc and
  framework units, transient `systemd-run` timers included.
- **Liveness of the laptop** is not a fault: it sleeps. Alert only if its
  Alloy has not reported for 3 days.

### 3. Alerts and incidents

- **Rules live in git**: Prometheus rules for metrics, Loki ruler rules for
  logs (for example: `level=error` lines from `local-stt` or `t3code` in the
  last 10 minutes). Grouped by `service`, so a burst of errors is one alert.
- **Alertmanager** groups, dedupes and silences. It sends:
  - **to Erik: ntfy** (proposal below), one message when an incident opens
    and one when it resolves, `priority=high` only for things a session
    cannot fix (host down, disk full, certificate failing).
  - **to agents: nothing pushed.** health-watch on the pc **polls**
    Alertmanager's API next to Gatus. It already has everything an incident
    engine needs: one session at a time, cooldown, daily cap, maintenance
    windows, a headless fallback when T3 Code itself is down, and clones of
    both repos. The alert's labels, annotations and a Loki query link go into
    the `<health-report>`. Fingerprint = `alertname + service`; a fingerprint
    that already has a session in the last 24 h is not restarted, it is
    appended to that session's thread with `t3_thread_send`.
  - Maintenance windows (`health-watch maintenance ...`) become Alertmanager
    silences, so a planned restart neither pages Erik nor starts a session.
- **Why poll instead of a T3 webhook (`schedule_task` webhook):** no inbound
  port on the pc, nothing that depends on T3 Connect, and the dedupe and rate
  limits stay in one place that is already tested. If the pc is down, ntfy
  still reaches Erik because Alertmanager runs on the homelab, and the
  homelab dying is caught the other way round: health-watch already starts a
  session when Gatus stops answering.
- **Morning check** sends its one summary through ntfy too, so it reaches the
  phone.

### 4. Dashboards and the phone

Grafana stays for digging in. For the phone:

- **ntfy** is the primary phone surface: alerts and the morning summary, with
  a tap-through link to the incident's T3 thread.
- **One "Home" dashboard built for a 400 px screen:** a single column of
  stat panels (every service up/down, failing jobs, disk, open incidents),
  provisioned from git, linked with `?kiosk`. Per-host and per-service
  drill-down dashboards stay desktop-sized.
- The Gatus page (already phone-friendly) stays the "is it up right now"
  view.
- If that still is not pleasant, the next step is a small read-only status
  page served by the brain or Time app from Prometheus' API, not more
  Grafana work.

### 5. Storage, retention and the Time project

The VM root has ~92 GB free of 309 GB (71 % used); local-path does not enforce
PVC sizes, so retention is the only real limit.

| Data | Store | Retention | Size budget |
|---|---|---|---|
| Metrics, infra and activity counters | Prometheus TSDB | 400 d, capped at 25 GB (`retention.size`) | 25 GB |
| Ops logs | Loki | 30 d | 20 GB |
| Activity events, raw copy | Loki, stream `{service_namespace="time"}` | `retention_stream` 5 y | ~1–2 GB over 5 y (screen embeddings dominate) |
| Activity events, classified | Time's own database (Time server) | forever, deduped by `event.id` | Time's PVC |
| Traces | Tempo, only once the T3 fork emits spans | 7 d | 5 GB |

`time_*` and `gen_ai.client.token.usage` are a handful of series, so the
single 400-day metrics retention covers Time's "at least a year".

- Time's database is the **source of truth** for activity (Time proposal,
  `~/projects/personal/time/PROPOSAL.md`). The Loki `time` stream is the
  raw copy Time can rebuild from, so it keeps every attribute, including
  the screen embedding: pixels are discarded on the pc, so a dropped
  embedding could never be recomputed.
- Loki 3 indexes `service.namespace` as the label `service_namespace` by
  default, so the 5-year rule needs no extra label config.
- **Backups are not operational** (docs/backups.md). Activity data is the
  first thing here that cannot be regenerated. Time v2 does not go live
  until the Time database and the Loki volume are backed up off the node
  (B2 CronJobs in `backup/backup.yaml`, plus a restore test).

### The Time pipeline (requirements from the Time redesign, 2026-10-21)

- **Emitters:** T3 Code server (its existing `OTEL_EXPORTER_OTLP_*` export,
  set in the dotfiles `hosts/pc/home.nix`), the local-stt gateway, a voxtype
  hook, the time agent (pc, laptop), the Time Android app, `time collect`.
  pc/laptop processes send to the local Alloy (`127.0.0.1:4318`); in-cluster
  ones to `http://alloy.homelab:4318`.
- **Phone ingest:** the Android app has no local Alloy and keeps its own
  spool. It sends OTLP/HTTP to `https://otlp.erikfrankling.duckdns.org`:
  Traefik route with the `lan-only` middleware (LAN and tailnet), and a
  bearer token checked by the gateway's receiver (`otelcol.auth.bearer`,
  which supports server-side auth; verify on build). The token is a SOPS
  secret here and lives in the app's settings. It is the first
  device-facing endpoint, so it accepts nothing without the token.
- **Routing in the gateway Alloy**, on the resource attribute
  `service.namespace`:
  - metrics → the metrics store.
  - log records with `service.namespace = "time"` go to **both**:
    - Loki, stream `{service_namespace="time"}`, kept 5 years, unmodified;
    - `otelcol.exporter.otlphttp` → `http://time.homelab.svc:7373/v1/logs`
      with `sending_queue { storage = otelcol.storage.file... }` on the
      gateway's PVC, so a Time restart or outage loses nothing; Time
      dedupes by `event.id`. `otelcol.storage.file` is a public-preview
      component: the gateway runs with `--stability.level=public-preview`.
  - everything else → Loki, 30 days.
- **Privacy:** emitters never send prompt text, transcripts or pixels; only
  counts, durations, ids, app/window names, browser hosts and the screen
  embedding. Loki is behind `lan-only` like Time itself, on the same node.
  Open question for Erik: window titles in the 5-year Loki copy (it is the
  rebuild source, so they are kept unless he says otherwise).
- **Health check:** Gatus probes the Time service's `GET /healthz` on port
  7373 (database writable). Data freshness is **not** part of the Gatus
  check: a failing Gatus check starts a repair session, and "no event for
  an hour" is normal every night. Freshness is the alert below instead.
- **Alerts (low priority, ntfy only, no session):**
  - Time server down: the Gatus check, plus the exporter's queue growing.
  - Device silent: every emitter sends `time.heartbeat` (attributes
    `spool.pending`, `app.version`) on each sync; the phone every 15 min
    on Wi-Fi. The Time server, which receives every event anyway, exposes
    `time_device_last_heartbeat_timestamp_seconds{device}` and
    `time_device_spool_pending{device}` on `/metrics`, scraped by the
    gateway Alloy. Alloy cannot turn a log attribute into a gauge cleanly.
    - pc, laptop: no heartbeat for 2 h while that device's Alloy reported
      in the last 10 min.
    - phone: no heartbeat for 2 h, only 08:00–23:00 Europe/Stockholm
      (Android Doze holds syncs overnight). Done with an Alertmanager
      `time_intervals` entry with `location: Europe/Stockholm` as the
      route's `active_time_intervals`, not with PromQL `hour()`, which is
      UTC and breaks at daylight-saving changes.
  - Phone spool growing: `spool.pending` rising for 6 h, so a broken token
    or route shows up before the spool fills.

### OTel conventions for every emitter

- Resource: `service.name` (`t3code`, `local-stt`, `time-agent`, ...),
  `host.name`, `service.version`, and `service.namespace = "time"` on
  activity data (that alone selects the 5-year stream and the Time
  fan-out).
- Event names (`t3.prompt.sent`, `stt.dictation.finished`,
  `time.screen.minute`, `github.commit`, ...) and their attributes are owned
  by the Time proposal.
- Metrics: low-cardinality attributes only (`provider`, `model`,
  `input_mode`, `host`). Thread ids, SHAs and similar go on log events.

## What happens to the naiaclaw-old stack

It keeps running untouched until the new stack works, since it backs the
OpenClaw/naiaclaw dashboards. After that Erik decides whether naiaclaw still
needs it. If not, `helm uninstall` (Flux HelmReleases `alloy`, `grafana`,
`loki`) and the Mimir StatefulSet go, and their PVCs with them.

## Rollout

1. *(done)* Gatus `metrics: true`; `lan/llama-swap` check.
2. Homelab: Prometheus + Alertmanager + Loki + Grafana + Alloy gateway + ntfy
   in namespace `homelab`, all from this repo. Cluster-scoped RBAC for Alloy
   goes in `kubernetes/bootstrap` (applied once; the Flux reconciler cannot
   create it). Grafana admin password via SOPS.
3. Alert rules for: Gatus checks failing, CronJob latest run failed, systemd
   unit failed, pod crash-looping, disk > 85 %, certificate < 20 d.
   Test cases: duckdns-updater, the naiaclaw sweeps, `brand-push-periodic`.
4. Dotfiles: Alloy on pc and framework; health-watch reads Alertmanager;
   morning check and incident open/close go to ntfy.
5. Error-log rules for local-stt and t3code; the Time routing above once Erik
   approves Time; then the T3 fork and local-stt
   emit OTel directly (with the Time project's events).
6. Phone dashboard; retire the old stack.

## Decisions for Erik

1. **Own stack in this repo** (recommended) or adopt the hand-applied naiaclaw
   one?
2. **Phone push: self-hosted ntfy** (recommended; on the homelab behind the
   tailnet, with ntfy.sh only as the wake-up relay, so message text never
   leaves the house) or email?
3. **What reaches Erik:** every incident (open and resolved), or only what a
   session could not fix?
4. **Error-log sessions cost tokens:** keep the current cap (one session an
   hour, six a day, shared with health checks) or a separate budget?
5. **Which naiaclaw failures count:** the naiaclaw-system jobs are a work
   project. Alert Erik, start sessions in that repo's T3 project, or ignore?
6. **Window titles in the 5-year Loki copy of Time's events:** keep them
   (recommended; Loki is the rebuild source and sits behind the tailnet like
   Time) or strip them there and accept that a rebuild loses them?
