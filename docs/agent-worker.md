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

- **Memory:** limit 16 GiB, request 256 MiB. That is the smallest request of
  any heavy pod, so under node pressure this pod is evicted and OOM-killed
  before nix-builder and the services.
- **CPU:** no request and no limit, so it gets the smallest share under
  contention. `max-jobs = 2`, `cores = 4` for Nix builds here.
- **Disk:** same node disk as nix-builder. `min-free` = 45 GiB, so it collects
  before nix-builder (40 GiB). An hourly janitor removes workspaces untouched
  for 7 days, and then the oldest ones while the disk has under 50 GiB free.
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

`heavy emulator start` on the PC runs `heavy-emulator.sh start` here. The
first run fetches the SDK and system image into this store (a few GB). It then
tunnels `127.0.0.1:5555` here to `127.0.0.1:15555` on the PC and runs
`adb connect 127.0.0.1:15555`. The pod's own adb server is stopped after boot,
so the PC's adb is the emulator's only client. `adb install`, `adb reverse`
and Expo work through that.
