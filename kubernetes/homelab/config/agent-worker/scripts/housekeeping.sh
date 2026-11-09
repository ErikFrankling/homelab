#!/bin/bash
# Hourly, started by cgroups.sh. The node disk is shared with nix-builder and
# was down to 35 GB free on 2026-10-21, so the worker keeps itself small:
#   - workspaces untouched for 3 days go, and the least recently used ones
#     while all of them use more than 15 GB (never one with a running job)
#   - each cache is pruned to a size budget, whole entries (one tool's cache),
#     least recently used first, never one used in the last 2 days
#   - old devShell profile generations go, then dead Nix store paths whenever
#     the node has less than 155 GB free (nix.conf's min-free does the same
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
# Sizes are measured once, in the idle IO class, and subtracted as workspaces
# go: a du of all of /work per removal took an hour under IO pressure on
# 2026-11-09. `heavy status` shows what is left (/work/.stats/workspaces)
# instead of running its own du.
work_budget=15
declare -A ws_kb=()
used_kb=0
while IFS=$'\t' read -r kb ws; do
  ws_kb[$ws]=$kb
  used_kb=$((used_kb + kb))
done < <(ionice -c3 du -sk /work/*/ 2> /dev/null)
for ws in $(ls -1dtr /work/*/ 2> /dev/null); do
  [ $((used_kb / 1048576)) -gt "$work_budget" ] || break
  busy "$ws" && continue
  echo "removing workspace $ws (workspaces use $((used_kb / 1048576))G > ${work_budget}G; least recently used)"
  rm -rf "$ws"
  used_kb=$((used_kb - ${ws_kb[$ws]:-0}))
  unset "ws_kb[$ws]"
done
mkdir -p /work/.stats
{
  echo "measured $(date '+%F %H:%M'), $((used_kb / 1048576))G in all"
  for ws in "${!ws_kb[@]}"; do printf '%s\t%s\n' "${ws_kb[$ws]}" "$ws"; done \
    | sort -rn | head -8 | awk -F'\t' '{ printf "%.1fG\t%s\n", $1 / 1048576, $2 }'
} > /work/.stats/workspaces.new && mv /work/.stats/workspaces.new /work/.stats/workspaces

# Caches go whole: each entry of the directories below is one tool's or one
# project's cache (.cache/fleet-build, .cache/nix, .local/share/pnpm,
# .gradle/caches/modules-2, ...), removed as a unit, least recently used
# first, while the directories together are over their budget. Never single
# files (2026-11-07): pruning files by atime broke every Fleet build. Unpacked
# archives carry the archive's atime (crate sources say 1970 or 2006), so the
# sources cargo only stats went while .cargo-ok still called the crate
# complete ("can't find dotenvy bin"), and deleting empty directories took
# the empty refs/ of nix's tarball-cache git repository ("could not find
# repository"). Last use is the newest atime or ctime in the entry (ctime is
# set on unpacking); entries used in the last 2 days stay.
#
# A job that starts on a cache while it is being removed breaks as well, and
# housekeeping starts exactly when a job starts. So pruning holds both job
# slots (heavy-run.sh waits for them), or waits for the next hour while a job
# runs.
slots=""
hold_slots() {
  [ -z "$slots" ] || return 0
  exec 8> /work/.slots/big 9> /work/.slots/small
  if flock -n 8 && flock -n 9; then
    slots=held
    for slot in big small; do
      printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$slot" .housekeeping "removing unused caches" > "/work/.slots/$slot.job"
    done
    return 0
  fi
  exec 8>&- 9>&-
  return 1
}
size_gb() { du -scBG "$@" 2> /dev/null | tail -1 | cut -f1 | tr -d G; }
last_used() { find "$1" -xdev -printf '%A@\n%C@\n' 2> /dev/null | awk '$1 > m { m = $1 } END { printf "%d", m }'; }
# prune BUDGET_GB DIR...
prune() {
  local budget=$1 size used entry recent
  shift
  size=$(size_gb "$@")
  [ "${size:-0}" -gt "$budget" ] || return 0
  hold_slots || { echo "$* use ${size}G > ${budget}G; a job is running, pruning next time"; return 0; }
  recent=$(($(date +%s) - 2 * 86400))
  while IFS=$'\t' read -r used entry; do
    if [ "$used" -ge "$recent" ]; then
      echo "$* use ${size}G > ${budget}G, but everything left was used in the last 2 days"
      break
    fi
    echo "removing $entry (${size}G > ${budget}G; last used $(date -d "@$used" +%F))"
    rm -rf "$entry"
    size=$(size_gb "$@")
    [ "${size:-0}" -gt "$budget" ] || break
  done < <(find "$@" -mindepth 1 -maxdepth 1 -print0 2> /dev/null \
    | while IFS= read -r -d '' entry; do printf '%s\t%s\n' "$(last_used "$entry")" "$entry"; done | sort -n)
}
home=$state/home
prune 10 "$home/.gradle/caches" "$home/.gradle/wrapper/dists"
prune 20 "$home/.cache"
prune 8 "$home/.local/share" "$home/.local/state"
prune 3 "$home/.npm"
prune 4 "$home/.cargo/registry" "$home/.cargo/git"
prune 3 "$home/.bun/install/cache"
prune 2 "$home/.android"
if [ -n "$slots" ]; then
  rm -f /work/.slots/big.job /work/.slots/small.job
  exec 8>&- 9>&-
fi

for profile in /work/*/.heavy/shell-*; do
  case "$profile" in *-link) continue ;; esac
  [ -L "$profile" ] && nix-env -p "$profile" --delete-generations old > /dev/null 2>&1
done
if [ "$(free_gb)" -lt 155 ]; then
  echo "collecting dead store paths"
  nix-store --gc 2>&1 | tail -1
fi
echo "== done, node free $(free_gb)G"
