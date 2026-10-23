# Agent worker: heavy work off Erik's PC

`kubernetes/homelab/apps/agent-worker.yaml` runs one pod where the agents on
Erik's PC do anything long-running or CPU/IO-heavy: builds and test suites,
Gradle/APK builds, the one Android emulator, embeddings and other batch jobs.
Policy since 2026-10-21: the PC is for Erik plus light agent work; heavy work
runs here even though it is slower, because swap and disk IO on the PC froze
his desktop.

The PC side is the `heavy` command (dotfiles,
`modules/home-manager/heavy`). It rsyncs the current repository to
`/work/<repo>-<hash>/` here and runs a command in it over SSH, inside the
repository's `nix develop` shell when its flake has one.

## How it fits together

| Piece | Where | What it does |
|---|---|---|
| `seed` (init) | `nixos/nix` image | Substitutes nix, sshd, rsync, git, adb and friends into the volume from one pinned nixpkgs (`--max-jobs 0`) |
| `worker` | port 2223 on the VIP, LAN only | sshd for `heavy`; jobs run as root against the pod's own `/nix/store` |
| `/work` | `/nix/var/worker/work` on the volume | One workspace per repository; build outputs and `node_modules` stay between runs |
| caches | `/nix/var/worker/home/{.gradle,.cache,.npm,...}` | Linked into `/root` so Gradle and pnpm reuse them |
| emulator | `config/agent-worker/heavy-emulator.sh` | API 36 google_apis x86_64 (the T3 Code fork's image), headless, KVM |

Substituters: the homelab cache first (it holds the PCs' closures, so a
devShell on the dotfiles' nixpkgs comes from the LAN), then cache.nixos.org and
the same caches as nix-builder. Unfree is allowed (Android SDK).

## Keeping it away from everything else

- **Memory:** limit 20 GiB (one release APK build peaks near 10 GB, the emulator takes 4), request 256 MiB. That is the smallest request of
  any heavy pod, so under node pressure this pod is evicted and OOM-killed
  before nix-builder and the services.
- **CPU:** no request and no limit, so it gets the smallest share under
  contention. `max-jobs = 2`, `cores = 4` for Nix builds here.
- **Disk:** same node disk as nix-builder. `min-free` = 115 GiB, so it collects
  before nix-builder (110 GiB). An hourly janitor removes workspaces untouched
  for 7 days, then the oldest while the disk has under 35 GiB free; a workspace
  with a running job is never touched. Devshells are rooted (`nix develop
  --profile <workspace>/.heavy/shell-NAME`) so collection keeps them.
- **Emulator:** one at most. It stops itself after 30 minutes with no adb
  client, and when the pod stops.

## Access

Only the key in `config/nix-builder/authorized_keys` (shared with the builder
through the ConfigMap) can log in, as root, into a privileged container.

```bash
ssh -p 2223 root@192.168.50.100 bash /config/heavy-status.sh
```

Gatus checks the SSH port (`lan/agent-worker-ssh`).

## Emulator

`heavy emulator start` on the PC runs `heavy-emulator.sh start` here: one
pixel_7 AVD (1080x2400, API 36 google_apis x86_64, the T3 Code fork's image),
headless with KVM. The first run fetches the SDK and system image into this
store (a few GB). The emulator runs in this pod, so `heavy` commands share its
network: their `adb` sees it as the only device (`emulator-5554`), and it
reaches their servers at `10.0.2.2`. This pod's adb server owns it. The PC
reaches that server through an SSH tunnel to `127.0.0.1:5037`, at
`ADB_SERVER_SOCKET=tcp:127.0.0.1:15037` (or `heavy adb ...`). It stops itself
after 30 minutes with no heavy job and no adb client.

## Background jobs

`heavy bg NAME -- CMD` (`config/agent-worker/heavy-bg.sh`) runs a job that
outlives the SSH connection, e.g. a server for the emulator. Its log and pid
live in `<workspace>/.heavy/`. `heavy forward PORT` tunnels a worker port to
the PC.

## Scheduling and limits

`scripts/heavy-run.sh` admits one **big** job at a time (Gradle, Expo, APK
builds, anything driving the emulator; guessed from the command or the script
it runs, or `heavy --big`) with up to 10 GiB, and one **small** job with up to
3 GiB, which may borrow the big slot while no big job waits. Others queue in
order (`/work/.queue`). `cgroups.sh` splits the container's cgroup into
`jobs/` (13 GiB, 4 cores, one `job-<pid>/` per job with `memory.oom.group`),
`emulator/` (5.5 GiB, 2 cores), `light/` (768 MiB) and `system/`. The caps add
up to less than the 20 GiB pod limit, so an OOM kills only the job that caused
it. (Kubernetes sets `memory.oom.group` on the container itself: before this,
one job over the limit killed the whole pod, emulator included.) Because the
container's own cgroup now hands its controllers to children, `kubectl exec`
into it fails; use SSH.

## Changing it without killing jobs

Everything under `config/agent-worker/scripts/` is the `agent-worker-scripts`
ConfigMap, which has no content hash and is mounted at `/scripts`. Edits reach
the running pod within about a minute, with no restart. `/config/heavy-*.sh`
are fixed shims. Changing anything else in `config/agent-worker/` (entrypoint,
cgroups, sshd, nix.conf, seed) or the Deployment restarts the pod and kills
every job and the emulator. Check `heavy status` first and warn the agents
using it.

## Services, secrets and the queue estimate

- `heavy bg NAME -- CMD` is a **service** by default: no job slot, its own
  1 GiB cgroup in the 1.5 GiB `service/` pool (CPU weight 10, 2 cores), at
  most 3 at once. It stops itself after 3 hours without CPU use, and when the
  emulator it was started with stops. `heavy bg --big/--small` makes a batch
  job that takes a slot instead.
- `heavy -e VAR[=VALUE]` sends values in a one-shot 0600 file
  (`/work/.envs/`), read into the job's environment and deleted at once, so
  they are in no command line. The queue, slot files and `heavy status` show
  commands redacted (`VAR=***`, `--token ***`).
- A waiting job prints its position and an estimated wait from the median of
  the last ten job durations per class (`/work/.stats/`), and points at
  `when-idle` on the PC.

## The emulator holds the big slot

An emulator next to a Gradle build starved (System UI ANRs, Bluetooth gone,
failed tests). `heavy emulator start` now queues for the big slot like a big
job (a holder runs `heavy-emulator.sh boot` through `heavy-run.sh` in
`/work/.emulator`) and keeps it until `heavy emulator stop` or 30 idle
minutes. Big jobs whose command or script mentions adb or the emulator run
inside that reservation (`/work/.slots/shared/`); other big jobs wait, and
their queue message says the emulator holds the slot. The emulator runs at
normal priority in its own cgroup.

## Emulator audio and gRPC

The emulator starts with `-allow-host-audio -grpc 8554`. It plays into a
PulseAudio null sink in the pod (`/run/heavy-pulse`), and its gRPC
EmulatorController on `127.0.0.1:8554` streams what it plays (`streamAudio`)
and feeds the microphone (`injectAudio`; start that only after the app has
opened its recorder, or the emulator can crash). Jobs get
`EMULATOR_GRPC_PORT=8554`, `emulator-python` (python with grpcio,
grpcio-tools, protobuf) on PATH, and `ANDROID_SDK_ROOT` pointing at an SDK
with `emulator_controller.proto` when they bring none. Read aloud's
`scripts/voice-e2e/android/emulator_audio.py` (t3code-voice-v2) runs as
`emulator-python scripts/voice-e2e/android/emulator_audio.py capture 8554 out.wav 10`.
From the PC, `heavy emulator start` also tunnels 8554.

## Housekeeping and caches

`scripts/housekeeping.sh` runs at most hourly (started by `cgroups.sh`):
workspaces untouched for 3 days are deleted, then the least recently used
while all of them use more than 15 GB (never one with a running job),
the caches in `/nix/var/worker/home` (linked into `/root`: `.gradle`, `.cache`
for pip/uv, `.local` for the pnpm store, `.npm`, `.cargo`, `.bun`,
`.android`) are pruned to size budgets by least recent use, old devShell
profile generations go, and dead store paths are collected while the node has
under 45 GB free. Log: `/nix/var/worker/housekeeping.log`.
