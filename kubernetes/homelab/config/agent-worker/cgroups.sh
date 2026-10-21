#!/bin/bash
set -euo pipefail
# Run by entrypoint.sh. Splits the container's cgroup so one job cannot
# take the pod down. Kubernetes sets memory.oom.group=1 on the container: if
# the container as a whole hits its limit, every process in it dies (on
# 2026-10-21 a job did that and took a running emulator with it). So each
# kind of work gets a sub-cgroup whose limits add up to less than the pod
# limit, and an OOM stays inside the sub-cgroup that caused it:
#   system/    sshd, the janitor, this script (no limit; small)
#   jobs/      heavy jobs, one job-<pid>/ each; the whole job dies on OOM
#   light/     `heavy bg --light` servers
#   emulator/  the one Android emulator
# Sizes come from the Deployment (WORKER_*), CPU as cores.
cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
if [ -w "$cg/cgroup.subtree_control" ]; then
  mkdir -p "$cg/system" "$cg/jobs" "$cg/light" "$cg/emulator"
  # No processes may stay in a cgroup that hands controllers to children.
  while read -r pid; do echo "$pid" > "$cg/system/cgroup.procs" 2> /dev/null || true; done < "$cg/cgroup.procs"
  echo "+memory +cpu +pids" > "$cg/cgroup.subtree_control"
  echo "+memory +cpu +pids" > "$cg/jobs/cgroup.subtree_control"
  cores() { echo "$(( $1 * 100000 )) 100000"; }
  echo "$WORKER_JOBS_MEMORY" > "$cg/jobs/memory.max"
  cores "$WORKER_JOBS_CPUS" > "$cg/jobs/cpu.max"
  echo "$WORKER_LIGHT_MEMORY" > "$cg/light/memory.max"
  cores 1 > "$cg/light/cpu.max"
  echo "$WORKER_EMULATOR_MEMORY" > "$cg/emulator/memory.max"
  cores "$WORKER_EMULATOR_CPUS" > "$cg/emulator/cpu.max"
  # Swap would only slow the node down; there is none on naiaclaw anyway.
  for sub in jobs light emulator; do echo 0 > "$cg/$sub/memory.swap.max" 2> /dev/null || true; done
  echo "$cg" > /nix/var/worker/cgroup
  echo "cgroups: jobs $WORKER_JOBS_MEMORY/${WORKER_JOBS_CPUS} cores, emulator $WORKER_EMULATOR_MEMORY/${WORKER_EMULATOR_CPUS} cores, light $WORKER_LIGHT_MEMORY"
else
  rm -f /nix/var/worker/cgroup
  echo "cgroups: $cg is not writable; jobs run without their own limits" >&2
fi
