# Observability and incident response

Status: **live since 2026-10-21** on the homelab (this repo). The pc and
framework side (Alloy, health-watch) is in the dotfiles
(`modules/nixos/observability*`, `modules/home-manager/auto-update`).

Every service Erik runs (homelab k3s, the pc, the framework laptop) is
health-checked, its logs and metrics land in one place over OpenTelemetry,
and when something breaks a repair session is already investigating. Erik
hears only about what a session could not fix. One incident is one session.

## Where things are

| What | Where |
|---|---|
| Grafana (read-only without login; Home is the phone view) | https://grafana.erikfrankling.duckdns.org (admin: `secrets/grafana.enc.yaml`) |
| Alertmanager (silences, active alerts) | https://alertmanager.erikfrankling.duckdns.org |
| Prometheus | https://prometheus.erikfrankling.duckdns.org |
| OTLP ingest (pc, laptop, phone; bearer token) | https://otlp.erikfrankling.duckdns.org, in-cluster `http://alloy.homelab:4318` |
| Gatus (up/down from LAN and tailnet) | http://192.168.50.100:18080 |
| Manifests | `apps/{alloy,prometheus,alertmanager,loki,grafana,kube-state-metrics,node-exporter}.yaml` |
| Config, rules, dashboards | `config/{alloy,prometheus,alertmanager,loki,grafana}/` |
| Cluster roles (applied by hand) | `kubernetes/bootstrap/observability-rbac.yaml` |
| Token | `secrets/otlp-ingest.enc.yaml`; same value in dotfiles `secrets/observability.yaml` |

All routes are `lan-only` (LAN and tailnet).

## How an incident flows

1. Something fails: a Gatus check, a Prometheus rule
   (`config/prometheus/homelab.rules.yml`) or a Loki log rule
   (`config/loki/rules.yml`).
2. Every alert carries `severity`, `project` and `session`.
3. `session="true"`: health-watch on the pc polls Alertmanager (and Gatus)
   every 2 minutes and starts one repair session per incident (Sonnet 5.5;
   it escalates hard parts to Opus). Limits: one session an hour, six a day,
   shared with the Gatus checks. If the session gives up it notifies Erik
   with `notify-erik`. Alertmanager also notifies him itself if the alert is
   still firing after 3 hours (priority 4); a group resolved before its
   first send never notifies.
4. `session="false"`: no session can act (the pc itself silent, a check
   still failing after 3 h, Time heartbeats). Erik hears directly: priority
   5 for critical, 4 warning, 3 info.
5. `project="naiaclaw"`: Erik's work project. Alert only, priority 2, at
   most once a day per alert; never a session.

What is watched today:

- **Endpoints:** Gatus, from the LAN and through the tailnet.
- **k3s:** CronJobs whose latest run failed, pods that do not start,
  Deployments short of replicas, pending PVCs, disk, certificate expiry,
  scrape targets.
- **pc / framework:** every systemd unit (system and user) that fails,
  localhost-only health endpoints (local-stt and others), disk, the pc
  going silent.
- **Error logs:** dictation (local-stt `*_failed` / `.error` events,
  tracebacks) and the T3 Code server (`ERROR`/`FATAL` lines).
- **Time:** device heartbeats and the export queue (low priority, never a
  session).

## Testing the alerts

A real failure end to end (k8s Job -> kube-state-metrics -> Prometheus ->
Alertmanager -> ntfy), no repair session. Arrives in about 2 minutes as
"Alert pipeline test"; the "Resolved" message follows when the Job removes
itself after 15 minutes.

```sh
ssh naiaclaw 'cat <<EOF | sudo kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: alert-e2e-test-$(date +%s)
  namespace: homelab
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 900
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: fail
          image: docker.io/library/busybox:1.37
          command: ["sh", "-c", "exit 1"]
EOF'
```

Validate before pushing: `promtool check rules`, `amtool check-config`,
`amtool config routes test --config.file=... session=true severity=warning`,
`loki -verify-config`, `alloy fmt` (binaries from the pinned images:
`crane export <image> - | tar -x bin/promtool`).

## Operating

- **Planned outage:** `health-watch maintenance MINUTES "reason" [regex]`
  on the pc keeps sessions away; to keep Erik's phone quiet too, add a
  silence in Alertmanager.
- **New service:** a Gatus check (endpoint) and, for a scheduled job,
  nothing more: CronJobs and systemd units are covered by the generic rules.
- **Pitfalls met while building:**
  - `absent_over_time` sees a new or wiped Prometheus as a silent
    machine; the silence alerts wait for `prometheus_tsdb_lowest_timestamp_seconds`
    to be old enough.
  - Loki refuses (500) entries older than the first schema `from` date;
    backfilled pod logs need it far in the past (2024-01-01).
  - Alertmanager 0.34 has no ntfy receiver; it uses a webhook with ntfy's
    own templating (`template=yes&title=...&message=...`).

## Design (as built)

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
  - **to Erik: ntfy** (deployed, docs/notifications.md): a webhook POST of
    JSON to `http://ntfy.homelab.svc`, topic `erik`, with the write-only
    token from Secret `alerts-ntfy` (`NTFY_URL`, `NTFY_TOPIC`,
    `NTFY_TOKEN`). One message when an incident opens; `sequence_id` = the
    alert fingerprint, so "resolved" replaces it. Priority 4–5 (pops up)
    only for things a session cannot fix (host down, disk full, certificate
    failing), 3 otherwise. `click` opens the incident's T3 thread
    (`t3code-preview://threads/<env>/<thread>`).
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
- **Morning check, health-watch and incident sessions** notify through the
  `notify-erik` CLI (pc, framework) or `tools.notify.send` in Executor, so
  they share the rate limits of the `notify` skill with everything else.

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

## Decisions (Erik, 2026-10-21)

1. A new stack owned by this repo, not the hand-applied naiaclaw one.
2. Phone alerts through the self-hosted ntfy (docs/notifications.md).
3. Erik hears only about incidents a session could not fix.
4. Repair sessions share health-watch's limit (1 an hour, 6 a day) and run
   on Sonnet 5.5, escalating hard parts to Opus.
5. Failing naiaclaw work-project jobs: alert only.
6. Window titles stay in the 5-year Loki copy of Time's events.

## Still to do

- Retire the naiaclaw-old stack (namespaces `grafana`, `loki`, `mimir`,
  `alloy`, `monitoring`) once naiaclaw no longer needs its dashboards.
- Backups: the Loki volume (`loki-data`, the raw copy of Time's events) and
  Time's database, off the node, with a restore test. Time v2 does not go
  live before that (docs/backups.md; the Time session owns it).
- The T3 Code fork and local-stt emitting OTLP directly (Time's events, and
  structured error logs instead of matching log lines).
- Tempo, once something emits traces.
