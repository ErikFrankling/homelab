#!/bin/bash
# Hourly, started by cgroups.sh. The node disk is shared with nix-builder and
# was down to 35 GB free on 2026-10-21, so the worker keeps itself small:
#   - workspaces untouched for 3 days go, and the least recently used ones
#     while all of them use more than 15 GB (never one with a running job)
#   - each cache is pruned to a size budget, least recently used files first
#   - old devShell profile generations go, then dead Nix store paths whenever
#     the node has less than 45 GB free (nix.conf's min-free does the same
#     during builds)
set -u
exec 7> /run/heavy-housekeeping.lock
flock -n 7 || exit 0
state=/nix/var/worker
free_gb() { df --output=avail -B1G /nix | tail -1 | tr -d ' '; }
echo "== $(date -Is) housekeeping, node free $(free_gb)G"

busy() { pgrep -f "heavy-run.sh ${1%/} " > /dev/null; }
for ws in /work/*/; do
  [ -d "$ws" ] || continue
  if [ -n "$(find "$ws" -maxdepth 0 -mmin +4320)" ] && ! busy "$ws"; then
    echo "removing workspace $ws (untouched for 3 days)"
    rm -rf "$ws"
  fi
done

# All workspaces together: at most 15 GB, least recently used go first.
work_budget=15
for ws in $(ls -1dtr /work/*/ 2> /dev/null); do
  used=$(du -s -BG /nix/var/worker/work 2> /dev/null | cut -f1 | tr -d G)
  [ "${used:-0}" -gt "$work_budget" ] || break
  busy "$ws" && continue
  echo "removing workspace $ws (workspaces use ${used}G > ${work_budget}G; least recently used)"
  rm -rf "$ws"
done

# prune DIR BUDGET_GB: delete files not used for 30, 14, 7, 3, 1 days until
# the directory fits.
prune() {
  local dir=$1 budget=$2 days size
  [ -d "$dir" ] || return 0
  for days in 30 14 7 3 1; do
    size=$(du -s -BG "$dir" 2> /dev/null | cut -f1 | tr -d G)
    [ "${size:-0}" -gt "$budget" ] || return 0
    echo "pruning $dir (${size}G > ${budget}G): files unused for $days days"
    find -L "$dir" -xdev -type f -atime +"$days" -delete 2> /dev/null
    find -L "$dir" -xdev -mindepth 1 -type d -empty -delete 2> /dev/null
  done
}
home=$state/home
prune "$home/.gradle" 10
prune "$home/.cache" 8
prune "$home/.local" 6
prune "$home/.npm" 3
prune "$home/.cargo" 4
prune "$home/.bun" 3
prune "$home/.android" 2

for profile in /work/*/.heavy/shell-*; do
  case "$profile" in *-link) continue ;; esac
  [ -L "$profile" ] && nix-env -p "$profile" --delete-generations old > /dev/null 2>&1
done
if [ "$(free_gb)" -lt 45 ]; then
  echo "collecting dead store paths"
  nix-store --gc 2>&1 | tail -1
fi
echo "== done, node free $(free_gb)G"
