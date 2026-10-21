#!/bin/bash
# Runs one `heavy` job: heavy-run.sh <workspace> <subdir> <develop> <cmd...>
# <develop> is auto (the flake's default devShell if it has one), no, or a
# devShell name.
#
# Classes (HEAVY_CLASS, from `heavy --big/--small`, else guessed):
#   big      Gradle/Expo/APK builds, anything that drives the emulator: one at
#            a time in the "big" slot, up to /nix/var/worker/memory-big.
#   small    typechecks, tests, scripts: the "small" slot, or the big one
#            while no big job waits; up to memory-small.
#   service  long-running servers from `heavy bg` (HEAVY_LIGHT=1 is the old
#            name): no slot, a small capped cgroup, low CPU weight.
# Big and small jobs wait in a FIFO queue per class (/work/.queue, one ticket
# each); slots are flock(1)s on /work/.slots/{big,small}.
#
# Secrets: HEAVY_ENVFILE names a 0600 file of NUL-separated VAR=value pairs
# (`heavy -e`). They go into the job's environment only, and the file is
# deleted at once. Commands shown in the queue are redacted.
#
# The job gets its own process group and cgroup (cgroups.sh). This script's
# stdin is the SSH channel, which the PC keeps open for the job's lifetime:
# when it closes (Ctrl-C, the agent stopped, the connection dropped) the job
# is killed, or leaves the queue if it was still waiting.
set -u
umask 077
ws=$1 sub=$2 develop=$3
shift 3
cd "$ws/$sub" || { echo "heavy: no directory $ws/$sub on the worker" >&2; exit 97; }
touch "$ws"
bash /scripts/cgroups.sh 2> /dev/null || true
cgroot=$(cat /nix/var/worker/cgroup 2> /dev/null || true)
run=$(mktemp -d /tmp/heavy-run.XXXXXX)
trap 'rm -rf "$run"' EXIT

if [ -n "${HEAVY_ENVFILE:-}" ] && [ -f "$HEAVY_ENVFILE" ]; then
  while IFS= read -r -d '' pair; do
    [[ $pair == [A-Za-z_]*=* ]] && export "${pair?}"
  done < "$HEAVY_ENVFILE"
  rm -f "$HEAVY_ENVFILE"
fi
unset HEAVY_ENVFILE

# What the queue and `heavy status` show: no values of VAR=value words, and
# nothing after --password/--token/--secret/--key style flags.
redact() {
  printf '%s' "$*" | tr '\n\t' '  ' | sed -E \
    -e 's/(^|[[:space:]"'\''])([A-Za-z_][A-Za-z0-9_]*)=[^[:space:]]*/\1\2=***/g' \
    -e 's/(--?[A-Za-z0-9-]*(password|passwd|token|secret|key|auth)[A-Za-z0-9-]*)([= ])[^[:space:]]+/\1\3***/Ig' \
    | cut -c1-300
}
display=$(redact "$@")

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

class=${HEAVY_CLASS:-auto}
[ "${HEAVY_LIGHT:-0}" != 1 ] || class=service
if [ "$class" = auto ]; then
  class=small
  big='\b(gradle|gradlew|assemble(release|debug)|bundlerelease|expo (run|prebuild|export)|eas build|emulator)\b'
  if printf '%s ' "$@" | grep -qiE "$big" \
    || { [ -f "$1" ] && grep -qiE "$big" "$1"; }; then
    class=big
  fi
fi

mkdir -p /work/.stats
# Minutes a job of this class usually takes: the median of the last 10.
typical() {
  local f=/work/.stats/$1
  [ -s "$f" ] || { echo 15; return; }
  tail -10 "$f" | sort -n | awk '{a[NR]=$1} END {m=a[int((NR+1)/2)]; v=int((m+59)/60); if (v < 1) v = 1; printf "%d", v}'
}

if [ "$class" = big ] || [ "$class" = small ]; then
  mkdir -p /work/.queue /work/.slots
  ticket="/work/.queue/$(date +%s%N)-$class-$$"
  printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$class" "$(basename "$ws")" "$display" > "$ticket"
  trap 'rm -rf "$run" "$ticket"' EXIT
  take() {
    exec 9> "/work/.slots/$1"
    if flock -n 9; then
      slot=$1
      printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$class" "$(basename "$ws")" "$display" > "/work/.slots/$slot.job"
      return 0
    fi
    exec 9>&-
    return 1
  }
  last="" last_at=0
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
        take big && break
      else
        take small && break
        [ "$bigs" != 0 ] || { take big && break; }
      fi
    fi
    # Estimate: what is left of the running job plus a typical job per ticket
    # ahead of this one.
    usual=$(typical "$class")
    left=$usual
    if [ -f "/work/.slots/$class.job" ]; then
      ran=$((($(date +%s) - $(stat -c %Y "/work/.slots/$class.job")) / 60))
      left=$((usual - ran))
      [ "$left" -ge 1 ] || left=1
    fi
    eta=$((left + ahead * usual))
    state="waiting for the $class-job slot: $ahead $class job(s) ahead of you, about $eta min (a $class job usually takes $usual min). Too long? when-idle runs it on the PC while Erik is away."
    now=$(date +%s)
    if [ "$state" != "$last" ] && [ $((now - last_at)) -ge 60 ] || [ $((now - last_at)) -ge 300 ]; then
      echo "heavy: $state" >&2
      last=$state last_at=$now
    fi
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

# Own cgroup for the job, not for this script: if the job runs out of memory,
# the whole job (and only it) is killed, and this script survives to say so.
target=""
jobcg=""
if [ -n "$cgroot" ]; then
  pool="jobs"
  [ "$class" != service ] || pool=service
  jobcg="$cgroot/$pool/job-$$"
  cap=$(cat "/nix/var/worker/memory-$class" 2> /dev/null || echo max)
  if { mkdir -p "$jobcg" && echo "$cap" > "$jobcg/memory.max" \
    && echo 1 > "$jobcg/memory.oom.group"; } 2> /dev/null; then
    target=$jobcg
  else
    jobcg=""
  fi
fi

# The job moves itself into its cgroup before exec, so nothing of it runs
# outside even for a moment.
started=$(date +%s)
setsid bash -c '[ -z "$1" ] || echo $$ > "$1/cgroup.procs" 2> /dev/null; shift; exec nice -n 19 "$@"' \
  heavy-job "$target" "$@" < /dev/null 3<&- 9>&- &
job=$!
echo "$job" > "$run/job"
[ -z "${HEAVY_JOB_PIDFILE:-}" ] || echo "$job" > "$HEAVY_JOB_PIDFILE"
# The channel closed while the job was starting.
[ ! -e "$run/closed" ] || kill -TERM -- "-$job" 2> /dev/null
wait "$job"
rc=$?
if [ "$class" = big ] || [ "$class" = small ]; then
  echo $(($(date +%s) - started)) >> "/work/.stats/$class"
fi
if [ -n "$jobcg" ] && ! grep -q '^oom_group_kill 0$' "$jobcg/memory.events" 2> /dev/null; then
  echo "heavy: the job ran out of memory ($class jobs get up to $(numfmt --to=iec < "$jobcg/memory.max")); use --big for builds, or run less at once" >&2
fi
pkill -P "$watcher" 2> /dev/null
kill "$watcher" 2> /dev/null
[ -z "${slot:-}" ] || rm -f "/work/.slots/$slot.job"
[ -z "$jobcg" ] || rmdir "$jobcg" 2> /dev/null || true
exit "$rc"
