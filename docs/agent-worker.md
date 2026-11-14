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

- **Memory:** limit 24 GiB on the running pod, 20 GiB in the manifest until the
  next restart (see "Pod limit"); one release APK build peaks near 10 GB, a
  small job up to 6, the emulator takes 4; request 8 GiB. Under node pressure earlyoom
  (`ops/earlyoom/install.sh`) kills nix-builder's processes before this pod's.
- **CPU:** no request and no limit, so it gets the smallest share under
  contention. `max-jobs = 2`, `cores = 4` for Nix builds here.
- **Disk:** same node disk as nix-builder. Hourly housekeeping collects dead
  store paths when the disk has under 155 GiB free. `min-free` (90 GiB, before
  nix-builder's 80) is only an emergency backstop: at 155 GiB every
  `nix develop` in every job ran its own full GC and waited on the GC lock. An
  hourly janitor removes workspaces untouched for 3 days, then the least
  recently used ones while all workspaces together use more than 15 GB (never
  one with a queued or running job; see "Housekeeping and caches"). **A
  workspace is disposable: anything that must survive between runs and is not
  in the repository belongs in `$HEAVY_BAZEL_DIR` or a cache under `$HOME`
  (see "Bazel"), not in `/work`.** Devshells are rooted (`nix develop
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
6 GiB (3 GiB until 2026-11-14, when `cargo test -p wbox` jobs, 3 to 5 GiB,
were killed at the cap), which may borrow the big slot while no big job waits. Others queue in
order (`/work/.queue`); `heavy --priority` (`HEAVY_PRIORITY=1`) gives a job a 30-minute
head start in its class's queue: it passes ordinary waiters that joined less
than 30 minutes before it, never one that has waited longer, and never
interrupts the running job. For a shared job many sessions wait on. A head
start rather than the front of the queue, because two priority jobs that
re-queue each other (wasm-box's builder and tests job, 2026-11-13) otherwise
keep the big slot forever. `cgroups.sh` splits the container's cgroup into
`jobs/` (16 GiB, 4 cores, one `job-<pid>/` per job with `memory.oom.group`),
`emulator/` (5.5 GiB, 2 cores), `service/` (1.5 GiB) and `system/`. The caps add
up to less than the 24 GiB pod limit, so an OOM kills only the job that caused
it. The jobs pool is sized from the container's actual limit (limit minus the
other pools minus 512 MiB, at most 16 GiB): a pod that runs with 20 GiB gets
12.8 GiB, never a pool that lets the container hit its limit and die whole.
A big and a small job at full size together (10 + 6) fill the pool; then the
kernel kills one of them. The jobs pool's 4-core quota is what a job's speed
depends on: on 2026-11-14 it was throttled in 72 % of its periods, and the
node itself (4 cores, 8 threads) averaged 74 % busy over 7 days, so a second
small slot would only split the same 4 cores. (Kubernetes sets `memory.oom.group` on the container itself: before this,
one job over the limit killed the whole pod, emulator included.) Because the
container's own cgroup now hands its controllers to children, `kubectl exec`
into it fails; use SSH.

## Exclusive cores (`heavy --cpus N`)

For latency-sensitive benchmarks (wasm-box's Firecracker restore and vsock
round trips, 2026-11-13), which cannot get a quiet machine on the PC.
`scripts/cores.sh` makes the job's cgroup a cgroup-v2 *remote partition* of
type `root` over the top N vCPUs (N at most half the node: 1 = `7`, 2 = `6-7`,
4 = `4-7`): every ancestor up to the node root gets the list in
`cpuset.cpus.exclusive`, and the kernel removes those CPUs from every other
cgroup on the node, including system.slice, k3s, every other pod, the
emulator and cgroups created during the run. Device IRQs and the unbound
workqueue cpumask move off them for the run (saved in
`/nix/var/worker/irq-affinity`). Per-CPU kernel threads and the few IRQs the
kernel manages itself stay. The job runs at nice 0, and the `jobs/` pool's
4-core quota is lifted while it runs so the other jobs cannot throttle it.

- One pinned job at a time (`/work/.slots/cpus`, taken before the slot queue);
  it still holds a big or small slot for its memory.
- The job cgroup becomes the partition before the job enters it, and a job
  that cannot get it does not start (exit 96).
- `HEAVY_CPUS` (the CPU list at start) and `HEAVY_CPUS_EXCLUSIVE` (1/0) are
  in every job's environment, for provenance.
- Release: after the job (stragglers are killed with `cgroup.kill`), and
  `cgroups.sh` runs `cores.sh sweep` before every job, which undoes what a job
  that died left behind (exclusive lists, IRQ masks, the quota).
- Kernel 6.8 computes an empty exclusive set at levels whose `cpuset.cpus` is
  empty, so `pin` writes the full CPU list into the levels between
  kubepods.slice and the job. That is what they inherit anyway.
- These are the k3s VM's vCPUs. Proxmox floats them over the i7-6700K's 8
  threads (4 cores with hyperthreading) without pinning, and the host itself
  is nearly idle (it only routes Tailscale), so the cores are quiet but not
  fixed physical cores, and a pinned vCPU can share a physical core with
  another vCPU's hyperthread.

## Pod limit: resized in place, manifest pending (2026-11-14)

Any edit of the Deployment (`strategy: Recreate`) restarts the pod and kills
every job, and the queue is never empty. So the limit went from 20 to 24 GiB on
the running pod without a restart, with Kubernetes 1.35's in-place resize:

```bash
sudo kubectl -n homelab patch pod POD --subresource resize --patch \
  '{"spec":{"containers":[{"name":"worker","resources":{"limits":{"memory":"24Gi"}}}]}}'
```

`apps/agent-worker.yaml` still says `20Gi`. Change it to `24Gi` (and
`WORKER_SMALL_MEMORY` to `6G`) in the same push as the next change that
restarts the pod anyway (an image update, a new env var), or when `heavy
status` shows nothing running. Until then a restart brings the pod back with
20 GiB, and `cgroups.sh` sizes the jobs pool down to fit (12.8 GiB), so
nothing breaks, only a big and a small job at full size can again kill each
other.

## Changing it without killing jobs

Everything under `config/agent-worker/scripts/` is the `agent-worker-scripts`
ConfigMap, which has no content hash and is mounted at `/scripts`. Edits reach
the running pod within about a minute, with no restart. `/config/heavy-*.sh`
are fixed shims. Changing anything else in `config/agent-worker/` (entrypoint,
cgroups, sshd, nix.conf, seed) or the Deployment restarts the pod and kills
every job and the emulator. Check `heavy status` first and warn the agents
using it.

## When a job ends with status 255 and no message

That is the SSH connection between `heavy` on the PC and the worker going away,
which also kills the job (see the top of `scripts/heavy-run.sh`). Until
2026-11-02 every `heavy` client shared one SSH master, which lived in the cgroup
of whichever session or job connected first, so a session ending dropped every
job at once. Masters are now per cgroup (dotfiles, `modules/home-manager/heavy`).
The sshd log in this pod (`kubectl logs`) says whether the worker saw a timeout;
`journalctl --user` on the PC shows what stopped in the milliseconds before.

Nothing in the queue loop may be able to fail fatally: a bash arithmetic syntax
error abandons the whole top-level `if` around the loop, which used to start
the job without a slot. A job that leaves the queue without a slot now exits 98
instead of starting.

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
for pip/uv, nix and Fleet's cargo builds, `.local` for the pnpm store, `.npm`,
`.cargo`, `.bun`, `.android`) are pruned to size budgets, old devShell
profile generations go, and dead store paths are collected while the node has
under 155 GB free. Log: `/nix/var/worker/housekeeping.log`.

A cache is removed whole, one entry at a time (`.cache/fleet-build`,
`.cache/nix`, `.local/share/pnpm`, `.gradle/caches/modules-2`, ...), least
recently used first, and never one used in the last 2 days. Until
2026-11-07 it deleted single files by atime plus every empty directory. That
broke Fleet's builds every hour: unpacked crate sources keep their archive's
1970/2006 atime, so cargo found crates marked complete with files missing
("can't find dotenvy bin", "no targets specified"), and nix's tarball-cache
git repository lost its empty `refs/` ("could not find repository"). Pruning
holds both job slots while it removes anything, because housekeeping starts
when a job does; while a job runs it waits for the next hour.

## Bazel: a persistent output root and disk cache (2026-11-14)

Why: on 2026-11-14 the 06:22 UTC housekeeping run logged `removing workspace
/work/t3-edceb705-... (workspaces use 62G > 15G; least recently used)`. The
workspace held a Bazel output root with V8 objects (about 20 GB, 7.3 h of
small-slot time). It was the 15 GB budget for all workspaces, not the 3-day
rule, not the pod restart (`/work` is on the persistent volume, restarted at
04:22 UTC, hours before) and not that morning's memory change.

Where: `/nix/var/worker/bazel/` on the volume, outside `/work` and outside
`.cache`, so neither the workspace budget nor the cache pruning touches it:

| Path | What |
|---|---|
| `/nix/var/worker/bazel/root` | `--output_user_root`: install base and one output base per workspace path (the V8 objects) |
| `/nix/var/worker/bazel/disk-cache` | `--disk_cache`: content-addressed, reusable whatever the workspace path |
| `/nix/var/worker/bazel/heavy.bazelrc` | both flags in one rc file, rewritten by `cgroups.sh` on every job |

Using it: every `heavy` job has `HEAVY_BAZEL_DIR` (the directory) and
`HEAVY_BAZEL_RC` (the rc file) in its environment. Either call
`bazel --bazelrc=$HEAVY_BAZEL_RC build ...`, or put
`try-import /nix/var/worker/bazel/heavy.bazelrc` in the project's `.bazelrc`
(a missing file is ignored, so it does no harm off the worker), or pass
`--output_user_root=$HEAVY_BAZEL_DIR/root` and
`--disk_cache=$HEAVY_BAZEL_DIR/disk-cache` yourself. An output base is named
after the workspace path (`/work/<repo>-<hash>`, stable for one directory), so
a re-synced workspace finds its objects again; the disk cache needs no such
luck.

Eviction (`prune_bazel` in `housekeeping.sh`):

- Budget 30 GB for the whole directory (`HEAVY_BAZEL_BUDGET_MB`). Over it,
  housekeeping prunes down to 24 GB: first disk-cache files, least recently
  used first (newest of atime and mtime), then whole output bases the same
  way, skipping one with a live Bazel server (`server/server.pid.txt`). Nothing
  used in the last 2 days goes.
- **Never while a job that uses Bazel is queued or running.** Such a job
  holds a shared `flock` on `/work/.slots/bazel` from the moment `heavy-run.sh`
  starts until it ends (queue wait included); the prune takes the exclusive
  one without waiting and skips this hour if it cannot. A job counts as using
  Bazel when its command or the script it names mentions `bazel`/`bazelisk`,
  when `heavy -e HEAVY_BAZEL=1` says so, or when its directory holds a
  `MODULE.bazel`, `WORKSPACE`, `WORKSPACE.bazel` or `.bazelversion` within
  three levels (not under `node_modules` or `target`). A script that calls
  Bazel two levels down, from a directory without those files, needs
  `-e HEAVY_BAZEL=1`.
- Consequence: the budget is soft. While Bazel jobs are always queued the
  directory can grow past 30 GB; the node's disk is 697 GB with 133 GB free
  (2026-11-14), so watch `du -sh /nix/var/worker/bazel` and `heavy status`'s
  disk line.
- A prune holds the exclusive lock for a few minutes at most; a Bazel job
  that starts then waits for it, up to 30 minutes.

Not changed: the other cache prunes (`.gradle` 10 GB, `.cache` 20 GB, ...)
wait for a moment with no job running and the log shows them skipped every
hour ("a job is running, pruning next time"). Gradle's caches are at 14 GB
against 10.
