#!/bin/bash
# `heavy status`: load, memory against the pod limit, jobs, emulator, disk.
echo "load: $(cut -d' ' -f1-3 /proc/loadavg)  (node has $(nproc) threads, shared with the cluster)"
current=$(cat /sys/fs/cgroup/memory.current) max=$(cat /sys/fs/cgroup/memory.max)
echo "memory: $((current / 1048576)) MiB used of $((max / 1048576)) MiB pod limit"
echo "disk: $(df -h --output=avail /nix | tail -1 | tr -d ' ') free on the node"
echo "emulator: $(pgrep -f qemu-system > /dev/null && echo running || echo stopped)"
echo "jobs:"
ps -eo pid,etime,pcpu,rss,args --sort=-pcpu | grep -v -E 'sshd|ps -eo|heavy-status|grep|janitor|sleep 3600|entrypoint' | head -15
echo "workspaces:"
du -sh /work/*/ 2> /dev/null | sort -rh | head -10
