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
  container. The small request makes this pod the first one the kubelet evicts
  and the first one the kernel OOM-kills if the node itself runs short.
- **CPU:** no request and no limit, like everything else here, so it gets the
  smallest share whenever another pod wants the CPU. `max-jobs` and `cores` in
  `config/nix-builder/nix.conf` are sized to use the node fully when idle.
- **Disk:** the volume is the node's root disk and local-path enforces no
  quota. `min-free` in `nix.conf` makes Nix collect garbage when that disk
  drops below 110 GiB free (just above the 20% `DiskFillingUp` alert) and
  collect until 135 GiB is free. The nightly job keeps GC roots under
  `/nix/var/nix/gcroots/auto-update` for the closures worth keeping; anything
  not rooted is fair game.

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
ssh naiaclaw 'sudo kubectl -n homelab get pod -l app.kubernetes.io/name=nix-builder; df -h /'
```

## Nested user namespaces

The node is Ubuntu 24.04, which by default denies unprivileged user namespaces
(`kernel.apparmor_restrict_unprivileged_userns=1`). Nix's own sandbox does not
care, since the daemon is root, but a build that sets up a sandbox of its own
inside Nix's fails with `bwrap: setting up uid map: Permission denied`
(`vmware-workstation` does this). `ops/sysctl/99-homelab.conf` sets it to `0`,
the default on other distributions; install it at
`/etc/sysctl.d/99-homelab.conf` on a rebuilt node.
