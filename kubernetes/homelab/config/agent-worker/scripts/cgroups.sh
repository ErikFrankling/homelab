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
# less than the pod limit, so an OOM stays inside the pool and the job
# that caused it. The limits are applied on every run, so editing them here
# takes effect on the running pod (this file is in the unhashed ConfigMap).
set -u
state=/nix/var/worker
exec 8> /run/heavy-cgroups.lock
flock 8

# Pools (GiB-based units, as cgroup files take them) and per-job caps.
# A big job (10G) and a small one (6G; `cargo test -p wbox` needs 3 to 5G,
# 2026-11-14: 3G killed it) at full size need a 16G jobs pool, and with the
# emulator (5.5G) and services (1.5G) that is 23G: the pod limit is 24Gi.
# The jobs pool is sized from the container's own limit (the part left after
# the other pools and 512M for sshd and the kernel), at most 16G, so a pod
# that runs with a lower limit (20Gi before 2026-11-14) gets a smaller pool
# (12.8G) instead of one that lets the container hit its limit and die whole.
# When a big and a small job at full size together exceed the pool, the kernel
# kills one of them, not the pod.
jobs_want_mb=16384 jobs_cpus=4
big_memory=10G small_memory=6G
emulator_mb=5632 emulator_memory=5632M emulator_cpus=2
service_pool_mb=1536 service_pool_memory=1536M service_memory=1G service_cpus=2 service_weight=10

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
# cpuset: `heavy --cpus` pins a job to exclusive cores (cores.sh).
echo +cpuset > "$cg/cgroup.subtree_control" 2> /dev/null || true
for pool in jobs service; do
  # Traversable by others (mkdir under umask 077 made them 700): an unprivileged
  # test user reaches the cgroup subtree delegated to it (heavy-run.sh) through
  # them. Nothing in a pool is writable by others.
  chmod 755 "$cg/$pool" 2> /dev/null || true
  echo "+memory +cpu +pids +cpuset" > "$cg/$pool/cgroup.subtree_control" 2> /dev/null || true
  # Job cgroups whose processes are gone (rmdir fails on busy ones).
  # A job with a delegated subtree (heavy-run.sh) has cgroups below it: those
  # first, but only of a job whose heavy-run.sh (the pid in the name) is gone;
  # a running job's empty `delegate` must stay.
  for dead in "$cg/$pool"/job-*; do
    [ -d "$dead" ] && ! kill -0 "${dead##*job-}" 2> /dev/null \
      && find "$dead" -depth -type d -exec rmdir {} \; 2> /dev/null
  done
done
# The pre-service pool for --light; gone once empty.
rmdir "$cg/light" 2> /dev/null

cores() { echo "$(($1 * 100000)) 100000"; }
jobs_mb=$jobs_want_mb
limit=$(cat "$cg/memory.max" 2> /dev/null || echo max)
if [ "$limit" != max ]; then
  fit_mb=$((limit / 1048576 - emulator_mb - service_pool_mb - 512))
  [ "$fit_mb" -ge "$jobs_mb" ] || jobs_mb=$fit_mb
fi
echo "${jobs_mb}M" > "$cg/jobs/memory.max"
# The jobs pool's quota, unless a pinned job (`heavy --cpus`) runs: then
# cores.sh lifts it; its sweep puts it back and undoes what a pinned job that
# died left behind (exclusive lists, IRQ affinity).
echo "$jobs_cpus" > "$state/jobs-cpus"
echo "$cg" > "$state/cgroup"
bash /scripts/cores.sh sweep || cores "$jobs_cpus" > "$cg/jobs/cpu.max"
echo "$service_pool_memory" > "$cg/service/memory.max"
cores "$service_cpus" > "$cg/service/cpu.max"
echo "$service_weight" > "$cg/service/cpu.weight"
# Jobs share the pod's CPU with sshd and the emulator at the normal weight
# (`heavy bg` servers sit at $service_weight). They were cpu.idle until
# 2026-11-09: on a saturated node (load ~200) that meant no CPU at all. The
# pod's own share against other pods is config/cpu-priority/rules (200).
echo 0 > "$cg/jobs/cpu.idle" 2> /dev/null || true
echo 100 > "$cg/jobs/cpu.weight"
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

# Bazel: the output root (output bases, with the objects a big build such as
# V8 takes hours to make) and the disk cache live here, not in a workspace and
# not under .cache, so neither the workspace budget nor the .cache pruning of
# housekeeping.sh can remove them (a V8 output root in a workspace went with
# the workspace on 2026-11-14, 7.3 h of small-slot time). housekeeping.sh
# prunes this directory on its own rule: 30 GB, never while a job that uses
# Bazel is queued or running. heavy-run.sh exports HEAVY_BAZEL_DIR and
# HEAVY_BAZEL_RC to every job; the rc file is what a job passes:
#   bazel --bazelrc=$HEAVY_BAZEL_RC build ...
# or a project's .bazelrc has `try-import /nix/var/worker/bazel/heavy.bazelrc`.
bazel=$state/bazel
mkdir -p "$bazel/root" "$bazel/disk-cache"
printf '%s\n' "startup --output_user_root=$bazel/root" "build --disk_cache=$bazel/disk-cache" \
  > "$bazel/heavy.bazelrc.new" && mv -f "$bazel/heavy.bazelrc.new" "$bazel/heavy.bazelrc"

# Housekeeping (housekeeping.sh) at most hourly, in the background. It must
# not inherit fd 8: on 2026-11-09 it held this lock for an hour (a slow du
# under IO pressure) and every heavy job waited in `flock 8` behind it.
stamp=$state/housekeeping.stamp
if [ ! -f "$stamp" ] || [ -n "$(find "$stamp" -mmin +60)" ]; then
  touch "$stamp"
  setsid bash /scripts/housekeeping.sh >> "$state/housekeeping.log" 2>&1 < /dev/null 8>&- &
fi
