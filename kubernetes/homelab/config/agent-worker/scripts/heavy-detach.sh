#!/bin/bash
# A `heavy` job that does not depend on its client (2026-11-14).
#
# Until then a job lived exactly as long as the SSH channel of the PC's `heavy`
# client: heavy-run.sh reads that channel's stdin and kills the job, or takes it
# out of the queue, when it closes. The client is a small ssh/bash wrapper that
# runs as an agent job at a high OOM score, so in any spike on the PC the kernel
# killed it first, and the job lost its place (17:53 that day: every wasm-box
# lane, one of them a --priority release build that had waited two hours).
#
# Now `heavy` asks this script to start the job and to follow it:
#
#   heavy-detach.sh run KEY WS REL DEVELOP CMD...   start the job for KEY, or, if
#         a job for KEY is queued or running, or finished while no client was
#         there to take its result, attach to it; then follow it (as `attach`)
#   heavy-detach.sh attach KEY   stream its stdout and stderr from the start
#         (stderr on stderr), keep it marked as attended, and exit with the
#         job's exit status when it ends (255 is reported as 254; 253 means the
#         job is gone: the worker restarted, or the result was collected)
#   heavy-detach.sh cancel KEY   what an interrupted client does: the job leaves
#         the queue, or is killed, as before
#   heavy-detach.sh list         the jobs and their state
#
# KEY is the client's hash of the workspace, the command and the options, so the
# same command from the same directory finds its job again. The job itself is
# heavy-run.sh, started in its own session with its stdin on a fifo that a
# `sleep` holds open: killing that sleep (cancel) is the old "channel closed".
# Output goes to files in /work/.jobs/KEY/ instead of the channel; attach
# copies them. A client that is killed (SIGKILL, the OOM killer) cannot cancel,
# so its job survives; one that is stopped (Ctrl-C, SIGTERM, SIGHUP) cancels
# first, as before.
#
# A job nobody has attended for 120 minutes (HEAVY_ORPHAN_MIN; the heartbeat file of an
# attach is touched twice a second) is cancelled: the queue must not fill with
# the jobs of agents that are gone. A result nobody collected is kept for 6
# hours, a collected one for 10 minutes. housekeeping.sh also calls `reap`.
set -u
jobs=/work/.jobs
orphan_secs=$((${HEAVY_ORPHAN_MIN:-120} * 60))
[[ ${HEAVY_ORPHAN_SECS:-} =~ ^[0-9]+$ ]] && orphan_secs=$HEAVY_ORPHAN_SECS
keep_hours=6

now() { date +%s; }
mtime() { stat -c %Y "$1" 2> /dev/null || echo 0; }
alive() { [ -f "$1/pid" ] && kill -0 "$(cat "$1/pid")" 2> /dev/null; }
cancel_job() { [ -f "$1/keeper" ] && kill "$(cat "$1/keeper")" 2> /dev/null; return 0; }

# Orphans cancelled, finished jobs forgotten, dead ones (a worker restart
# killed them) removed.
reap() {
  local d t
  t=$(now)
  for d in "$jobs"/*/; do
    d=${d%/}
    [ -d "$d" ] || continue
    if [ -f "$d/status" ]; then
      if [ -f "$d/consumed" ]; then
        [ $((t - $(mtime "$d/consumed"))) -gt 600 ] && rm -rf "$d"
      else
        [ $((t - $(mtime "$d/status"))) -gt $((keep_hours * 3600)) ] && rm -rf "$d"
      fi
    elif alive "$d"; then
      if [ $((t - $(mtime "$d/heartbeat"))) -gt "$orphan_secs" ] && [ ! -f "$d/orphaned" ]; then
        touch "$d/orphaned"
        cancel_job "$d"
      fi
    else
      [ $((t - $(mtime "$d"))) -gt 600 ] && rm -rf "$d"
    fi
  done
  return 0
}

# Copy what the job wrote since the last call: $d/out to stdout, $d/err to
# stderr, by byte offsets, so nothing is repeated or lost.
pump() {
  local size
  size=$(stat -c %s "$d/out" 2> /dev/null || echo 0)
  if [ "$size" -gt "$off_out" ]; then
    tail -c +$((off_out + 1)) "$d/out" | head -c $((size - off_out))
    off_out=$size
  fi
  size=$(stat -c %s "$d/err" 2> /dev/null || echo 0)
  if [ "$size" -gt "$off_err" ]; then
    tail -c +$((off_err + 1)) "$d/err" | head -c $((size - off_err)) >&2
    off_err=$size
  fi
}

attach() {
  d=$jobs/$1
  off_out=0 off_err=0
  [ -d "$d" ] || { echo "heavy: no such job on the worker (it was collected, or the worker restarted); run the command again" >&2; exit 253; }
  local finished
  while :; do
    touch "$d/heartbeat"
    finished=0
    [ -f "$d/status" ] && finished=1
    pump
    if [ "$finished" = 1 ]; then
      # The tees of heavy-run.sh may write a moment after it exited.
      sleep 1
      pump
      break
    fi
    if ! alive "$d"; then
      sleep 1
      if [ ! -f "$d/status" ]; then
        pump
        echo "heavy: the job is gone without a result (the worker restarted?); run the command again" >&2
        exit 253
      fi
    fi
    sleep 0.5
  done
  local rc
  rc=$(cat "$d/status")
  touch "$d/consumed"
  [ "$rc" != 255 ] || rc=254
  exit "$rc"
}

start_job() { # KEY WS REL DEVELOP CMD...
  local key=$1 ws=$2 rel=$3 develop=$4
  shift 4
  d=$jobs/$key
  mkdir -p "$d"
  rm -f "$d/status" "$d/consumed" "$d/orphaned" "$d/cancelled" "$d/stdin"
  : > "$d/out"
  : > "$d/err"
  touch "$d/heartbeat"
  now > "$d/started"
  printf '%s\t%s\n' "$(basename "$ws")" "$(printf '%q ' "$@")" > "$d/cmd"
  mkfifo "$d/stdin"
  # The channel heavy-run.sh watches: open while this sleep lives.
  setsid sleep 2147483647 > "$d/stdin" 3<&- 6>&- 7>&- 8>&- 9>&- &
  echo $! > "$d/keeper"
  setsid bash -c '
    d=$1; shift
    bash /scripts/heavy-run.sh "$@" < "$d/stdin" > "$d/out" 2> "$d/err"
    rc=$?
    echo "$rc" > "$d/status.tmp" && mv "$d/status.tmp" "$d/status"
    kill "$(cat "$d/keeper")" 2> /dev/null
  ' heavy-detached "$d" "$ws" "$rel" "$develop" "$@" < /dev/null > /dev/null 2>&1 3<&- 6>&- 7>&- 8>&- 9>&- &
  echo $! > "$d/pid"
}

run() { # KEY WS REL DEVELOP CMD...
  local key=$1
  mkdir -p "$jobs"
  exec 7> "$jobs/.lock-$key"
  flock 7
  d=$jobs/$key
  if [ -d "$d" ]; then
    # Collected, cancelled or orphaned results are not replayed; a job that
    # died with the worker is not waited for.
    if [ -f "$d/status" ] && { [ -f "$d/consumed" ] || [ -f "$d/orphaned" ] || [ -f "$d/cancelled" ]; }; then
      rm -rf "$d"
    elif [ ! -f "$d/status" ] && ! alive "$d"; then
      rm -rf "$d"
    fi
  fi
  if [ -d "$d" ]; then
    # The job is already here: the env file this call uploaded is not needed.
    [ -z "${HEAVY_ENVFILE:-}" ] || rm -f "$HEAVY_ENVFILE"
    if [ -f "$d/status" ]; then
      echo "heavy: this command finished while its client was away; here is its result (run it again to run it again)" >&2
    else
      echo "heavy: re-attached to the job for this command that is already queued or running here (started $(date -d "@$(cat "$d/started")" +%T)); its place and its output so far are kept" >&2
    fi
  else
    start_job "$@"
  fi
  flock -u 7
  exec 7>&-
  attach "$key"
}

case "${1:-}" in
  run)
    shift
    [ $# -ge 5 ] || { echo "usage: heavy-detach.sh run KEY WS REL DEVELOP CMD..." >&2; exit 2; }
    reap
    run "$@"
    ;;
  attach)
    reap
    attach "${2:?usage: heavy-detach.sh attach KEY}"
    ;;
  cancel)
    d=$jobs/${2:?usage: heavy-detach.sh cancel KEY}
    [ -d "$d" ] || exit 0
    touch "$d/cancelled" "$d/consumed"
    cancel_job "$d"
    ;;
  reap) reap ;;
  list)
    reap
    t=$(now)
    for d in "$jobs"/*/; do
      d=${d%/}
      [ -d "$d" ] || continue
      if [ -f "$d/status" ]; then state="finished ($(cat "$d/status")), $([ -f "$d/consumed" ] && echo collected || echo uncollected)"
      elif alive "$d"; then state="queued or running, client last seen $((t - $(mtime "$d/heartbeat"))) s ago"
      else state=dead; fi
      printf '%s\t%s\tsince %s\t%s\n' "$(basename "$d")" "$state" "$(date -d "@$(cat "$d/started" 2> /dev/null || echo 0)" +%T)" "$(cut -c1-120 "$d/cmd" 2> /dev/null | tr '\t' ' ')"
    done
    ;;
  *)
    echo "usage: heavy-detach.sh run|attach|cancel|reap|list ..." >&2
    exit 2
    ;;
esac
