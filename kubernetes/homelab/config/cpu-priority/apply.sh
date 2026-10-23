#!/bin/bash
# Applies config/cpu-priority/rules to the pod cgroups on this node, every
# 30 s. The kubelet sets cpu.weight once when it creates a pod's cgroup and
# systemd may rewrite it on a daemon-reload, so this keeps re-applying.
# Pods are found from /var/log/pods/<namespace>_<name>_<uid>, which needs no
# API access.
set -u
cg=/host/cgroup/kubepods.slice
declare -A last
while true; do
  mapfile -t rules < <(grep -Ev '^[[:space:]]*(#|$)' /rules/rules)
  declare -A seen=()
  for dir in /host/pods/*_*_*; do
    base=${dir##*/}
    ns=${base%%_*}
    rest=${base#*_}
    name=${rest%_*}
    uid=${rest##*_}
    want=""
    for rule in "${rules[@]}"; do
      read -r value nsglob podglob <<< "$rule"
      # shellcheck disable=SC2053 # globs on purpose
      if [[ $ns == $nsglob && $name == $podglob ]]; then want=$value; break; fi
    done
    [ -n "$want" ] || continue
    u=${uid//-/_}
    for pod in "$cg/kubepods-pod$u.slice" \
      "$cg/kubepods-burstable.slice/kubepods-burstable-pod$u.slice" \
      "$cg/kubepods-besteffort.slice/kubepods-besteffort-pod$u.slice"; do
      [ -d "$pod" ] || continue
      seen[$uid]=1
      if [ "$want" = idle ]; then
        [ "$(cat "$pod/cpu.idle")" = 1 ] || echo 1 > "$pod/cpu.idle"
      else
        [ "$(cat "$pod/cpu.idle")" = 0 ] || echo 0 > "$pod/cpu.idle"
        [ "$(cat "$pod/cpu.weight")" = "$want" ] || echo "$want" > "$pod/cpu.weight"
      fi
      if [ "${last[$uid]:-}" != "$want" ]; then
        echo "$(date -Iseconds) $ns/$name: $want"
        last[$uid]=$want
      fi
    done
  done
  for uid in "${!last[@]}"; do [ -n "${seen[$uid]:-}" ] || unset "last[$uid]"; done
  unset seen
  sleep 30
done
