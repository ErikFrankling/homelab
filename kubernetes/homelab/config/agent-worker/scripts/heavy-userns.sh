#!/bin/bash
# User namespaces with subordinate ids for an unprivileged test user
# (HEAVY_USERNS=1 or HEAVY_USER=test, heavy-run.sh). Run as root before such a
# job starts: heavy-userns.sh ensure
#
# The container's /etc is lost on a restart and seed.sh/entrypoint.sh are in a
# hashed ConfigMap (editing them restarts the pod and kills every job), so this
# is the declared config, applied on demand and idempotent:
#
#   user      heavytest, uid 20000, gid 20000 (not 65534: nobody owns nothing
#             and has no ranges; this one is for tests that need them), no
#             home on disk;
#   ranges    /etc/subuid and /etc/subgid: heavytest:2000000:131072 each. The
#             nixbld users hold 100000 to 1148575 (useradd gave each 65536), so
#             2000000 and up overlaps nothing; this checks that and refuses if
#             it ever does;
#   binaries  newuidmap and newgidmap from the pinned nixpkgs' `shadow`
#             (the image has no `uidmap` package), copied setuid root to
#             /usr/local/bin (a setuid bit does not survive in the Nix store).
#             The store path is rooted as $state/suid/shadow, so a pod restart
#             copies it again without downloading.
#
# The cgroup half (a subtree root delegates to the user for one job) is in
# heavy-run.sh.
set -u
state=/nix/var/worker
user=heavytest uid=20000 gid=20000
sub_start=2000000 sub_count=131072
sub_end=$((sub_start + sub_count - 1))

[ "${1:-}" = ensure ] || { echo "usage: heavy-userns.sh ensure" >&2; exit 2; }
exec 8> /run/heavy-userns.lock
flock 8

getent group "$user" > /dev/null || groupadd --gid "$gid" "$user" || exit 1
getent passwd "$user" > /dev/null \
  || useradd --uid "$uid" --gid "$gid" --no-create-home --home-dir /nonexistent \
    --shell /bin/bash "$user" || exit 1

# useradd may have added a range of its own for the user: replace it, after
# checking that ours overlaps nobody else's.
want="$user:$sub_start:$sub_count"
for f in /etc/subuid /etc/subgid; do
  touch "$f"
  if ! grep -qx "$want" "$f" || [ "$(grep -c "^$user:" "$f")" != 1 ]; then
    if awk -F: -v u="$user" -v s="$sub_start" -v e="$sub_end" \
      '$1 != u && $2 <= e && $2 + $3 - 1 >= s { bad = 1 } END { exit !bad }' "$f"; then
      echo "heavy: $f already has a range overlapping $sub_start-$sub_end; not touching it" >&2
      exit 1
    fi
    { grep -v "^$user:" "$f"; echo "$want"; } > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
  fi
done

# newuidmap / newgidmap.
dest=/usr/local/bin
if [ ! -u "$dest/newuidmap" ] || [ ! -u "$dest/newgidmap" ]; then
  link=$state/suid/shadow
  if [ ! -x "$link/bin/newuidmap" ]; then
    mkdir -p "$state/suid"
    rev=$(cat "$state/nixpkgs-rev" 2> /dev/null) || { echo "heavy: no $state/nixpkgs-rev" >&2; exit 1; }
    echo "heavy: fetching shadow (newuidmap, newgidmap) from nixpkgs $rev (once)" >&2
    timeout 600 nix build --out-link "$link" "github:NixOS/nixpkgs/$rev#shadow" 3<&- 6<&- 7<&- 9<&- >&2 \
      || { echo "heavy: could not build shadow; the job was not started" >&2; exit 1; }
  fi
  for b in newuidmap newgidmap; do
    install -m 4755 -o root -g root "$link/bin/$b" "$dest/$b" || exit 1
  done
fi
exit 0
