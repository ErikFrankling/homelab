#!/bin/sh
# Init container, run from the nixos/nix image with the store volume at
# /mnt/nix. Same idea as config/nix-builder/seed.sh: the tools the worker runs
# are substituted into its own store from one pinned nixpkgs revision and
# linked under /nix/var/worker/bin. An unchanged revision is a no-op, so the
# pod still starts offline.
set -eu

root=/mnt
state="$root/nix/var/worker"
stamp="$state/seeded-rev"
# Everything a job over SSH needs before `nix develop` / `nix shell` takes
# over: rsync for `heavy`'s sync, adb for the emulator, procps for status.
packages="nix openssh bashInteractive coreutils gnugrep gnused gawk findutils gitMinimal cacert rsync procps util-linux gnutar gzip xz which iproute2 android-tools less"

chmod 0755 "$root/nix"
roots="$root/nix/var/nix/gcroots/worker-tools"

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$NIXPKGS_REV:$packages" ] && [ -d "$roots" ]; then
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

# Substitution only: a tool missing from cache.nixos.org is a wrong pin.
# shellcheck disable=SC2086
paths=$(nix build \
  --extra-experimental-features 'nix-command flakes' \
  --store "local?root=$root" \
  --max-jobs 0 --no-link --print-out-paths $installables)

# Each tool rooted by its own symlink directly in gcroots (see the nix-builder
# seed for why).
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

rm -rf "$state/bin" "$roots"
mv "$state/bin.new" "$state/bin"
mv "$roots.new" "$roots"

echo "$NIXPKGS_REV:$packages" > "$stamp"
echo "seeded tools from nixpkgs $NIXPKGS_REV"
