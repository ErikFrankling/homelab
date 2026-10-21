#!/bin/bash
# Runs one `heavy` job: heavy-run.sh <workspace> <subdir> <develop> <cmd...>
# <develop> is auto (the flake's default devShell if it has one), no, or a
# devShell name. The job gets its own process group. This script's stdin is
# the SSH channel, which the PC keeps open for the job's lifetime: when it
# closes (Ctrl-C, the agent stopped, the connection dropped) the job is killed.
set -u
ws=$1 sub=$2 develop=$3
shift 3
cd "$ws/$sub" || { echo "heavy: no directory $ws/$sub on the worker" >&2; exit 97; }
touch "$ws"

if [ "$develop" != no ] && [ -f "$ws/flake.nix" ] && grep -q devShell "$ws/flake.nix"; then
  shell=default
  [ "$develop" = auto ] || shell=${develop#.#}
  set -- nix develop "$ws#$shell" -c "$@"
fi

# Background jobs get /dev/null as stdin in a non-interactive shell, so keep
# the channel on fd 3 for the watcher.
exec 3<&0
setsid "$@" < /dev/null 3<&- &
job=$!
[ -z "${HEAVY_JOB_PIDFILE:-}" ] || echo "$job" > "$HEAVY_JOB_PIDFILE"
(
  cat <&3 > /dev/null
  kill -TERM -- "-$job" 2> /dev/null && sleep 10 && kill -KILL -- "-$job" 2> /dev/null
) > /dev/null 2>&1 &
watcher=$!
wait "$job"
rc=$?
pkill -P "$watcher" 2> /dev/null
kill "$watcher" 2> /dev/null
exit "$rc"
