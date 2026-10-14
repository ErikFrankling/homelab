#!/bin/sh
# Init container, run from the nixos/nix image with the store volume at
# /mnt/nix. The volume shadows /nix in every other container, so nothing from
# an image's own store survives there: the tools the pod runs (nix, sshd,
# harmonia, ...) are substituted into the volume here, from one pinned nixpkgs
# revision, and linked under /nix/var/builder/bin.
#
# NIXPKGS_REV comes from the Deployment. Bumping it is how the tools are
# upgraded; an unchanged revision is a no-op so the pod still starts offline.
set -eu

root=/mnt
state="$root/nix/var/builder"
stamp="$state/seeded-rev"
packages="nix openssh harmonia bashInteractive coreutils gnugrep gnused findutils gitMinimal cacert"

# local-path creates the volume directory world-writable, and Nix refuses a
# store whose parent anyone can write to.
chmod 0755 "$root/nix"
roots="$root/nix/var/nix/gcroots/builder-tools"

# Seeded already, and the garbage collector has not taken anything: nothing to
# do, which also lets the pod start without network.
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$NIXPKGS_REV" ] && [ -d "$roots" ]; then
  intact=true
  for link in "$roots"/*; do
    [ -e "$root$(readlink "$link")" ] || intact=false
  done
  if $intact; then
    echo "tools already seeded from nixpkgs $NIXPKGS_REV"
    exit 0
  fi
  echo "some tools are gone from the store; seeding again"
fi

installables=""
for package in $packages; do
  installables="$installables github:NixOS/nixpkgs/$NIXPKGS_REV#$package"
done

# Substitution only (--max-jobs 0): a tool that is not in cache.nixos.org is a
# wrong pin, not something to compile in an init container.
# shellcheck disable=SC2086
paths=$(nix build \
  --extra-experimental-features 'nix-command flakes' \
  --store "local?root=$root" \
  --max-jobs 0 --no-link --print-out-paths $installables)

# Each tool is rooted by its own symlink directly inside gcroots. Nix follows a
# root symlink only to a store path; on 2026-10-14 the roots were one level
# further down, behind a symlink to a directory, and a garbage collection
# deleted nix and harmonia out from under the running pod.
rm -rf "$state/bin.new" "$roots.new"
mkdir -p "$state/bin.new" "$roots.new"
for path in $paths; do
  ln -s "$path" "$roots.new/$(basename "$path")"
  if [ -d "$root$path/bin" ]; then
    for binary in "$root$path"/bin/*; do
      ln -sfn "$path/bin/$(basename "$binary")" "$state/bin.new/$(basename "$binary")"
    done
  fi
  if [ -e "$root$path/etc/ssl/certs/ca-bundle.crt" ]; then
    ln -sfn "$path/etc/ssl/certs/ca-bundle.crt" "$state/ca-bundle.crt"
  fi
done

rm -rf "$state/bin" "$state/roots" "$roots"
mv "$state/bin.new" "$state/bin"
mv "$roots.new" "$roots"

echo "$NIXPKGS_REV" > "$stamp"
echo "seeded tools from nixpkgs $NIXPKGS_REV"
