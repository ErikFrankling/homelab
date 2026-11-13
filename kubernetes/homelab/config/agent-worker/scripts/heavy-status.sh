#!/bin/bash
# `heavy status` / `heavy queue`: load, memory, slots, queue, services,
# emulator, disk. Commands are redacted again here, for tickets written by
# older clients.
redact() {
  tr '\n\t' '  ' | sed -E \
    -e 's/(^|[[:space:]"'\''])([A-Za-z_][A-Za-z0-9_]*)=[^[:space:]]*/\1\2=***/g' \
    -e 's/(--?[A-Za-z0-9-]*(password|passwd|token|secret|key|auth)[A-Za-z0-9-]*)([= ])[^[:space:]]+/\1\3***/Ig' \
    | cut -c1-150
}
echo "load: $(cut -d' ' -f1-3 /proc/loadavg)  (node has $(nproc) threads, shared with the cluster)"
cgroot=$(cat /nix/var/worker/cgroup 2> /dev/null || true)
if [ -n "$cgroot" ]; then
  mib() { [ -f "$1" ] && echo $(($(cat "$1") / 1048576)) || echo -; }
  echo "memory MiB: pod $(mib "$cgroot/memory.current")/$(mib "$cgroot/memory.max"), jobs $(mib "$cgroot/jobs/memory.current")/$(mib "$cgroot/jobs/memory.max"), emulator $(mib "$cgroot/emulator/memory.current")/$(mib "$cgroot/emulator/memory.max"), services $(mib "$cgroot/service/memory.current")/$(mib "$cgroot/service/memory.max")"
fi
echo "disk: $(df -h --output=avail /nix | tail -1 | tr -d ' ') free on the node"
echo "emulator: $(pgrep -f 'qemu-system.*-avd' > /dev/null && echo running || echo stopped)"
typical() {
  local f=/work/.stats/$1
  [ -s "$f" ] || { echo 15; return; }
  tail -10 "$f" | sort -n | awk '{a[NR]=$1} END {m=a[int((NR+1)/2)]; v=int((m+59)/60); if (v < 1) v = 1; printf "%d", v}'
}
echo "running jobs (one big slot, one small slot; a big job usually takes $(typical big) min, a small one $(typical small)):"
for i in big small; do
  if [ -f "/work/.slots/$i.job" ] && ! flock -n "/work/.slots/$i" true 2> /dev/null; then
    since=$(stat -c %Y "/work/.slots/$i.job" 2> /dev/null) || continue
    ran=$((($(date +%s) - since) / 60))
    if [ "$(cut -f3 "/work/.slots/$i.job")" = .emulator ]; then
      echo "  [$i] held by the emulator since $(cut -c1-5 "/work/.slots/$i.job") (${ran} min; freed by heavy emulator stop or 30 idle minutes)"
    else
      echo "  [$i, ${ran} min] $(cut -f2- "/work/.slots/$i.job" | redact)"
    fi
  fi
done
if [ -f /work/.slots/cpus.job ] && ! flock -n /work/.slots/cpus true 2> /dev/null; then
  if grep -qs '^root' "$cgroot"/jobs/job-*/cpuset.cpus.partition; then
    echo "  [pinned to CPUs $(cut -f2 /work/.slots/cpus.job), exclusive] $(cut -f3- /work/.slots/cpus.job | redact)"
  else
    echo "  [next on CPUs $(cut -f2 /work/.slots/cpus.job), waiting for its slot] $(cut -f3- /work/.slots/cpus.job | redact)"
  fi
fi
for s in /work/.slots/shared/*; do
  [ -e "$s" ] || continue
  if kill -0 "$(basename "$s")" 2> /dev/null; then
    echo "  [with the emulator] $(cut -f2- "$s" | redact)"
  else
    rm -f "$s"
  fi
done
echo "waiting:"
for t in /work/.queue/*; do
  [ -e "$t" ] || continue
  kill -0 "${t##*-}" 2> /dev/null && echo "  $(redact < "$t")"
done
echo "background jobs (services: at most 3, capped, stop when idle):"
bash /scripts/heavy-bg.sh list | sed 's/^/  /'
# Sizes from the last housekeeping run: a du of /work here took over half an
# hour under IO pressure (2026-11-09) and hung `heavy status`.
echo "workspaces (as of the last hourly housekeeping):"
sed 's/^/  /' /work/.stats/workspaces 2> /dev/null || echo "  not measured yet"
