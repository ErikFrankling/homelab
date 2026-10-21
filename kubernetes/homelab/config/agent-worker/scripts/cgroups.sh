#!/bin/bash
# Idempotent cgroup setup, run by heavy-run.sh and heavy-emulator.sh before
# every job (the boot-time /config/cgroups.sh can lose a race and leave the
# pod without limits). Layout, under the container's own cgroup:
#   system/    sshd, the janitor (no limit; small)
#   jobs/      big and small jobs, one job-<pid>/ each (memory.oom.group)
#   service/   `heavy bg` servers, one job-<pid>/ each; low CPU weight
#   emulator/  the one Android emulator
# Kubernetes sets memory.oom.group on the container: if the container as a
# whole hits its limit, every process in it dies. The pools below add up to
# less than the 20 GiB pod limit, so an OOM stays inside the pool and the job
# that caused it. The limits are applied on every run, so editing them here
# takes effect on the running pod (this file is in the unhashed ConfigMap).
set -u
state=/nix/var/worker
exec 8> /run/heavy-cgroups.lock
flock 8

# Pools (GiB-based units, as cgroup files take them) and per-job caps.
# jobs 12.5G + emulator 5.5G + service 1.5G = 19.5G of 20G. A big job (10G)
# and a small one (3G) at full size together exceed the jobs pool; then the
# kernel kills one of them, not the pod.
jobs_memory=12800M jobs_cpus=4
big_memory=10G small_memory=3G
emulator_memory=5632M emulator_cpus=2
service_pool_memory=1536M service_memory=1G service_cpus=2 service_weight=10

cg=""
if [ -s "$state/cgroup" ] && [ -d "$(cat "$state/cgroup")/jobs" ] \
  && grep -q memory "$(cat "$state/cgroup")/cgroup.subtree_control" 2> /dev/null; then
  cg=$(cat "$state/cgroup")
else
  # The container's own cgroup: pid 1's, minus a sub-cgroup it may sit in.
  cg=/sys/fs/cgroup$(cut -d: -f3 /proc/1/cgroup)
  cg=${cg%/system}
  [ -w "$cg/cgroup.subtree_control" ] || { echo "cgroups: $cg is not writable" >&2; exit 1; }
  mkdir -p "$cg/system" "$cg/jobs" "$cg/service" "$cg/emulator"
  # A cgroup that hands controllers to children may hold no processes. New
  # ones keep appearing (sshd sessions fork), so move and retry until it sticks.
  ok=0
  for _ in $(seq 1 50); do
    while read -r pid; do echo "$pid" > "$cg/system/cgroup.procs" 2> /dev/null || true; done < "$cg/cgroup.procs"
    if echo "+memory +cpu +pids" > "$cg/cgroup.subtree_control" 2> /dev/null; then ok=1; break; fi
    sleep 0.1
  done
  [ "$ok" = 1 ] || { echo "cgroups: could not empty $cg" >&2; exit 1; }
  echo "cgroups: set up under $cg" >&2
fi

mkdir -p "$cg/service"
for pool in jobs service; do
  echo "+memory +cpu +pids" > "$cg/$pool/cgroup.subtree_control" 2> /dev/null || true
  # Job cgroups whose processes are gone (rmdir fails on busy ones).
  rmdir "$cg/$pool"/job-* 2> /dev/null
done
# The pre-service pool for --light; gone once empty.
rmdir "$cg/light" 2> /dev/null

cores() { echo "$(($1 * 100000)) 100000"; }
echo "$jobs_memory" > "$cg/jobs/memory.max"
cores "$jobs_cpus" > "$cg/jobs/cpu.max"
echo "$service_pool_memory" > "$cg/service/memory.max"
cores "$service_cpus" > "$cg/service/cpu.max"
echo "$service_weight" > "$cg/service/cpu.weight"
echo "$emulator_memory" > "$cg/emulator/memory.max"
cores "$emulator_cpus" > "$cg/emulator/cpu.max"
for pool in jobs service emulator; do echo 0 > "$cg/$pool/memory.swap.max" 2> /dev/null || true; done
echo "$big_memory" > "$state/memory-big"
echo "$small_memory" > "$state/memory-small"
echo "$service_memory" > "$state/memory-service"
echo "$cg" > "$state/cgroup"

# Caches on the volume, shared by all jobs and kept between runs: Gradle,
# pnpm store (.local), npm, cargo, pip/uv/bun (.cache, .bun), Android.
for cache in .gradle .cache .local .npm .android .cargo .bun; do
  mkdir -p "$state/home/$cache"
  if [ ! -L "/root/$cache" ]; then
    rm -rf "/root/${cache:?}"
    ln -sfn "$state/home/$cache" "/root/$cache"
  fi
done

# Housekeeping (housekeeping.sh) at most hourly, in the background.
stamp=$state/housekeeping.stamp
if [ ! -f "$stamp" ] || [ -n "$(find "$stamp" -mmin +60)" ]; then
  touch "$stamp"
  setsid bash /scripts/housekeeping.sh >> "$state/housekeeping.log" 2>&1 < /dev/null &
fi
