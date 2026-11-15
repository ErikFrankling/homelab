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

## When the checkout is copied: at submission, not at start

**`heavy` copies the checkout when the job is submitted (when you run
`heavy ...`), not when the job starts.** The sequence is: rsync the checkout to
`/work/<repo>-<hash>/`, then queue the job. A job can wait for an hour or more;
**edits you make to your checkout while it waits are not on the worker and do
not run.** Briefs that said "syncs at start" were wrong. Spelled out:

- The job runs on the worker's copy, as it is when the job starts. That copy is
  the result of the last sync into that workspace by anyone, not a snapshot
  taken at submission: another `heavy` call from the same checkout (the same
  directory, so the same `/work/<repo>-<hash>/`) syncs again and changes the
  files a waiting job will use. A job queued before your edit runs your edit if,
  and only if, some later `heavy` call (or `heavy sync`) from that checkout
  synced it before the job started.
- **Re-running the same command syncs again, then re-attaches to the job
  already queued or running for it** (see "Jobs that survive their client").
  The queue place is kept and the files are refreshed, which is how to get an
  edit into a job that is already waiting: run the same `heavy ...` command
  again. Without the sync (`--no-sync`) nothing is copied.
- `heavy sync` only copies, without queueing anything. `--no-sync` skips the
  copy (rerun on what the worker already has).
- What is copied: the files git would show (tracked plus untracked, minus
  everything ignored), not `.git`; in a directory that is not a repository,
  everything but `node_modules`, `.direnv`, `result*`, `.venv`, `.gradle`.
  Files a job built on the worker (`target/`, `node_modules`) stay between
  runs.
- A job that is already running is not affected by later syncs of files it has
  already read, but one that reads files late in its run (a test suite that
  opens fixtures as it goes) can see a mix of old and new.

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

## Jobs are root; unprivileged steps (2026-11-14)

What a job is: uid 0, gid 0, no supplementary groups, `CapEff` 000001ffffffffff
(every capability), identity `uid_map`, inside a **privileged** container. So
it is real root on the node, not rootless (see "Access": whoever holds the key
has root on the node, as with nix-builder). Root never gets EACCES, so a test of
a permission check passes for the wrong reason (a wasm-box test that expects
EACCES passed its mutation only because of this).

Two ways to get an unprivileged process, both `setpriv` plus the container's
`nobody` user (uid/gid 65534, no groups, no capabilities); the build, `nix
develop` and the caches stay root:

- **One step of a root job:** every job has `HEAVY_UNPRIV`, a command prefix
  (`setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=... TMPDIR=...`),
  and `HEAVY_UNPRIV_TMP`, a directory nobody owns that is its `HOME` and
  `TMPDIR`. Use it unquoted before the command:
  `cargo test --no-run && $HEAVY_UNPRIV ./target/debug/deps/wbox-1a2b3c --test-threads=1`.
- **The whole command:** `heavy -e HEAVY_USER=nobody -- CMD` runs CMD as nobody
  (`nix develop` around it is still root). Also sets the job's umask to 022 and
  opens the workspace for reading (`chmod o+rX`, a find over the tree, about
  0.1 s per 20000 files). `HEAVY_USER=root` is the default. A job that uses the
  emulator or adb stays root.

What nobody can and cannot do: read the workspace and the Nix store; write only
its own `TMPDIR`/`HOME` (a fresh directory in the job's temp dir, removed with
the job). It cannot write the workspace, the caches (cargo, npm, Gradle,
Bazel), `/work/.slots` or the Nix store, so it cannot build; `cargo test`
compiles into `target/`, so compile as root (`cargo test --no-run`) and run the
test binaries as nobody. Locks are taken by `heavy-run.sh` as root, so the
queue, the slots and the Bazel lock work as before.

Readability: jobs run with umask 077, so what a root job builds is unreadable
to nobody. Either `heavy -e HEAVY_UMASK=022 -- CMD` (the job's umask; directories
and files built earlier with 077 stay as they are) or `chmod -R o+rX target`
before the step. `HEAVY_USER=nobody` does the second for the whole workspace.

Not the default (`default_user=0` in `heavy-run.sh`): everything that writes
the workspace or a cache, calls `nix` or uses adb would break, and only
permission-dependent tests gain. A full unprivileged user for the whole job
(own uid with the workspace, the caches and Bazel handed to it, a Nix daemon in
its own cgroup so `nix` works inside) was drafted and dropped as more than the
first need.

### User namespaces with subordinate ids, and a delegated cgroup (2026-11-14)

For a test that needs an unprivileged user with `/etc/subuid` ranges and
`newuidmap` (wasm-box's isolate-tier jail): `heavy -e HEAVY_USERNS=1 -- CMD`.
Opt-in; the job still runs as root, with these added:

| What | Value |
|---|---|
| User | `heavytest`, uid 20000, gid 20000, no groups, no home on disk. Not 65534: `nobody` owns nothing and has no ranges |
| Subordinate ids | `heavytest:2000000:131072` in `/etc/subuid` and `/etc/subgid` (2000000 to 2131071). The `nixbld1..16` users hold 100000 to 1148575, uid 65534 and the nixbld ids 30000s are outside both; `heavy-userns.sh` refuses to write a range that overlaps another |
| `newuidmap`, `newgidmap` | setuid root in `/usr/local/bin`, from the pinned nixpkgs' `shadow` (the image has no `uidmap` package) |
| Prefix | `$HEAVY_UNPRIV_NS` (like `$HEAVY_UNPRIV`, as heavytest) and `$HEAVY_UNPRIV_NS_TMP` (its `HOME` and `TMPDIR`, owned by it) |
| Facts as env vars | `HEAVY_USERNS_USER`, `HEAVY_USERNS_UID`, `HEAVY_USERNS_GID`, `HEAVY_USERNS_SUBID_START`, `HEAVY_USERNS_SUBID_COUNT` |
| Cgroup | `$HEAVY_CGROUP_DELEGATED`, owned by heavytest for this job; `$HEAVY_CGROUP_JOB` is its parent |

`HEAVY_USER=test` runs the whole command as heavytest (workspace readable, not
writable, umask 022, as for `nobody`) and implies `HEAVY_USERNS=1`.

Declared, not edited by jobs: `scripts/heavy-userns.sh` (run by `heavy-run.sh`
before such a job, idempotent, under a lock) creates the user, the ranges and
the two setuid binaries. The container's `/etc` and `/usr/local/bin` are lost
on a pod restart and `seed.sh`/`entrypoint.sh` are in a hashed ConfigMap
(editing them restarts the pod and kills every job), so this is a script in the
unhashed one, applied at the first job that asks for it. The store path of
`shadow` is rooted at `/nix/var/worker/suid/shadow`, so only the first time
ever downloads anything (a 1 MB man output, 2026-11-14).

The cgroup path is `/sys/fs/cgroup/kubepods.slice/.../cri-containerd-<container id>.scope/jobs/job-<pid>/delegate`
(`service/` for a `heavy bg` style class). The container id changes with every
pod restart, and so does the pid: always use `$HEAVY_CGROUP_DELEGATED`. Why
two directories: in cgroup v2 a cgroup with processes cannot enable controllers
for its children, so the job's processes run in `job-<pid>/main` and
`job-<pid>/delegate` is empty with `cpu memory pids` enabled for its children.
The user owns `delegate`, its `cgroup.procs`, `cgroup.subtree_control` and
`cgroup.threads`, and `job-<pid>/cgroup.procs`: moving a process from `main`
into `delegate/x` needs write access to the common ancestor's `cgroup.procs`
(the kernel still only lets it move processes it owns). A test makes children
with `mkdir`, sets `memory.max`, `cpu.max`, `pids.max` on them and moves its
processes in. Memory stays capped by the job cgroup (6 GiB small, 10 GiB big:
a child's own `memory.max` kills inside that child, not the whole job; the job
cap still kills the whole job). The pool directories `jobs/` and `service/` are
now 755 for this. When the job ends, everything below its cgroup is killed and
removed (`cgroup.kill`, then `rmdir` deepest first); `cgroups.sh` also removes
what a dead job left, never below a job whose `heavy-run.sh` still runs.

Checked on the worker on 2026-11-14 with a probe job: `newuidmap`/`newgidmap`
mapped `0 20000 1; 1 2000000 65535` for both uids and gids; heavytest made a
child in the delegated cgroup, set `memory.max` 50M and `pids.max` 64, and moved
itself into it; unprivileged user namespaces are on (`max_user_namespaces`
208677, no AppArmor restriction, kernel 6.8) and the cgroup2 mount has
`nsdelegate`.

## Silence, wall time and the 2-hour cap for big jobs (2026-11-14)

Why: a wasm-box job believed a compiler was cached, compiled LLVM from source
with gcc in the big slot for over an hour, ahead of everything else, and
nothing in `heavy` noticed.

`heavy status` / `heavy queue`, per running job:
`[big, 52 min wall, silent 134 s, wall cap in 68 min] ...`. Silence is the
seconds since the job's output (stdout or stderr) last appeared, to within
about 5 s; wall time runs from when the job got its slot. A job that started
before this existed shows `silence not tracked`.

How: `heavy-run.sh` sends the job's stdout and stderr through two `tee`s on
fifos (bytes pass untouched, stdout stays stdout, stderr stays stderr, the exit
code is the job's). A monitor loop, every 5 s while the job lives, touches
`/work/.slots/SLOT.out` when output appeared (its mtime is the silence; its
content is the wall-cap deadline as an epoch, or `none`), and looks at the
output of the last 5 s. Nothing is kept: the tee's file is emptied each time.

**Wall cap:** an unmarked **big** job gets 2 hours from the start of its run.
Then its log says `heavy: wall cap 2h; rerun with --long if this is expected`,
the job's process group gets SIGTERM, and 60 s later SIGKILL; the job exits 124.

| What | How |
|---|---|
| Opt out | `heavy --long -- CMD` or `heavy -e HEAVY_LONG=1 -- CMD` (`--long` needs the PC's `heavy` from the dotfiles of 2026-11-14; the `-e` form works anywhere) |
| A cap of your own | `heavy -e HEAVY_WALL_CAP=SECONDS -- CMD`, any class; `HEAVY_LONG` wins |
| Grace before SIGKILL | `HEAVY_WALL_GRACE=SECONDS`, default 60 |
| Never capped | the emulator's reservation and jobs inside it, services, small jobs without `HEAVY_WALL_CAP` |

`heavy bg --big` batch jobs are big jobs and get the cap too: pass `-e
HEAVY_LONG=1` for one that is meant to run longer.

**LLVM or GCC from source:** a warning line, once, in the job's log. At start,
when the command (or the script it names) matches `nix build ... llvm|gcc`,
`build-llvm`, `llvm-from-source` or `llvm-project`; while running, when its
output shows Nix building a `gcc`, `llvm` or `clang` derivation with a version
number (`building '/nix/store/...-llvm-19.1.7.drv'`, a wrapper does not match)
or CMake compiling an object under an `llvm` path. A warning only: nothing is
stopped by it.

## Jobs that survive their client (2026-11-14)

Why: until then a job lived exactly as long as the SSH channel of the PC's
`heavy` client (`heavy-run.sh` reads the channel's stdin and kills the job, or
takes it out of the queue, when it closes). That client is a few MB of ssh and
bash that runs as an agent job at a high OOM score, so in any memory spike on
the PC the kernel killed it first and the job lost its queue place. At
17:53-17:57 on 2026-11-14 a global OOM took every wasm-box lane's client,
including a `--priority` release build that had waited about 2 hours.

Two changes, both in the dotfiles' `heavy` module and `agent-job`, plus one
script here:

1. **The client runs at OOM score 500** (the infra daemons' value), not 800
   (agents' builds; 1000 in the units already running on 2026-11-14, from an
   older `agent-job`). `heavy` passes `AGENT_JOB_OOM=500` to `agent-job wrap`,
   which sets it as the unit's `OOMScoreAdjust`. A unit already running keeps
   its old score: only a client started after the PC deploys gets it.
2. **The job does not depend on the client.** `scripts/heavy-detach.sh` starts
   `heavy-run.sh` in its own session, with its stdin on a fifo that a `sleep`
   holds open (killing that sleep is the old "channel closed"), and its output
   in `/work/.jobs/KEY/{out,err}`. The client only follows it
   (`heavy-detach.sh run|attach|cancel|list|reap`).

KEY is the client's hash of the workspace path, the sub-directory, the shell,
the class, `--priority`, `--cpus`, the `-e` variables and the command: the same
command from the same directory finds its job again. A different `-e` value is
a different job. Files per job: `out`, `err`, `cmd`, `started`, `pid`,
`keeper`, `heartbeat` (touched twice a second by an attached client), `status`
(the exit code, when it ended), `consumed`, `cancelled`, `orphaned`.
`heavy-detach.sh list` shows them (`ssh -p 2223 root@worker bash
/scripts/heavy-detach.sh list`).

What each case does:

| Case | What happens |
|---|---|
| The client is killed by SIGKILL or the OOM killer | The job stays queued or running, its queue place unchanged (checked: the same ticket in `/work/.queue` before and after). Start the same command again, or `agent-job attach NAME`: it re-attaches, prints the job's output from the start and exits with its status |
| The same command is started while its job is queued or running | It attaches to that job; nothing new is queued. This also happens between two live clients (two agents with the same command) |
| The job finished while no client was there | The next call for the same command gets its output and exit code once (kept 6 hours), and says so; the call after that runs the command again |
| `agent-job attach NAME` on a client that was killed | `agent-job` starts the client again from the recorded directory and command (it knows it is a `heavy`), which re-attaches. Not after `agent-job stop NAME`, which cancelled the job, and not for a finished one |
| The client is interrupted: Ctrl-C, SIGTERM, SIGHUP, `agent-job stop` | It cancels the job on the worker (leaves the queue, or kills it) before exiting 130, as before. Until 2026-11-14 evening `agent-job stop` did not: systemd sends SIGTERM to the whole unit, the unit's main process dies, and systemd then sends a second SIGTERM to what is left, which killed the client in the middle of its cancel. The cancel now ignores further signals (`trap ""`, inherited by its ssh) and uses its own ssh connection, not the unit's mux master |
| Cancel without attaching | `heavy cancel KEY...` (6 or more characters of the key `heavy status` shows in brackets), `heavy cancel --here` (every job of this directory), `heavy cancel` (list the jobs and keys). A queued job leaves the queue, a running one is killed; the same as an interrupted client. Only for jobs started by a client from 2026-11-14 on |
| A client's ssh died and its attach loop on the worker was left behind | Until 2026-11-14 evening that loop (`heavy-detach.sh run/attach`, parent pid 1 after its sshd session ended) kept touching the job's heartbeat for good: `client last seen 0 s ago` with no client, and the 2-hour cutoff never fired. The loop now stops when it is reparented, and leaves the job alone |
| The SSH connection is lost (the client survives) | The client re-attaches by itself every 5 s, up to 120 times (10 minutes); the output is replayed from the start. Until 2026-11-14 this ended the job with status 255 |
| The PC reboots, or the client's unit is gone | The job keeps going; start the same command again to re-attach |
| Nobody has attached for 2 hours (`HEAVY_ORPHAN_MIN`) | The job is cancelled (queued: it leaves the queue; running: it is killed), so abandoned jobs do not fill the queue. `housekeeping.sh` and every `heavy-detach.sh` call check this |
| The worker pod restarts | Every job is gone, as before; a re-attach says so (exit 253) and a re-run starts it again |
| `HEAVY_DETACH=0 heavy ...` | The old way: tied to the connection |

Exit codes: the job's own, except 255 (ssh's) is reported as 254, and 253 means
the job is gone (collected, or the worker restarted). Collected results and
their logs are removed after 10 minutes. The output of a job is kept on the
worker's disk while it runs; a very chatty job costs disk in `/work/.jobs`.

What existed before: only the PC's `agent-job` reuse, a client unit with the
same name (a hash of the directory and the arguments) that is still alive is
followed instead of started again. It did nothing for a client that was killed,
because its job was killed with it.

## Build stores: a persistent area for state that must outlive a workspace (2026-11-15)

Why: on 2026-11-15 04:24:34 UTC wasm-box's package-world store
(`/work/world-r3h-dd182dd6/target/supply-world-store`, hours of work) was gone.
Not `/tmp`, not the restart itself: it was in a workspace, and housekeeping
removed that workspace (`workspaces use 43G > 15G; least recently used`,
`/nix/var/worker/housekeeping.log`, 90 s before the next job was submitted).
The restart only triggered it: the VM restart kills every job, so at the first
housekeeping run after it **no workspace has a job and every one over the 15 GB
budget is removable, least recently used first** (9 workspaces went that
minute). Anything that must survive belongs in a store, not in `/work`.

| What | Value |
|---|---|
| Where | `/nix/var/worker/stores/NAME` on the volume, outside `/work` and `$HOME`: not touched by the workspace budget or the cache pruning, and kept across a pod or VM restart |
| How a job gets one | `heavy -e HEAVY_STORE=NAME -- CMD`. The job sees `HEAVY_STORE_DIR=/nix/var/worker/stores/NAME` (created, root owned) and `HEAVY_STORES_ROOT` (in every job) |
| Names | letters, digits, `.` `_` `-`, up to 64, starting with a letter or digit; anything else exits 94 without starting |
| Never removed while in use | a job with `HEAVY_STORE=NAME` holds a shared `flock` on `/work/.slots/store-NAME` from the moment `heavy-run.sh` starts (queue wait included) to its end; housekeeping takes the exclusive one without waiting and skips the store when it cannot |
| Eviction | only when no job uses it, and then only (1) a store unused for 14 days (`HEAVY_STORES_IDLE_DAYS`; last use is `$store/.heavy-last-used`, touched when a job starts and ends), or (2) least recently used first while all stores together exceed 100 GB (`HEAVY_STORES_BUDGET_MB`), never one used in the last 2 days. Nothing else removes a store |

Notes: a job that does not set `HEAVY_STORE` is not protected, even if it writes
under the stores root. A store is a plain directory owned by root: an
unprivileged step (`HEAVY_USER=nobody`) can read it, not write it. A store is not
a Nix store; point whatever tool you run (`WBOX_PKGS=$HEAVY_STORE_DIR/pkgs`) at it.

## Restarting the pod without losing work (2026-11-15)

Any change to the Deployment (`strategy: Recreate`: the `/tmp` volume, the 24 GiB
limit in the manifest, an image bump) and a VM restart kill every process in the
pod. Until 2026-11-15 that also lost the queue and the places in it. Now:

- **Queued jobs are kept.** A job submitted by a client from 2026-11-15 on
  (`heavy-detach.sh`) records its arguments, options, `-e` values (a 0600 copy, in
  `/work/.jobs/KEY/`, deleted when the job gets its slot) and its ticket time.
  At the next pod start, `cgroups.sh` runs `heavy-detach.sh resume` (only in the
  first 3 minutes of the container, and before housekeeping): each such job that had
  not got its slot is queued again in order, **with its original ticket time**, so it
  keeps its place, and the lane's client re-attaches by key as after a lost connection.
  `heavy-detach.sh list` says `queued (kept if the pod restarts)`. Log:
  `/nix/var/worker/resume.log`.
- **Running jobs are not.** A job that had its slot (marker `running`) is killed by a
  restart and not re-queued: its client gets `gone` (253). So a restart is done only
  when no job runs. Jobs queued by an older client, or submitted before this existed,
  are also lost: `list` says so, and `check` waits for them to drain.
- **A pause, to reach the moment nothing runs.** There is never an idle moment on its
  own (a queue is always waiting). `heavy-maint.sh pause big|all MINUTES [REASON]`
  writes `/work/.pause`: new starts of **resumable** jobs are held (scope `big`: the
  big slot only, so small jobs keep flowing; `all`: both slots), everything else and
  everything already running goes on, held tickets are not counted as "ahead" of the
  rest, and it lapses at its deadline by itself (at most 12 h), so it can never wedge
  the queue. Waiting jobs say so in their log.

```bash
W="ssh -p 2223 root@192.168.50.100"        # the worker (heavy's own key; known-hosts as heavy)
$W bash /scripts/heavy-maint.sh status     # what runs, what a restart would keep and lose
$W bash /scripts/heavy-maint.sh pause big 720 "pod restart: /tmp volume + 24Gi"
$W bash /scripts/heavy-maint.sh check      # wait | tighten | ready
$W bash /scripts/heavy-maint.sh pause all 45 "pod restart"     # when check says tighten
$W bash /scripts/heavy-maint.sh check      # ready: nothing runs, nothing queued would be lost
# now merge the Deployment change to main (Flux applies it in about a minute),
# wait for the new pod, check the evidence, then:
$W bash /scripts/heavy-maint.sh unpause
```

`check` waits while a job is in a slot, a `heavy bg` service or the emulator runs, a
pinned-cores job holds the cores, or a queued job would be lost. It says `tighten`
when the big slot is free and nothing non-resumable waits for it, and `ready` when
both slots are held and nothing runs. Do not restart while it says anything else;
`--long` jobs (hours) are the usual reason. After the restart, `unpause` (or let the
pause lapse) and confirm with `heavy-detach.sh list` that the queued jobs came back.

### Without a standing pause (2026-11-15, the preferred way)

A pause holds new big jobs for as long as it takes a long job to end, which can be
all day; wasm-box asked for none. So no pause is held while waiting. A change that
restarts the pod is applied at one of two moments, and costs nothing extra:

1. **Just before a restart that happens anyway.** The VM's nightly maintenance
   reboot (Proxmox `homelab-maintenance-reboot.timer`, 04:15 UTC; `qm reboot 200` at
   about 04:20, only when the VM has `/run/reboot-required`) kills every job
   regardless. Merging the Deployment change about two minutes before it (Flux
   applies in about a minute) makes that one reboot apply it. Whether it is due:
   `ssh proxmox homelab-maintenance-reboot --dry-run` after the VM's upgrade run
   (about 06:00 to 07:00 UTC), or at 04:17 UTC the unit is still running and its
   journal has no `nothing to reboot`.
2. **A true idle moment**, with no pause: `heavy-maint.sh idle` says `idle` when no
   job is in a slot, no service or emulator runs and no queued job would be lost
   (queued jobs of resumable clients are kept). Then `pause all 15` as a guard for
   the minute Flux needs, check `idle` again, merge, verify, `unpause`.

If neither comes, the change waits; nothing is killed to make room for it.
