#!/bin/bash
# Exclusive cores for `heavy --cpus N` (latency-sensitive benchmarks).
#
#   cores.sh list N         the fixed core set for N cores: the top N CPUs
#                           (N=2 on this 8-vCPU node: 6-7), so a phase runs
#                           on the same cores every time
#   cores.sh pin JOBCG LIST make the empty job cgroup JOBCG a cpuset root
#                           partition over LIST, before the job enters it
#   cores.sh release        undo after the job (JOBCG removed or not)
#   cores.sh sweep          the same, for a job that died without release;
#                           cgroups.sh runs it under its lock on every job
#
# How: a "remote" cgroup-v2 partition (kernel >= 6.7). Every ancestor of the
# job cgroup up to the node's root gets LIST in cpuset.cpus.exclusive, and the
# job cgroup becomes `root`. The kernel then takes LIST out of every other
# cgroup on the node: system.slice, k3s, every other pod and container, the
# other heavy jobs, and cgroups created while it runs. Unbound kernel
# threads follow; device IRQs and the unbound-workqueue mask are moved off
# LIST here and put back on release. Only per-CPU kernel threads (and their
# timers) stay, as on any isolated core. The cores are vCPUs of the k3s VM,
# which floats them over the host's 8 threads (docs/agent-worker.md).
#
# One pinned job at a time (heavy-run.sh holds /work/.slots/cpus). The jobs
# pool's CPU quota (cgroups.sh) would throttle the pinned job together with
# the others, so it is lifted while a partition exists; the other jobs then
# share the remaining cores.
set -u
state=/nix/var/worker
saved=$state/irq-affinity
root=/sys/fs/cgroup
all=$(cat /sys/devices/system/cpu/online)

# expand "0-2,5" -> "0 1 2 5"
expand() {
  local part out=() i
  IFS=, read -ra parts <<< "$1"
  for part in "${parts[@]}"; do
    if [[ $part == *-* ]]; then
      for ((i = ${part%-*}; i <= ${part#*-}; i++)); do out+=("$i"); done
    else
      out+=("$part")
    fi
  done
  echo "${out[@]}"
}
# hex mask of a cpu list, as the workqueue cpumask takes it
hexmask() {
  local c m=0
  for c in $(expand "$1"); do m=$((m | (1 << c))); done
  printf '%x' "$m"
}
# the online CPUs minus LIST, as a list
rest() {
  local c out=() pinned=" $(expand "$1") "
  for c in $(expand "$all"); do [[ $pinned == *" $c "* ]] || out+=("$c"); done
  local IFS=,
  echo "${out[*]}"
}
# ancestors of a cgroup below the node root, top first
chain() {
  local d=$1
  while [ "$d" != "$root" ] && [ "$d" != / ]; do
    echo "$d"
    d=$(dirname "$d")
  done | tac
}
pinned_cgroup() {
  local cg f
  cg=$(cat "$state/cgroup" 2> /dev/null) || return 1
  for f in "$cg"/jobs/job-*/cpuset.cpus.partition; do
    [ -f "$f" ] && grep -q '^root' "$f" && { dirname "$f"; return 0; }
  done
  return 1
}

irqs_off() { # LIST
  local away f
  away=$(rest "$1")
  [ -f "$saved" ] || {
    for f in /proc/irq/*/smp_affinity_list; do echo "$f $(cat "$f")"; done
    echo "/sys/devices/virtual/workqueue/cpumask $(cat /sys/devices/virtual/workqueue/cpumask)"
  } > "$saved.new" && mv "$saved.new" "$saved"
  # Per-CPU and kernel-managed IRQs refuse (EIO); they stay where they are.
  for f in /proc/irq/*/smp_affinity_list; do echo "$away" > "$f" 2> /dev/null; done
  hexmask "$away" > /sys/devices/virtual/workqueue/cpumask 2> /dev/null
  return 0
}
irqs_back() {
  local f v
  [ -f "$saved" ] || return 0
  while read -r f v; do echo "$v" > "$f" 2> /dev/null; done < "$saved"
  rm -f "$saved"
}

# Undo everything unless a pinned job still runs. Caller holds the lock.
sweep() {
  local cg d jobs_cpus
  pinned_cgroup > /dev/null && return 0
  cg=$(cat "$state/cgroup" 2> /dev/null) || return 0
  # Exclusive lists are cleared bottom-up (a child's must stay inside its
  # parent's).
  for d in $(chain "$cg/jobs" | tac); do
    [ -z "$(cat "$d/cpuset.cpus.exclusive" 2> /dev/null)" ] || echo > "$d/cpuset.cpus.exclusive" 2> /dev/null
  done
  irqs_back
  jobs_cpus=$(cat "$state/jobs-cpus" 2> /dev/null || echo 4)
  echo "$((jobs_cpus * 100000)) 100000" > "$cg/jobs/cpu.max"
}

lock() { exec 8> /run/heavy-cgroups.lock && flock 8; }

case "${1:-}" in
  list)
    n=${2:?N}
    last=$(($(expand "$all" | wc -w) - 1))
    first=$((last - n + 1))
    [ "$first" = "$last" ] && echo "$last" || echo "$first-$last"
    ;;
  pin)
    jobcg=${2:?JOBCG} cpus=${3:?LIST}
    lock
    for d in $(chain "$jobcg"); do
      parent=$(dirname "$d")
      grep -qw cpuset "$parent/cgroup.subtree_control" || echo +cpuset > "$parent/cgroup.subtree_control" || exit 1
      # A level with an empty cpuset.cpus computes an empty exclusive set
      # (6.8), so the levels in between get the full list, which is what they
      # inherit anyway. kubepods.slice already has it (kubelet's).
      if [ "$d" != "$jobcg" ] && [ -z "$(cat "$d/cpuset.cpus")" ]; then
        echo "$all" > "$d/cpuset.cpus" || exit 1
      fi
      echo "$cpus" > "$d/cpuset.cpus.exclusive" || exit 1
    done
    echo "$cpus" > "$jobcg/cpuset.cpus" || exit 1
    echo root > "$jobcg/cpuset.cpus.partition"
    got=$(cat "$jobcg/cpuset.cpus.partition")
    if [ "$got" != root ]; then
      echo "cores: $got" >&2
      echo member > "$jobcg/cpuset.cpus.partition" 2> /dev/null
      sweep
      exit 1
    fi
    cg=$(cat "$state/cgroup")
    echo max > "$cg/jobs/cpu.max"
    irqs_off "$cpus"
    ;;
  release)
    lock
    if jobcg=$(pinned_cgroup); then
      # Only an empty one: a live pinned job keeps its cores.
      if [ -z "$(cat "$jobcg/cgroup.procs" 2> /dev/null)" ]; then
        echo member > "$jobcg/cpuset.cpus.partition" 2> /dev/null
        rmdir "$jobcg" 2> /dev/null
      fi
    fi
    sweep
    ;;
  sweep) sweep ;;
  *) echo "usage: cores.sh list N | pin JOBCG LIST | release | sweep" >&2; exit 2 ;;
esac
