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
# each; HEAVY_PRIORITY=1 tickets get a 30-minute head start); slots are
# flock(1)s on /work/.slots/{big,small}.
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

# The shared emulator (heavy-emulator.sh): its gRPC port, emulator-python
# (python with grpc, appended so a devShell's own python still wins), and an
# SDK with emulator_controller.proto when the job brings none.
export EMULATOR_GRPC_PORT=8554 PATH="$PATH:/nix/var/worker/android/bin"
if [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -d /nix/var/worker/android/sdk/libexec/android-sdk ]; then
  export ANDROID_SDK_ROOT=/nix/var/worker/android/sdk/libexec/android-sdk
fi

# What the queue and `heavy status` show: no values of VAR=value words, and
# nothing after --password/--token/--secret/--key style flags.
redact() {
  printf '%s' "$*" | tr '\n\t' '  ' | sed -E \
    -e 's/(^|[[:space:]"'\''])([A-Za-z_][A-Za-z0-9_]*)=[^[:space:]]*/\1\2=***/g' \
    -e 's/(--?[A-Za-z0-9-]*(password|passwd|token|secret|key|auth)[A-Za-z0-9-]*)([= ])[^[:space:]]+/\1\3***/Ig' \
    | cut -c1-300
}
display=${HEAVY_DISPLAY:-$(redact "$@")}

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

# mentions REGEX CMD...: the command line, or a script file it names (e.g.
# `bash scripts/e2e.sh`), matches REGEX.
mentions() {
  local re=$1 arg
  shift
  printf '%s ' "$@" | grep -qiE "$re" && return 0
  for arg in "$@"; do
    [ -f "$arg" ] && [ "$(stat -c %s "$arg")" -lt 1048576 ] && grep -qiE "$re" "$arg" && return 0
  done
  return 1
}

# Who the job's command runs as. Jobs are root in a privileged container, which
# gives different answers than a developer's machine for anything
# permission-dependent: root never gets EACCES (2026-11-14: a wasm-box test of
# EACCES passed only because of that). Two ways to get an unprivileged
# process, both built on `setpriv` and the `nobody` user (65534):
#   HEAVY_USER=nobody   (`heavy -e HEAVY_USER=nobody`) the whole command runs as
#                       nobody, with the workspace readable to it (below);
#   $HEAVY_UNPRIV       in every job: a command prefix for one step of a root
#                       job, `$HEAVY_UNPRIV ./target/debug/deps/x-1a2b --test`.
# HEAVY_USER=root says root, which is the default (default_user=0). Nobody can
# read the workspace but not write it, the caches or the Nix store: build as
# root, run the permission-sensitive step as nobody.
#
# For tests that need user namespaces with subordinate ids (a jail's
# unprivileged path), HEAVY_USERNS=1 (`heavy -e HEAVY_USERNS=1`) adds the user
# `heavytest` (uid 20000, subuid/subgid 2000000+131072), newuidmap/newgidmap,
# a cgroup subtree delegated to it for this job, and the prefix
# $HEAVY_UNPRIV_NS (heavy-userns.sh, below). HEAVY_USER=test runs the whole
# command as heavytest (and implies HEAVY_USERNS=1).
default_user=0
user_mode=$default_user
userns=0
case "${HEAVY_USER:-}" in
  1 | user | nobody | yes | true) user_mode=1 ;;
  test | heavytest) user_mode=2 userns=1 ;;
  0 | root | no | false) user_mode=0 ;;
esac
case "${HEAVY_USERNS:-}" in
  1 | yes | true) userns=1 ;;
esac

class=${HEAVY_CLASS:-auto}
[ "${HEAVY_LIGHT:-0}" != 1 ] || class=service
if [ "$class" = auto ]; then
  class=small
  big='\b(gradle|gradlew|assemble(release|debug)|bundlerelease|expo (run|prebuild|export)|eas build|emulator)\b'
  if mentions "$big" "$@"; then
    class=big
  fi
fi

# The emulator holds the big slot while it runs (heavy-emulator.sh). A big
# job that uses adb or the emulator runs inside that reservation instead of
# queueing behind it; other big jobs wait.
emulator_holds() { [ -f /work/.slots/big.job ] && cut -f3 /work/.slots/big.job 2> /dev/null | grep -qx .emulator; }
shared=""
if [ "$class" = big ] && [ "$ws" != /work/.emulator ] && emulator_holds; then
  uses='\b(adb|emulator)\b'
  if mentions "$uses" "$@"; then
    mkdir -p /work/.slots/shared
    shared=/work/.slots/shared/$$
    printf '%s\t%s\t%s\t%s\n' "$(date +%T)" big "$(basename "$ws")" "$display" > "$shared"
    trap 'rm -rf "$run" "$shared"' EXIT
    echo "heavy: running alongside the emulator, inside its big-slot reservation" >&2
  fi
fi

# `heavy --cpus N` (HEAVY_CPUS_WANT): exclusive cores for the job's whole run
# (cores.sh). One pinned job at a time, in the order they ask; the lock is
# taken before the slot queue so a waiting pinned job does not sit on a slot.
pin=""
if [ -n "${HEAVY_CPUS_WANT:-}" ]; then
  half=$(($(nproc --all) / 2))
  if ! [[ $HEAVY_CPUS_WANT =~ ^[1-9][0-9]*$ ]] || [ "$HEAVY_CPUS_WANT" -gt "$half" ]; then
    echo "heavy: --cpus takes 1 to $half (the node has $(nproc --all) vCPUs; the rest stay for everything else)" >&2
    exit 2
  fi
  if [ -z "$cgroot" ] || [ "$class" = service ]; then
    echo "heavy: --cpus is not available here (no job cgroups, or a background service); the job was not started" >&2
    exit 96
  fi
  pin=$(bash /scripts/cores.sh list "$HEAVY_CPUS_WANT")
  mkdir -p /work/.slots
  exec 7> /work/.slots/cpus
  if ! flock -n 7; then
    echo "heavy: waiting for the pinned cores: another --cpus job holds $(cut -f2 /work/.slots/cpus.job 2> /dev/null) ($(cut -f3- /work/.slots/cpus.job 2> /dev/null | tr '\t' ' '))" >&2
    until flock -n 7; do
      [ ! -e "$run/closed" ] || exit 130
      sleep 2
    done
  fi
  printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$pin" "$(basename "$ws")" "$display" > /work/.slots/cpus.job
fi

# Bazel (cgroups.sh, housekeeping.sh): every job gets the persistent output
# root and disk cache's location. A job that uses Bazel (its command or the
# script it names mentions bazel, or HEAVY_BAZEL=1 through `heavy -e
# HEAVY_BAZEL=1`, or the directory holds a MODULE.bazel, WORKSPACE or
# .bazelversion within three levels) holds a shared lock on
# /work/.slots/bazel from here, so while it is queued or running,
# housekeeping.sh cannot take the exclusive one and prune the directory.
export HEAVY_BAZEL_DIR=/nix/var/worker/bazel HEAVY_BAZEL_RC=/nix/var/worker/bazel/heavy.bazelrc
if [ "$class" != service ] && { [ "${HEAVY_BAZEL:-0}" = 1 ] || mentions '\bbazel(isk)?\b' "$@" \
  || [ -n "$(find . -maxdepth 3 \( -name node_modules -o -name target \) -prune -o \
    \( -name MODULE.bazel -o -name WORKSPACE -o -name WORKSPACE.bazel -o -name .bazelversion \) -print -quit 2> /dev/null)" ]; }; then
  mkdir -p /work/.slots
  exec 6> /work/.slots/bazel
  # A prune of the directory holds the exclusive lock for a few minutes at
  # most; do not wait more than 30 for it.
  for _ in $(seq 1 900); do
    flock -s -n 6 && break
    [ ! -e "$run/closed" ] || exit 130
    sleep 2
  done
fi

mkdir -p /work/.stats
# Minutes a job of this class usually takes: the median of the last 10.
typical() {
  local f=/work/.stats/$1
  [ -s "$f" ] || { echo 15; return; }
  tail -10 "$f" | sort -n | awk '{a[NR]=$1} END {m=a[int((NR+1)/2)]; v=int((m+59)/60); if (v < 1) v = 1; printf "%d", v}'
}

if [ -z "$shared" ] && { [ "$class" = big ] || [ "$class" = small ]; }; then
  mkdir -p /work/.queue /work/.slots
  # Tickets are named by the time they joined (epoch ns); the slot goes to
  # the lowest name of the class. HEAVY_PRIORITY=1 (`heavy --priority`, for a
  # shared job many sessions wait on) backdates the ticket by
  # HEAVY_PRIORITY_HEADSTART minutes (default 30): it passes ordinary jobs
  # that joined less than that before it, never one that has waited longer.
  # It only decides who takes the slot next: a running job is never
  # interrupted. (2026-11-13: wasm-box's shared builder waited behind other
  # big jobs while ten lanes waited on it. The first version put priority
  # tickets ahead of every ordinary one; wasm-box's builder and tests jobs
  # re-queue each other with --priority, so they took turns in the big slot
  # and an APK release waited 1 h 45 min and more.)
  key=$(date +%s%N) mark=""
  if [ "${HEAVY_PRIORITY:-0}" = 1 ]; then
    key=$((key - ${HEAVY_PRIORITY_HEADSTART:-30} * 60000000000)) mark=" (priority)"
  fi
  ticket="/work/.queue/$key-$class-$$"
  printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$class$mark" "$(basename "$ws")" "$display" > "$ticket"
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
    # The running job can end at any moment and take this file with it. No
    # stat inside the arithmetic: a syntax error there makes bash abandon the
    # whole `if` around this loop, and the job starts without a slot.
    if since=$(stat -c %Y "/work/.slots/$class.job" 2> /dev/null); then
      ran=$((($(date +%s) - since) / 60))
      left=$((usual - ran))
      [ "$left" -ge 1 ] || left=1
    fi
    eta=$((left + ahead * usual))
    state="waiting for the $class-job slot: $ahead $class job(s) ahead of you, about $eta min (a $class job usually takes $usual min)."
    if [ "$class" = big ] && emulator_holds; then
      state="waiting for the big-job slot: the emulator holds it since $(cut -c1-5 /work/.slots/big.job 2> /dev/null) (freed by heavy emulator stop, or after 30 idle minutes); $ahead big job(s) ahead of you. Jobs that use adb or the emulator run alongside it instead."
    fi
    now=$(date +%s)
    if [ "$state" != "$last" ] && [ $((now - last_at)) -ge 60 ] || [ $((now - last_at)) -ge 300 ]; then
      echo "heavy: $state" >&2
      last=$state last_at=$now
    fi
    sleep 3
  done
  rm -f "$ticket"
fi
# Fail closed: however the queue above was left, a job that needed a slot and
# has none does not start.
if [ -n "${ticket:-}" ] && [ -z "${slot:-}" ]; then
  echo "heavy: internal error: left the queue without a job slot; the job was not started" >&2
  exit 98
fi

# Unprivileged steps. $run is the job's private directory under /tmp (removed
# with it): `unpriv` in it is nobody's TMPDIR and HOME, and $run is
# traversable (not listable) so nobody reaches it. HEAVY_UNPRIV is the prefix.
# The emulator's adb server is root's, so a job that uses it stays root.
unpriv=$run/unpriv
mkdir -m 700 "$unpriv" && chown 65534:65534 "$unpriv" && chmod 711 "$run"
export HEAVY_UNPRIV_TMP=$unpriv
export HEAVY_UNPRIV="setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=$unpriv USER=nobody LOGNAME=nobody TMPDIR=$unpriv TMP=$unpriv TEMP=$unpriv"
if [ "$user_mode" -ge 1 ] && { [ -n "$shared" ] || [ "$ws" = /work/.emulator ]; }; then
  echo "heavy: this job uses the emulator, so it runs as root, not as an unprivileged user" >&2
  user_mode=0
fi
# The test user with subordinate ids: its account, ranges and newuidmap
# (heavy-userns.sh, idempotent, declared in the repository), its own TMPDIR and
# HOME, and the prefix. The cgroup it may manage is made further down.
if [ "$userns" = 1 ]; then
  if ! bash /scripts/heavy-userns.sh ensure 3<&- 6<&- 7<&- 9<&-; then
    [ -z "${slot:-}" ] || rm -f "/work/.slots/$slot.job"
    echo "heavy: could not set up the test user for user namespaces; the job was not started" >&2
    exit 94
  fi
  unpriv_ns=$run/userns
  mkdir -m 700 "$unpriv_ns" && chown 20000:20000 "$unpriv_ns"
  export HEAVY_UNPRIV_NS_TMP=$unpriv_ns
  export HEAVY_UNPRIV_NS="setpriv --reuid=20000 --regid=20000 --clear-groups env HOME=$unpriv_ns USER=heavytest LOGNAME=heavytest TMPDIR=$unpriv_ns TMP=$unpriv_ns TEMP=$unpriv_ns"
  export HEAVY_USERNS_USER=heavytest HEAVY_USERNS_UID=20000 HEAVY_USERNS_GID=20000
  export HEAVY_USERNS_SUBID_START=2000000 HEAVY_USERNS_SUBID_COUNT=131072
fi
if [ "$user_mode" -ge 1 ]; then
  # Jobs run with umask 077 (a root-built target/ is unreadable to nobody) and
  # a workspace synced from the PC may hold modes nobody cannot read: open it
  # for reading (o+rX), not for writing.
  find "$ws" -xdev \( -type d ! -perm -005 -o -type f ! -perm -004 \) -exec chmod o+rX {} + 2> /dev/null
  # shellcheck disable=SC2086
  if [ "$user_mode" = 2 ]; then set -- $HEAVY_UNPRIV_NS "$@"; else set -- $HEAVY_UNPRIV "$@"; fi
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

# Pinned: the empty job cgroup becomes the exclusive partition before the job
# enters it, so it never runs anywhere else. Fail closed: a job that asked
# for exclusive cores and cannot have them does not start.
niceness=19
if [ -n "$pin" ]; then
  if [ -z "$jobcg" ] || ! bash /scripts/cores.sh pin "$jobcg" "$pin"; then
    [ -z "$jobcg" ] || rmdir "$jobcg" 2> /dev/null
    bash /scripts/cores.sh release
    rm -f /work/.slots/cpus.job
    [ -z "${slot:-}" ] || rm -f "/work/.slots/$slot.job"
    echo "heavy: could not reserve CPUs $pin exclusively; the job was not started" >&2
    exit 96
  fi
  # Alone on its cores, so no reason to yield to anything.
  niceness=0
  echo "heavy: pinned to CPUs $pin, exclusive for this run (no other process, pod or IRQ the node can move is on them)" >&2
fi

# A cgroup subtree the test user manages for this job (HEAVY_USERNS=1), so a
# test can make children and set memory.max/cpu.max/pids.max on them.
# Delegation (cgroup v2): a cgroup with processes cannot enable controllers for
# its children, so the job's processes go into $jobcg/main and $jobcg/delegate,
# empty, with the controllers on, is the user's. The user owns delegate and its
# control files, and $jobcg/cgroup.procs: moving a process from main into
# delegate/x needs write access to the common ancestor's cgroup.procs. The
# kernel only lets it move processes it owns. Memory is still capped by
# $jobcg (memory.max, oom.group: a child's own memory.max kills inside that
# child, not the job). Needs 755 on $jobcg (mkdir made it 700 under umask 077).
delegated=""
if [ "$userns" = 1 ]; then
  if [ -n "$jobcg" ] \
    && echo "+memory +cpu +pids" > "$jobcg/cgroup.subtree_control" 2> /dev/null \
    && mkdir -m 755 "$jobcg/main" "$jobcg/delegate" 2> /dev/null \
    && echo "+memory +cpu +pids" > "$jobcg/delegate/cgroup.subtree_control" 2> /dev/null \
    && chmod 755 "$jobcg" \
    && chown 20000:20000 "$jobcg/delegate" "$jobcg/delegate/cgroup.procs" "$jobcg/delegate/cgroup.subtree_control" \
      "$jobcg/delegate/cgroup.threads" "$jobcg/cgroup.procs"; then
    delegated=$jobcg/delegate
    target=$jobcg/main
    export HEAVY_CGROUP_DELEGATED=$delegated
    export HEAVY_CGROUP_JOB=$jobcg
  else
    echo "heavy: could not delegate a cgroup subtree to the test user (is the job cgroup there?); HEAVY_CGROUP_DELEGATED is unset" >&2
  fi
fi

# The job moves itself into its cgroup before exec, so nothing of it runs
# outside even for a moment. HEAVY_CPUS is the CPU list it may run on as it
# starts (exclusive when HEAVY_CPUS_EXCLUSIVE=1), for a benchmark's provenance.
started=$(date +%s)
# The job's umask: 077 as ever, 022 for HEAVY_USER=nobody, or HEAVY_UMASK=NNN
# (`heavy -e HEAVY_UMASK=022`), so what a root job builds can be read by the
# unprivileged step that runs it. Set for the job's fork only.
if [ -n "${HEAVY_UMASK:-}" ] && [[ $HEAVY_UMASK =~ ^0?[0-7]{3}$ ]]; then
  umask "$HEAVY_UMASK"
elif [ "$user_mode" -ge 1 ]; then
  umask 022
fi
HEAVY_CPUS_EXCLUSIVE=$([ -n "$pin" ] && echo 1 || echo 0) \
  setsid bash -c '[ -z "$1" ] || echo $$ > "$1/cgroup.procs" 2> /dev/null
    HEAVY_CPUS=$(sed -n "s/^Cpus_allowed_list:[[:space:]]*//p" /proc/self/status); export HEAVY_CPUS HEAVY_CPUS_EXCLUSIVE
    n=$2; shift 2; exec nice -n "$n" "$@"' \
  heavy-job "$target" "$niceness" "$@" < /dev/null 3<&- 6>&- 7>&- 9>&- &
job=$!
umask 077
echo "$job" > "$run/job"
[ -z "${HEAVY_JOB_PIDFILE:-}" ] || echo "$job" > "$HEAVY_JOB_PIDFILE"
# The channel closed while the job was starting.
[ ! -e "$run/closed" ] || kill -TERM -- "-$job" 2> /dev/null
wait "$job"
rc=$?
if [ -z "$shared" ] && [ -z "${HEAVY_NO_STATS:-}" ] && { [ "$class" = big ] || [ "$class" = small ]; }; then
  echo $(($(date +%s) - started)) >> "/work/.stats/$class"
fi
if [ -n "$jobcg" ] && ! grep -q '^oom_group_kill 0$' "$jobcg/memory.events" 2> /dev/null; then
  echo "heavy: the job ran out of memory ($class jobs get up to $(numfmt --to=iec < "$jobcg/memory.max")); use --big for builds, or run less at once" >&2
fi
pkill -P "$watcher" 2> /dev/null
kill "$watcher" 2> /dev/null
[ -z "${slot:-}" ] || rm -f "/work/.slots/$slot.job"
[ -z "$shared" ] || rm -f "$shared"
if [ -n "$delegated" ]; then
  # What the job and its test user left in the subtree: kill it, then remove
  # the cgroups below $jobcg deepest first, so the rmdir of $jobcg below works.
  echo 1 > "$jobcg/cgroup.kill" 2> /dev/null
  for _ in 1 2 3 4 5; do
    find "$jobcg" -mindepth 1 -depth -type d -exec rmdir {} \; 2> /dev/null
    [ -z "$(find "$jobcg" -mindepth 1 -type d 2> /dev/null)" ] && break
    sleep 0.2
  done
fi
if [ -n "$pin" ]; then
  # Stragglers the job left (daemonized children) would keep the cores.
  [ -z "$(cat "$jobcg/cgroup.procs" 2> /dev/null)" ] || echo 1 > "$jobcg/cgroup.kill" 2> /dev/null
  for _ in 1 2 3 4 5; do rmdir "$jobcg" 2> /dev/null && break; sleep 0.2; done
  bash /scripts/cores.sh release
  rm -f /work/.slots/cpus.job
fi
[ -z "$jobcg" ] || rmdir "$jobcg" 2> /dev/null || true
exit "$rc"
