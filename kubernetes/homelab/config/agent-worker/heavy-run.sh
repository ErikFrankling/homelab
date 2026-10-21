#!/bin/bash
# Runs one `heavy` job: heavy-run.sh <workdir> <develop: auto|no|NAME> <cmd...>
# The job gets its own process group. This script's stdin is the SSH channel,
# which the PC keeps open for the job's lifetime: when it closes (Ctrl-C, the
# agent stopped, the connection dropped) the whole job is killed.
set -u
dir=$1 develop=$2
shift 2
cd "$dir" || { echo "heavy: no workspace $dir" >&2; exit 97; }
touch "$dir"

if [ "$develop" != no ] && [ -f flake.nix ] && grep -q devShell flake.nix; then
  shell=.#default
  [ "$develop" = auto ] || shell=".#$develop"
  set -- nix develop "$shell" -c "$@"
fi

setsid "$@" < /dev/null &
job=$!
(
  cat > /dev/null
  kill -TERM -- "-$job" 2> /dev/null && sleep 10 && kill -KILL -- "-$job" 2> /dev/null
) &
watcher=$!
wait "$job"
rc=$?
kill "$watcher" 2> /dev/null
exit "$rc"
