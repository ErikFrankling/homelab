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

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$NIXPKGS_REV" ]; then
  echo "tools already seeded from nixpkgs $NIXPKGS_REV"
  exit 0
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

rm -rf "$state/bin.new" "$state/roots.new"
mkdir -p "$state/bin.new" "$state/roots.new" "$root/nix/var/nix/gcroots"
for path in $paths; do
  ln -s "$path" "$state/roots.new/$(basename "$path")"
  if [ -d "$root$path/bin" ]; then
    for binary in "$root$path"/bin/*; do
      ln -sfn "$path/bin/$(basename "$binary")" "$state/bin.new/$(basename "$binary")"
    done
  fi
  if [ -e "$root$path/etc/ssl/certs/ca-bundle.crt" ]; then
    ln -sfn "$path/etc/ssl/certs/ca-bundle.crt" "$state/ca-bundle.crt"
  fi
done

rm -rf "$state/bin" "$state/roots"
mv "$state/bin.new" "$state/bin"
mv "$state/roots.new" "$state/roots"
# One indirection keeps the garbage collector away from the tools: every entry
# in roots/ is a symlink to a store path.
ln -sfn /nix/var/builder/roots "$root/nix/var/nix/gcroots/builder-tools"

echo "$NIXPKGS_REV" > "$stamp"
echo "seeded tools from nixpkgs $NIXPKGS_REV"
