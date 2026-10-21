#!/bin/bash
# Runs one `heavy` job: heavy-run.sh <workspace> <subdir> <develop> <cmd...>
# <develop> is auto (the flake's default devShell if it has one), no, or a
# devShell name.
#
# Scheduling: at most /nix/var/worker/slots jobs run at once; the rest wait
# in a FIFO queue (/work/.queue, one ticket each). Slots are flock(1)s on
# /work/.slots/N, held for the job's lifetime. HEAVY_LIGHT=1 (servers from
# `heavy bg --light`) skips the queue and runs in the small light/ cgroup.
#
# The job gets its own process group and cgroup (cgroups.sh). This script's
# stdin is the SSH channel, which the PC keeps open for the job's lifetime:
# when it closes (Ctrl-C, the agent stopped, the connection dropped) the job
# is killed, or leaves the queue if it was still waiting.
set -u
ws=$1 sub=$2 develop=$3
shift 3
cd "$ws/$sub" || { echo "heavy: no directory $ws/$sub on the worker" >&2; exit 97; }
touch "$ws"
slots=$(cat /nix/var/worker/slots 2> /dev/null || echo 2)
cgroot=$(cat /nix/var/worker/cgroup 2> /dev/null || true)
run=$(mktemp -d /tmp/heavy-run.XXXXXX)
trap 'rm -rf "$run"' EXIT

# Background jobs get /dev/null as stdin in a non-interactive shell, so the
# watcher reads the channel through fd 3.
exec 3<&0
(
  cat <&3 > /dev/null
  touch "$run/closed"
  if [ -f "$run/job" ]; then
    job=$(cat "$run/job")
    kill -TERM -- "-$job" 2> /dev/null && sleep 10 && kill -KILL -- "-$job" 2> /dev/null
  fi
) > /dev/null 2>&1 &
watcher=$!

if [ "${HEAVY_LIGHT:-0}" != 1 ]; then
  mkdir -p /work/.queue /work/.slots
  ticket="/work/.queue/$(date +%s%N)-$$"
  printf '%s\t%s\t%s\n' "$(date +%T)" "$(basename "$ws")" "$*" > "$ticket"
  trap 'rm -rf "$run" "$ticket"' EXIT
  last=""
  while :; do
    [ ! -e "$run/closed" ] || exit 130
    # Forget tickets of jobs that went away while waiting.
    for t in /work/.queue/*; do
      [ -e "$t" ] || continue
      kill -0 "${t##*-}" 2> /dev/null || rm -f "$t"
    done
    ahead=0
    for t in /work/.queue/*; do
      [ -e "$t" ] && [ "$t" \< "$ticket" ] && ahead=$((ahead + 1))
    done
    if [ "$ahead" = 0 ]; then
      for i in $(seq 1 "$slots"); do
        exec 9> "/work/.slots/$i"
        if flock -n 9; then
          slot=$i
          printf '%s\t%s\t%s\n' "$(date +%T)" "$(basename "$ws")" "$*" > "/work/.slots/$slot.job"
          break 2
        fi
        exec 9>&-
      done
    fi
    state="waiting for a slot ($ahead ahead of you, $slots jobs running)"
    [ "$state" = "$last" ] || { echo "heavy: $state" >&2; last=$state; }
    sleep 3
  done
  rm -f "$ticket"
fi

if [ "$develop" != no ] && [ -f "$ws/flake.nix" ] && grep -q devShell "$ws/flake.nix"; then
  shell=default
  [ "$develop" = auto ] || shell=${develop#.#}
  # --profile roots the shell, so the store's garbage collector (which runs
  # often on this tight disk) does not throw it away between runs.
  mkdir -p "$ws/.heavy"
  set -- nix develop --profile "$ws/.heavy/shell-$shell" "$ws#$shell" -c "$@"
fi

# Own cgroup: if the jobs/ pool runs out of memory, the whole job (and only
# it) is killed.
jobcg=""
if [ -n "$cgroot" ]; then
  if [ "${HEAVY_LIGHT:-0}" = 1 ]; then
    echo $$ > "$cgroot/light/cgroup.procs" 2> /dev/null || true
  else
    jobcg="$cgroot/jobs/job-$$"
    { mkdir -p "$jobcg" && echo 1 > "$jobcg/memory.oom.group" && echo $$ > "$jobcg/cgroup.procs"; } 2> /dev/null || jobcg=""
  fi
fi

setsid nice -n 19 "$@" < /dev/null 3<&- 9>&- &
job=$!
echo "$job" > "$run/job"
[ -z "${HEAVY_JOB_PIDFILE:-}" ] || echo "$job" > "$HEAVY_JOB_PIDFILE"
# The channel closed while the job was starting.
[ ! -e "$run/closed" ] || kill -TERM -- "-$job" 2> /dev/null
wait "$job"
rc=$?
if [ -n "$jobcg" ] && ! grep -q '^oom_group_kill 0$' "$jobcg/memory.events"; then
  echo "heavy: the job ran out of memory (the worker's job pool is $(numfmt --to=iec < "$cgroot/jobs/memory.max")); run less at once" >&2
fi
pkill -P "$watcher" 2> /dev/null
kill "$watcher" 2> /dev/null
[ -z "${slot:-}" ] || rm -f "/work/.slots/$slot.job"
if [ -n "$jobcg" ]; then
  # Leave the job's cgroup so it can go once its processes are gone.
  echo $$ > "$cgroot/system/cgroup.procs" 2> /dev/null
  rmdir "$jobcg" 2> /dev/null || true
fi
exit "$rc"
