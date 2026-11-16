#!/bin/bash
# Functions for heavy-run's existing monitor. There is no upstream per-tree
# disk stop in heavy; this adds sampled reassessment, NOT a filesystem quota.
budget_enabled=0
budget_error() { echo "heavy budget: $*" >&2; return 1; }
budget_event() {
  printf '%s\t%s\t%s\n' "$(date -Is)" "$1" "${2:-}" >> "$budget_receipt"
}
budget_identity() { stat -Lc '%d:%i' -- "$1"; }
budget_process_start() { # /proc comm can contain spaces and parentheses
  local line rest
  IFS= read -r line < "/proc/$1/stat" || return 1
  rest=${line##*) }; set -- $rest
  printf '%s\n' "${20}"
}
budget_measure() {
  local size free
  [ "$(budget_identity "$budget_store")" = "$budget_store_id" ] || return 1
  # timeout includes the entire measurement, not just one subprocess. One
  # traversal per sample, idle IO priority, at most 5 s plus a 1 s kill grace.
  size=$(timeout -k 1s 5s ionice -c3 du -sx -B1 -- "$budget_store") || return 1
  size=${size%%[[:space:]]*}
  free=$(timeout -k 1s 2s df --output=avail -B1 -- "$budget_store") || return 1
  free=${free##*$'\n'}; free=${free//[[:space:]]/}
  [[ $size =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] || return 1
  [ "$(budget_identity "$budget_store")" = "$budget_store_id" ] || return 1
  budget_used=$size budget_free=$free
}
budget_prepare() {
  [ "${HEAVY_DISK_STOP:-0}" = 1 ] || return 0
  budget_enabled=1
  # Fixed contract: callers cannot reduce admission/floor or silently enlarge
  # the agreed reassessment envelope. A different policy needs a source change.
  budget_limit=17179869184
  budget_floor=166429982720
  budget_admission=188978561024
  [ "${HEAVY_LONG:-0}" = 0 ] && [ "${HEAVY_WALL_CAP:-}" = 2700 ] \
    && [ "${HEAVY_WALL_GRACE:-}" = 30 ] || { budget_error 'requires LONG=0 WALL_CAP=2700 WALL_GRACE=30'; return 1; }
  [ -n "${store:-}" ] && [ -n "${HEAVY_TARGET_LEASE:-}" ] && [ -n "${CARGO_TARGET_DIR:-}" ] \
    && [ -z "${shared:-}" ] && [ "$ws" != /work/.emulator ] && [ "$class" != service ] \
    || { budget_error 'requires a dedicated leased store and non-shared batch job'; return 1; }
  budget_store=$(realpath -e -- "$store") || return 1
  [ "$(lease_resource "$CARGO_TARGET_DIR")" = "$budget_store" ] || { budget_error 'target must be inside the declared store'; return 1; }
  lease_hold "$CARGO_TARGET_DIR" "$HEAVY_TARGET_LEASE" || return 1
  # One bounded writer at a time, across workspaces; independent from owner
  # retention and job slots. The FD is inherited for the job's lifetime.
  exec {budget_writer_fd}>"$lease_dir/bounded-writer.lock" || return 1
  flock -x -n "$budget_writer_fd" || { budget_error 'another bounded writer uses this store'; return 1; }
  [[ ${HEAVY_JOB_KEY:-} =~ ^[a-f0-9]{24}$ ]] && [ -d "${HEAVY_JOB_DIR:-}" ] \
    && [ "$(realpath -e "$HEAVY_JOB_DIR")" = "$(realpath -e "/work/.jobs/$HEAVY_JOB_KEY")" ] \
    || { budget_error 'requires a detached job receipt/key'; return 1; }
  budget_receipt=$HEAVY_JOB_DIR/budget.tsv
  budget_store_id=$(budget_identity "$budget_store") || return 1
  budget_event prepare "key=$HEAVY_JOB_KEY store=$budget_store identity=$budget_store_id" || return 1
  if ! budget_measure; then
    budget_event refuse measurement-failed || true
    return 1
  fi
  budget_event admission "used=$budget_used free=$budget_free" || return 1
  [ "$budget_used" -lt "$budget_limit" ] && [ "$budget_free" -ge "$budget_admission" ] \
    || { budget_event refuse insufficient-capacity || true; return 1; }
}
budget_capture_cgroup() {
  [ "$budget_enabled" = 1 ] || return 0
  # heavy-run constructed this exact job-$$ under its jobs pool. Never accept
  # a parent slice or caller-supplied generic cgroup for cgroup.kill.
  [ "$jobcg" = "$cgroot/jobs/job-$$" ] && [ -f "$jobcg/cgroup.kill" ] \
    && [ -w "$jobcg/cgroup.kill" ] || { budget_error 'missing exact writable job cgroup'; return 1; }
  exec {budget_cgfd}<"$jobcg" || return 1
  budget_cgref=/proc/self/fd/$budget_cgfd
  budget_cg_id=$(budget_identity "$budget_cgref") || return 1
  budget_event custody "cgroup=$jobcg identity=$budget_cg_id" || return 1
}
budget_kill() {
  # Open directory FD pins the old identity even if its pathname is later
  # removed/reused. Failure never falls back to a broad PID/pattern kill.
  [ "$(budget_identity "$budget_cgref")" = "$budget_cg_id" ] || return 1
  printf '1\n' > "$budget_cgref/cgroup.kill"
}
budget_stop() { # monitor OR parent supervisor; caller has exact cgroup FD
  local reason=$1
  : > "$run/budget-failed"
  budget_event stop "$reason" || true
  # TERM is restricted to the session leader captured before the start gate
  # opened. If the leader exited, only the held cgroup is authoritative.
  if [ "$(budget_process_start "$job" 2>/dev/null)" = "$budget_job_start" ]; then
    kill -TERM -- "-$job" 2>/dev/null || true
  fi
  sleep 30
  budget_kill || { budget_event kill-failed "$reason" || true; return 1; }
  budget_event killed "$reason" || true
}
budget_check() {
  [ "$(budget_identity "$budget_cgref")" = "$budget_cg_id" ] || { budget_reason=cgroup-identity; return 1; }
  if ! budget_measure; then budget_reason=measurement-failed; return 1; fi
  budget_event sample "used=$budget_used free=$budget_free" || { budget_reason=receipt-write-failed; return 1; }
  if [ "$budget_used" -ge "$budget_limit" ]; then budget_reason=store-16GiB; return 1; fi
  if [ "$budget_free" -lt "$budget_floor" ]; then budget_reason=node-below-155GiB; return 1; fi
}

budget_supervise() {
  local completed="" first_rc
  wait -n -p completed "$job" "$monitor"
  first_rc=$?
  if [ "${completed:-}" = "$monitor" ]; then
    if [ -e "$run/budget-failed" ]; then
      # A marker records intent, never proof of a completed kill. This also
      # covers monitor SIGKILL during its TERM grace interval.
      budget_event supervisor monitor-ended-during-stop || true
      budget_kill || budget_event kill-failed supervisor || true
    elif kill -0 "$job" 2>/dev/null || [ "$first_rc" != 0 ]; then
      budget_stop "monitor-exit-$first_rc" || true
    fi
    wait "$job"
    rc=$?
  else
    rc=$first_rc
  fi
  # Leader exit is not proof of an empty cgroup (daemonized descendants).
  budget_kill || { : > "$run/budget-failed"; budget_event kill-failed completion || true; }
}
