# Nix build server and binary cache

`kubernetes/homelab/apps/nix-builder.yaml` runs one pod that builds the NixOS
system closures for `pc` and `framework` and serves them as a binary cache.
The machines then update by downloading, never by compiling. The nightly job
pushes the dotfiles to `main` only once both closures are built here, so
`main` itself says what is in the cache. The client side
(timers, substituter settings, the nightly update job) lives in the dotfiles
repository.

## How it fits together

| Piece | Where | What it does |
|---|---|---|
| `seed` (init) | `nixos/nix` image | Substitutes nix, sshd, harmonia and friends into the volume from one pinned nixpkgs revision |
| `builder` | port 2222 on the VIP, LAN only | sshd; the PC builds with `nix build --store ssh-ng://root@192.168.50.100:2222` |
| `cache` | `https://nix-cache.erikfrankling.duckdns.org` | harmonia, serving the builder's `/nix/store` signed |

The builder's store is the cache. Building a system closure leaves every path
of it valid in that store, including what came from `cache.nixos.org`, so a
client can fetch its whole update from the LAN.

Public key, for `trusted-public-keys` on the clients:

```text
nix-cache.erikfrankling.duckdns.org-1:i1VytpUS/NiHyPJq8tWmvhrhfBL7L3+ZOcVYq2BXWdA=
```

The private half is `secrets/nix-builder.enc.yaml`. Rotating it means every
client needs the new public key before it will accept anything built here.

## Keeping it away from everything else

- **Memory:** the builder container has a 24 GiB limit and a 512 MiB request.
  The limit is a hard ceiling, so a runaway build is killed inside the
  container. The small request and `--prefer` in `ops/earlyoom/install.sh` make its
  evaluations and compilers the first thing earlyoom kills if the node itself
  runs short. The kubelet does not evict on memory here.
- **CPU:** no request and no limit, like everything else here, so it never
  holds back scheduling. Its priority comes from the `cpu-priority` DaemonSet
  instead, which sets the pod's `cpu.weight` to 10000 against everyone else's 1
  (docs/architecture.md, "CPU priority"): under contention the nightly build
  gets most of the node, and when it is idle it costs nothing. `max-jobs` and
  `cores` in `config/nix-builder/nix.conf` are sized to use the node fully.
- **Disk:** the volume is the node's root disk and local-path enforces no
  quota. The nightly job (dotfiles auto-update) collects garbage before its
  builds, even when they then fail, when the disk has under 150 GiB free.
  `min-free` in `nix.conf` is only an emergency backstop: below 80 GiB free,
  collect until 150 GiB (`max-free`). Keep `min-free` well under the free
  space live data leaves: a threshold the store cannot reach makes every Nix
  operation run a full GC under the GC lock (2026-11-09: remote builds hung
  for 20 minutes). Keep `max-free` well above it, or each emergency GC frees
  a sliver and the next starts a few builds later (2026-11-18). The nightly
  job keeps GC roots under `/nix/var/nix/gcroots/auto-update` for the
  closures worth keeping; anything not rooted is fair game.
- **Never delete store paths with `rm`.** Only Nix deletes from `/nix/store`
  (`nix-collect-garbage`, `nix-store --delete`). A store directory removed
  behind its back stays valid in the database: every build that needs it
  fails, and a store path's mtime is always 1970, so "older than N days"
  matches all of them. 2026-11-18: an `rm -rf` of "old" store directories on
  the node took ~9,800 paths, nix and sshd among them.

## Repairing a store whose database and disk disagree

1. List what is valid but gone: `nix path-info --all`, then `[ -e "$p" ]`
   for each (`-e`, not `-d`: `.drv` files and some outputs are files).
2. Paths a substituter has: `nix-store --repair-path` fetches them again.
   `nix-store --verify` stops at its first database inconsistency, so give
   it the list instead.
3. Paths built only here that the PC still has: copy them into a file cache
   on the volume and repair from it, so Nix does the canonicalisation and
   hash check:
   `nix copy --to 'ssh-ng://root@192.168.50.100:2222?remote-store=file%3A%2F%2F%2Fnix%2Fvar%2Fbuilder%2Frepair%3Fcompression%3Dnone' PATHS`,
   then on the builder
   `nix-store --repair-path PATHS --option substituters file:///nix/var/builder/repair --option require-sigs false`.
4. The rest: `nix-store --delete --ignore-liveness` on
   `nix-store -q --referrers-closure` of them, so nothing valid refers to a
   missing path. They are rebuilt or fetched when next needed.
5. `nix-store --verify` should now finish without errors.

The seed container fetches the pod's own tools with `--repair`, so a pod
restart brings nix and sshd back even when the database lies about them.

## Access

Only keys in `config/nix-builder/authorized_keys` can log in, as root, into a
privileged container. Treat that file like root access to the node.

## Changing the pod's own tools

Bump `NIXPKGS_REV` in the Deployment to a revision whose packages are in
`cache.nixos.org`. The init container refuses to compile (`--max-jobs 0`), so
a bad pin fails the rollout instead of building harmonia on the node.

## Checking it

```bash
curl -s https://nix-cache.erikfrankling.duckdns.org/nix-cache-info
nix store info --store ssh-ng://root@192.168.50.100:2222
ssh k8s 'sudo kubectl -n homelab get pod -l app.kubernetes.io/name=nix-builder; df -h /'
```

## Nested user namespaces

The node is Ubuntu 24.04, which by default denies unprivileged user namespaces
(`kernel.apparmor_restrict_unprivileged_userns=1`). Nix's own sandbox does not
care, since the daemon is root, but a build that sets up a sandbox of its own
inside Nix's fails with `bwrap: setting up uid map: Permission denied`
(`vmware-workstation` does this). `ops/sysctl/99-homelab.conf` sets it to `0`,
the default on other distributions; install it at
`/etc/sysctl.d/99-homelab.conf` on a rebuilt node.
