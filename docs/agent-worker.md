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
- **Disk:** same node disk as nix-builder. `min-free` = 45 GiB, so it collects
  before nix-builder (40 GiB). An hourly janitor removes workspaces untouched
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
