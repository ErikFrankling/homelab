#!/bin/bash
# Idempotent cgroup setup, run by heavy-run.sh and heavy-emulator.sh before
# every job (the boot-time /config/cgroups.sh can lose a race and leave the
# pod without limits). Same layout and reasons as /config/cgroups.sh:
#   system/ (sshd etc.), jobs/ (one job-<pid>/ each), light/, emulator/
# with caps that add up to less than the pod limit, so an OOM stays inside
# the job that caused it. Sizes: /nix/var/worker/limits if present (written
# from the Deployment at boot), else the defaults below.
set -u
state=/nix/var/worker
exec 8> /run/heavy-cgroups.lock
flock 8

# Job cgroups whose processes are gone (rmdir fails on busy ones).
[ ! -s "$state/cgroup" ] || rmdir "$(cat "$state/cgroup")"/jobs/job-* 2> /dev/null

if [ -s "$state/cgroup" ] && [ -d "$(cat "$state/cgroup")/jobs" ] \
  && grep -q memory "$(cat "$state/cgroup")/cgroup.subtree_control" 2> /dev/null; then
  exit 0
fi

# The container's own cgroup: pid 1's, minus a sub-cgroup it may sit in.
cg=/sys/fs/cgroup$(cut -d: -f3 /proc/1/cgroup)
cg=${cg%/system}
[ -w "$cg/cgroup.subtree_control" ] || { echo "cgroups: $cg is not writable" >&2; exit 1; }

WORKER_JOBS_MEMORY=13G WORKER_JOBS_CPUS=4 WORKER_BIG_MEMORY=10G WORKER_SMALL_MEMORY=3G
WORKER_EMULATOR_MEMORY=5632M WORKER_EMULATOR_CPUS=2 WORKER_LIGHT_MEMORY=768M
# shellcheck disable=SC1091
[ ! -f "$state/limits" ] || . "$state/limits"

mkdir -p "$cg/system" "$cg/jobs" "$cg/light" "$cg/emulator"
# A cgroup that hands controllers to children may hold no processes. New ones
# keep appearing (sshd sessions fork), so move and retry until it sticks.
ok=0
for _ in $(seq 1 50); do
  while read -r pid; do echo "$pid" > "$cg/system/cgroup.procs" 2> /dev/null || true; done < "$cg/cgroup.procs"
  if echo "+memory +cpu +pids" > "$cg/cgroup.subtree_control" 2> /dev/null; then ok=1; break; fi
  sleep 0.1
done
[ "$ok" = 1 ] || { echo "cgroups: could not empty $cg" >&2; exit 1; }
echo "+memory +cpu +pids" > "$cg/jobs/cgroup.subtree_control"
cores() { echo "$(($1 * 100000)) 100000"; }
echo "$WORKER_JOBS_MEMORY" > "$cg/jobs/memory.max"
cores "$WORKER_JOBS_CPUS" > "$cg/jobs/cpu.max"
echo "$WORKER_LIGHT_MEMORY" > "$cg/light/memory.max"
cores 1 > "$cg/light/cpu.max"
echo "$WORKER_EMULATOR_MEMORY" > "$cg/emulator/memory.max"
cores "$WORKER_EMULATOR_CPUS" > "$cg/emulator/cpu.max"
for sub in jobs light emulator; do echo 0 > "$cg/$sub/memory.swap.max" 2> /dev/null || true; done
echo "$WORKER_BIG_MEMORY" > "$state/memory-big"
echo "$WORKER_SMALL_MEMORY" > "$state/memory-small"
echo "$cg" > "$state/cgroup"
echo "cgroups: set up under $cg" >&2
