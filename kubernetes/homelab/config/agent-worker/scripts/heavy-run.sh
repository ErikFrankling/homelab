#!/bin/bash
# Runs one `heavy` job: heavy-run.sh <workspace> <subdir> <develop> <cmd...>
# <develop> is auto (the flake's default devShell if it has one), no, or a
# devShell name.
#
# Scheduling: two slots, "big" and "small" (see below); the rest wait in a
# FIFO queue per class (/work/.queue, one ticket each). Slots are flock(1)s
# on /work/.slots/{big,small}, held for the job's lifetime. HEAVY_LIGHT=1
# (servers from `heavy bg --light`) skips the queue and runs in the small light/ cgroup.
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
class=light
bash /scripts/cgroups.sh 2> /dev/null || true
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
  # Big jobs (Gradle/Expo/APK builds, anything that drives the emulator) run
  # one at a time in the "big" slot with up to WORKER_BIG_MEMORY; small jobs
  # (typechecks, tests, scripts) take the "small" slot with up to
  # WORKER_SMALL_MEMORY, or the big one while no big job waits. HEAVY_CLASS
  # (from `heavy --big/--small`) overrides the guess.
  class=${HEAVY_CLASS:-auto}
  if [ "$class" = auto ]; then
    class=small
    big='gradle|gradlew|assemble(release|debug)|bundlerelease|expo (run|prebuild|export)|eas build|emulator'
    if printf '%s ' "$@" | grep -qiE "$big" \
      || { [ -f "$1" ] && grep -qiE "$big" "$1"; }; then
      class=big
    fi
  fi
  mkdir -p /work/.queue /work/.slots
  ticket="/work/.queue/$(date +%s%N)-$class-$$"
  printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$class" "$(basename "$ws")" "$*" > "$ticket"
  trap 'rm -rf "$run" "$ticket"' EXIT
  last=""
  take() {
    exec 9> "/work/.slots/$1"
    if flock -n 9; then
      slot=$1
      printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$class" "$(basename "$ws")" "$*" > "/work/.slots/$slot.job"
      return 0
    fi
    exec 9>&-
    return 1
  }
  while :; do
    [ ! -e "$run/closed" ] || exit 130
    # Forget tickets of jobs that went away while waiting.
    for t in /work/.queue/*; do
      [ -e "$t" ] || continue
      kill -0 "${t##*-}" 2> /dev/null || rm -f "$t"
    done
    ahead=0 bigs=0
    for t in /work/.queue/*; do
      [ -e "$t" ] || continue
      case "$t" in *-big-*) bigs=$((bigs + 1)) ;; esac
      case "$t" in *"-$class-"*) [ "$t" \< "$ticket" ] && ahead=$((ahead + 1)) ;; esac
    done
    if [ "$ahead" = 0 ]; then
      if [ "$class" = big ]; then
        take big "$@" && break
      else
        take small "$@" && break
        [ "$bigs" != 0 ] || { take big "$@" && break; }
      fi
    fi
    state="waiting for the $class-job slot ($ahead $class jobs ahead of you)"
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
    cap=$(cat "/nix/var/worker/memory-$class" 2> /dev/null || echo max)
    { mkdir -p "$jobcg" && echo "$cap" > "$jobcg/memory.max" && echo 1 > "$jobcg/memory.oom.group" \
      && echo $$ > "$jobcg/cgroup.procs"; } 2> /dev/null || jobcg=""
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
  echo "heavy: the job ran out of memory ($class jobs get up to $(numfmt --to=iec < "$jobcg/memory.max"), all jobs together $(numfmt --to=iec < "$cgroot/jobs/memory.max")); use --big for builds, or run less at once" >&2
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
