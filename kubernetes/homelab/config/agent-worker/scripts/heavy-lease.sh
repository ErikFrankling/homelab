#!/bin/bash
# Persistent ownership + flock, shared by job admission and workspace retirement.
# No upstream tool tracks cross-workspace ownership, so this is the worker's
# lease authority. It never executes owner metadata, expires ownership, or
# creates a missing target. All records/locks live outside prunable trees.
lease_state=${HEAVY_LEASE_STATE:-/nix/var/worker}
lease_ready=${HEAVY_LEASE_READY:-/run/heavy-workspace-leases-ready}
lease_fail() { echo "heavy lease: $*" >&2; return 1; }
lease_resource() {
  local p base rest
  p=$(realpath -e -- "$1") && [ -d "$p" ] || { lease_fail "missing directory: $1 (no cold recreation)"; return 1; }
  for base in "$lease_state/work" "$lease_state/stores"; do
    base=$(realpath -e -- "$base") || continue
    case "$p" in
      "$base"/*)
        rest=${p#"$base"/}; rest=${rest%%/*}
        [[ $rest =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || $rest = .emulator ]] || break
        printf '%s/%s\n' "$base" "$rest"; return 0 ;;
    esac
  done
  lease_fail "path is not in a workspace or build store: $1"
}
lease_key() { printf '%s' "$1" | sha256sum | cut -d ' ' -f1; }
lease_init() {
  [ -f "$lease_ready" ] || { lease_fail 'startup migration not verified; admission/cleanup held'; return 1; }
  mkdir -p "$lease_state/leases" || return 1
}
lease_lock() { # resource mode -> global lease_fd, lease_dir (locks are never unlinked)
  lease_init || return 1
  lease_dir=$lease_state/leases/$(lease_key "$1")
  mkdir -p "$lease_dir" || return 1
  exec {lease_fd}>"$lease_dir/lock" || return 1
  if ! flock "$2" -n "$lease_fd"; then
    exec {lease_fd}>&-
    lease_fail "busy: $1"; return 1
  fi
}
lease_identity() { stat -Lc '%d:%i' -- "$1"; }
lease_retain() (
  local path=$1 owner=$2 resource token identity
  [[ $owner =~ ^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,199}$ ]] || { lease_fail 'invalid owner'; exit 1; }
  resource=$(lease_resource "$path") || exit 1
  lease_lock "$resource" -x || exit 1
  # Validate again after locking: cleanup may have won the race.
  [ "$(lease_resource "$path")" = "$resource" ] || exit 1
  identity=$(lease_identity "$resource") || exit 1
  token=$(cat /proc/sys/kernel/random/uuid) || exit 1
  # A crash during publication leaves an advisory pending record that blocks
  # retirement, never an unprotected successful acquisition.
  printf '%s\n%s\n%s\n%s\n' "$resource" "$identity" "$owner" "$(date -Is)" > "$lease_dir/$token.pending" || exit 1
  mv -- "$lease_dir/$token.pending" "$lease_dir/$token.lease" || exit 1
  printf '%s\n' "$token"
)
lease_validate() { # under lock
  local resource=$1 token=$2 recorded identity
  [[ $token =~ ^[a-f0-9-]{36}$ ]] || { lease_fail 'invalid token'; return 1; }
  [ -f "$lease_dir/$token.lease" ] || { lease_fail 'unknown/released lease'; return 1; }
  { read -r recorded; read -r identity; } < "$lease_dir/$token.lease"
  [ "$recorded" = "$resource" ] && [ "$identity" = "$(lease_identity "$resource")" ] \
    || { lease_fail 'resource identity changed; reconcile ownership'; return 1; }
}
lease_release() (
  local resource
  resource=$(lease_resource "$1") || exit 1
  lease_lock "$resource" -x || exit 1
  lease_validate "$resource" "$2" || exit 1
  # Keep the receipt; a late release cannot affect a new owner's token.
  mv -- "$lease_dir/$2.lease" "$lease_dir/$2.released"
)
lease_hold() { # path [retained-token], fd inherited until this job's last child exits
  local resource
  resource=$(lease_resource "$1") || return 1
  lease_lock "$resource" -s || return 1
  if [ "$(lease_resource "$1")" != "$resource" ] || \
    { [ -n "${2:-}" ] && ! lease_validate "$resource" "$2"; }; then
    exec {lease_fd}>&-
    return 1
  fi
  # Caller keeps the dynamically allocated FD open. Never unlock another
  # hold when acquiring its own workspace plus a borrowed target.
}
lease_admit() { # own workspace, plus an explicitly declared borrowed target
  local own target
  own=$(lease_resource "$1") || return 1
  lease_hold "$1" || return 1
  if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    target=$(realpath -m -- "$CARGO_TARGET_DIR") || return 1
    case "$target" in
      "$own"|"$own"/*)
        # A new local target is normal; the whole workspace is held.
        if [ -n "${HEAVY_TARGET_LEASE:-}" ]; then
          lease_hold "$1" "$HEAVY_TARGET_LEASE" || return 1
        fi ;;
      *)
        [ -n "${HEAVY_TARGET_LEASE:-}" ] || { lease_fail 'borrowed CARGO_TARGET_DIR needs HEAVY_TARGET_LEASE'; return 1; }
        lease_hold "$CARGO_TARGET_DIR" "$HEAVY_TARGET_LEASE" || return 1 ;;
    esac
  elif [ -n "${HEAVY_TARGET_LEASE:-}" ]; then
    lease_fail 'HEAVY_TARGET_LEASE requires explicit CARGO_TARGET_DIR'; return 1
  fi
}
lease_retire() (
  local resource=$1 reason=${2:-released} entry destination
  resource=$(lease_resource "$resource") || exit 1
  lease_lock "$resource" -x || exit 1
  for entry in "$lease_dir"/*.lease "$lease_dir"/*.pending; do
    [ ! -e "$entry" ] || { lease_fail "retained ownership: $resource"; exit 1; }
  done
  # Compatibility for jobs admitted before the shared-lock protocol. This is
  # supplementary, not the ownership contract. Old jobs must finish before
  # borrowed resources can be declared safe by the deployment owner.
  if pgrep -f "heavy-run.sh /work/$(basename "$resource") " >/dev/null; then
    lease_fail "legacy job uses $resource"; exit 1
  fi
  [ -d "$resource" ] || exit 1
  # Lossless same-filesystem retirement: never destroy traces or unfinished
  # outputs as a side effect of a size budget. This does not reclaim disk.
  mkdir -p "$lease_state/retired-workspaces" || exit 1
  [ "$(stat -c %d -- "$resource")" = "$(stat -c %d -- "$lease_state/retired-workspaces")" ] \
    || { lease_fail 'retirement must be an atomic same-filesystem rename'; exit 1; }
  destination=$lease_state/retired-workspaces/$(basename "$resource").$(cat /proc/sys/kernel/random/uuid)
  mv -T -- "$resource" "$destination" || exit 1
  printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$resource" "$destination" "$reason" >> "$lease_state/leases/retirements.log"
  echo "retired $resource to $destination ($reason); bytes/traces preserved"
)
lease_prune_workspaces() {
  local ws kb used_kb=0 work_budget=${HEAVY_WORK_BUDGET_GB:-15}
  local -A ws_kb=()
  for ws in "$lease_state/work"/*/; do
    [ -d "$ws" ] || continue
    if [ -n "$(find "$ws" -maxdepth 0 -mmin +4320)" ]; then
      lease_retire "$ws" 'untouched for 3 days' || true
    fi
  done
  while IFS=$'\t' read -r kb ws; do
    [ -n "$ws" ] || continue
    ws_kb[$ws]=$kb
    used_kb=$((used_kb + kb))
  done < <(ionice -c3 du -sk "$lease_state/work"/*/ 2>/dev/null)
  while IFS= read -r ws; do
    [ $((used_kb / 1048576)) -gt "$work_budget" ] || break
    lease_retire "$ws" "workspaces use $((used_kb / 1048576))G > ${work_budget}G; least recently used" || continue
    used_kb=$((used_kb - ${ws_kb[$ws]:-0}))
    unset 'ws_kb[$ws]'
  done < <(ls -1dtr "$lease_state/work"/*/ 2>/dev/null)
  mkdir -p "$lease_state/work/.stats"
  {
    echo "measured $(date '+%F %H:%M'), $((used_kb / 1048576))G in all (retired bytes excluded, not reclaimed)"
    for ws in "${!ws_kb[@]}"; do printf '%s\t%s\n' "${ws_kb[$ws]}" "$ws"; done \
      | sort -rn | head -8 | awk -F'\t' '{ printf "%.1fG\t%s\n", $1 / 1048576, $2 }'
  } > "$lease_state/work/.stats/workspaces.new" && mv "$lease_state/work/.stats/workspaces.new" "$lease_state/work/.stats/workspaces"
}
lease_inspect() (
  local resource entry
  resource=$(lease_resource "$1") || exit 1
  lease_lock "$resource" -s || exit 1
  echo "resource=$resource identity=$(lease_identity "$resource")"
  for entry in "$lease_dir"/*.lease "$lease_dir"/*.pending; do
    [ ! -e "$entry" ] || { echo "record=$(basename "$entry")"; cat -- "$entry"; }
  done
)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -eu
  case "${1:-}" in
    retain) lease_retain "${2:?PATH}" "${3:?OWNER}" ;;
    release) lease_release "${2:?PATH}" "${3:?TOKEN}" ;;
    inspect) lease_inspect "${2:?PATH}" ;;
    *) echo 'usage: heavy-lease.sh retain PATH OWNER | release PATH TOKEN | inspect PATH' >&2; exit 2 ;;
  esac
fi
