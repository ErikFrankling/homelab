#!/bin/bash
# Background jobs that outlive the SSH connection (servers next to the
# emulator, long batch jobs):
#   heavy-bg.sh start <workspace> <subdir> <develop> <name> <cmd...>
#   heavy-bg.sh stop <workspace> <name> | logs <workspace> <name> | list
# Logs and pids live in <workspace>/.heavy/. The emulator reaches anything
# listening here at 10.0.2.2.
set -u
action=$1
shift
case "$action" in
  start)
    ws=$1 sub=$2 develop=$3 name=$4
    shift 4
    mkdir -p "$ws/.heavy"
    pidfile="$ws/.heavy/$name.pid"
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2> /dev/null; then
      echo "heavy: $name is already running (pid $(cat "$pidfile"))" >&2
      exit 1
    fi
    # heavy-run records the job's process group here, for stop.
    export HEAVY_JOB_PIDFILE="$ws/.heavy/$name.job"
    # heavy-run with stdin that never closes: the job lives until stopped.
    setsid bash -c 'exec bash /config/heavy-run.sh "$@" < <(exec sleep 2147483647)' heavy-bg \
      "$ws" "$sub" "$develop" "$@" > "$ws/.heavy/$name.log" 2>&1 < /dev/null &
    echo $! > "$pidfile"
    echo "started $name (pid $!), log: $ws/.heavy/$name.log"
    ;;
  stop)
    ws=$1 name=$2
    pidfile="$ws/.heavy/$name.pid" job="$ws/.heavy/$name.job"
    [ -f "$pidfile" ] || { echo "heavy: no job $name" >&2; exit 1; }
    [ ! -f "$job" ] || kill -TERM -- "-$(cat "$job")" 2> /dev/null || true
    if kill -TERM -- "-$(cat "$pidfile")" 2> /dev/null; then echo "stopped $name"; else echo "$name was not running"; fi
    rm -f "$pidfile" "$job"
    ;;
  logs)
    ws=$1 name=$2
    tail -n "${HEAVY_LOG_LINES:-100}" "$ws/.heavy/$name.log"
    ;;
  list)
    for pidfile in /work/*/.heavy/*.pid; do
      [ -e "$pidfile" ] || continue
      state=stopped
      kill -0 "$(cat "$pidfile")" 2> /dev/null && state=running
      echo "$(basename "$(dirname "$(dirname "$pidfile")")")  $(basename "$pidfile" .pid)  $state"
    done
    ;;
  *) echo "usage: heavy-bg.sh start|stop|logs|list ..." >&2; exit 2 ;;
esac
