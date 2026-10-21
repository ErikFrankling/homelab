#!/bin/bash
# `heavy status` / `heavy queue`: load, memory, slots, queue, emulator, disk.
echo "load: $(cut -d' ' -f1-3 /proc/loadavg)  (node has $(nproc) threads, shared with the cluster)"
cgroot=$(cat /nix/var/worker/cgroup 2> /dev/null || true)
if [ -n "$cgroot" ]; then
  mib() { echo $(( $(cat "$1") / 1048576 )); }
  echo "memory: pod $(mib "$cgroot/memory.current")/$(mib "$cgroot/memory.max") MiB;" \
    "jobs $(mib "$cgroot/jobs/memory.current")/$(mib "$cgroot/jobs/memory.max")," \
    "emulator $(mib "$cgroot/emulator/memory.current")/$(mib "$cgroot/emulator/memory.max")," \
    "light $(mib "$cgroot/light/memory.current")/$(mib "$cgroot/light/memory.max")"
fi
echo "disk: $(df -h --output=avail /nix | tail -1 | tr -d ' ') free on the node"
echo "emulator: $(pgrep -f 'qemu-system.*-avd' > /dev/null && echo running || echo stopped)"
slots=$(cat /nix/var/worker/slots 2> /dev/null || echo 2)
echo "running jobs ($slots slots):"
for i in $(seq 1 "$slots"); do
  if [ -f "/work/.slots/$i.job" ] && ! flock -n "/work/.slots/$i" true 2> /dev/null; then
    echo "  [$i] $(tr '\t' ' ' < "/work/.slots/$i.job" | cut -c1-150)"
  fi
done
echo "waiting:"
for t in /work/.queue/*; do
  [ -e "$t" ] || continue
  kill -0 "${t##*-}" 2> /dev/null && echo "  $(tr '\t' ' ' < "$t" | cut -c1-150)"
done
echo "background jobs:"
bash /config/heavy-bg.sh list | sed 's/^/  /'
echo "workspaces:"
du -sh /work/*/ 2> /dev/null | sort -rh | head -8 | sed 's/^/  /'
