#!/bin/bash
# Background jobs that outlive the SSH connection:
#   heavy-bg.sh start <workspace> <subdir> <develop> <name> <cmd...>
#   heavy-bg.sh stop <workspace> <name> | logs <workspace> <name> | list
#
# By default a background job is a *service* (a server next to the emulator,
# a dev server): no job slot, a small capped cgroup with low CPU weight (see
# cgroups.sh), at most $max_services at once. A service stops itself once its
# processes have used no CPU for HEAVY_SERVICE_IDLE_HOURS (default 3), and,
# if it was started while the emulator ran, when the emulator stops.
# HEAVY_CLASS=big|small (`heavy bg --big/--small`) makes it a batch job that
# takes a slot like a foreground job instead.
#
# Logs, pids and the class live in <workspace>/.heavy/ (root-only). The
# emulator reaches anything listening here at 10.0.2.2.
set -u
umask 077
max_services=3
action=$1
shift

running() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2> /dev/null; }

case "$action" in
  start)
    ws=$1 sub=$2 develop=$3 name=$4
    shift 4
    mkdir -p "$ws/.heavy"
    pidfile="$ws/.heavy/$name.pid"
    if running "$pidfile"; then
      echo "heavy: $name is already running (pid $(cat "$pidfile"))" >&2
      exit 1
    fi
    class=${HEAVY_CLASS:-auto}
    case "$class" in big | small) ;; *) class=service ;; esac
    if [ "$class" = service ]; then
      n=0
      for p in /work/*/.heavy/*.pid; do
        [ -e "$p" ] || continue
        [ "$(cat "${p%.pid}.class" 2> /dev/null || echo legacy)" = service ] && running "$p" && n=$((n + 1))
      done
      if [ "$n" -ge "$max_services" ]; then
        echo "heavy: $n background services already run on the worker (the limit is $max_services); stop one first (heavy jobs, heavy stop NAME)" >&2
        exit 1
      fi
    fi
    echo "$class" > "$ws/.heavy/$name.class"
    # heavy-run records the job's process group here, for stop.
    export HEAVY_JOB_PIDFILE="$ws/.heavy/$name.job" HEAVY_CLASS=$class
    [ "$class" != service ] || export HEAVY_LIGHT=1
    # heavy-run with stdin that never closes: the job lives until stopped.
    setsid bash -c 'exec bash /scripts/heavy-run.sh "$@" < <(exec sleep 2147483647)' heavy-bg \
      "$ws" "$sub" "$develop" "$@" > "$ws/.heavy/$name.log" 2>&1 < /dev/null &
    echo $! > "$pidfile"
    if [ "$class" = service ]; then
      # Watchdog: idle for hours, or its emulator went away -> stop.
      emulator_at_start=0
      pgrep -f 'qemu-system.*-avd' > /dev/null && emulator_at_start=1
      setsid bash -c '
        ws=$1 name=$2 emu=$3 idle_limit=$(( ${HEAVY_SERVICE_IDLE_HOURS:-3} * 3600 ))
        pidfile=$ws/.heavy/$name.pid jobfile=$ws/.heavy/$name.job
        last_cpu=-1 idle=0
        while sleep 300; do
          [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2> /dev/null || exit 0
          why=""
          if [ "$emu" = 1 ] && ! pgrep -f "qemu-system.*-avd" > /dev/null; then
            why="the emulator it was started for stopped"
          fi
          if [ -f "$jobfile" ]; then
            pg=$(cat "$jobfile")
            cpu=$(awk -v pg="$pg" '\''{ if ($5 == pg) s += $14 + $15 } END { print s + 0 }'\'' /proc/[0-9]*/stat 2> /dev/null)
            if [ "$cpu" = "$last_cpu" ]; then idle=$((idle + 300)); else idle=0; fi
            last_cpu=$cpu
            [ "$idle" -lt "$idle_limit" ] || why="it used no CPU for ${HEAVY_SERVICE_IDLE_HOURS:-3} hours"
          fi
          if [ -n "$why" ]; then
            echo "heavy: stopping $name: $why" >> "$ws/.heavy/$name.log"
            bash /scripts/heavy-bg.sh stop "$ws" "$name" > /dev/null
            exit 0
          fi
        done' heavy-bg-watch "$ws" "$name" "$emulator_at_start" > /dev/null 2>&1 < /dev/null &
    fi
    echo "started $name ($class, pid $(cat "$pidfile")), log: heavy logs $name"
    ;;
  stop)
    ws=$1 name=$2
    pidfile="$ws/.heavy/$name.pid" job="$ws/.heavy/$name.job"
    [ -f "$pidfile" ] || { echo "heavy: no job $name" >&2; exit 1; }
    [ ! -f "$job" ] || kill -TERM -- "-$(cat "$job")" 2> /dev/null || true
    if kill -TERM -- "-$(cat "$pidfile")" 2> /dev/null; then echo "stopped $name"; else echo "$name was not running"; fi
    rm -f "$pidfile" "$job" "$ws/.heavy/$name.class"
    ;;
  logs)
    ws=$1 name=$2
    [ -f "$ws/.heavy/$name.log" ] || { echo "heavy: no log for $name" >&2; exit 1; }
    if [ "${HEAVY_LOG_FOLLOW:-0}" = 1 ] && running "$ws/.heavy/$name.pid"; then
      # Follow until the job ends (reattach after the client went away).
      exec tail -n "${HEAVY_LOG_LINES:-100}" -f --pid="$(cat "$ws/.heavy/$name.pid")" "$ws/.heavy/$name.log"
    fi
    tail -n "${HEAVY_LOG_LINES:-100}" "$ws/.heavy/$name.log"
    ;;
  list)
    for pidfile in /work/*/.heavy/*.pid; do
      [ -e "$pidfile" ] || continue
      state=stopped
      running "$pidfile" && state=running
      class=$(cat "${pidfile%.pid}.class" 2> /dev/null || echo legacy)
      echo "$(basename "$(dirname "$(dirname "$pidfile")")")  $(basename "$pidfile" .pid)  $class  $state"
    done
    ;;
  *) echo "usage: heavy-bg.sh start|stop|logs|list ..." >&2; exit 2 ;;
esac
