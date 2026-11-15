#!/bin/bash
# Restarting the worker pod without losing work (docs/agent-worker.md, "Restarting
# the pod without losing work"). A restart kills every running job; jobs that are
# still queued are queued again with their place (heavy-detach.sh resume) if they
# were submitted since 2026-11-15. This script is the safe decision point:
#
#   heavy-maint.sh status             what runs, what waits, and what a restart would lose
#   heavy-maint.sh pause SCOPE MIN [REASON...]
#                                     hold new starts of resumable jobs for at most MIN
#                                     minutes (max 720): SCOPE big = the big slot only,
#                                     all = both slots. It lapses by itself.
#   heavy-maint.sh unpause            lift it
#   heavy-maint.sh idle               no pause needed: "idle" (exit 0) when nothing runs and
#                                     nothing queued would be lost, else "busy" (exit 1)
#   heavy-maint.sh check              one word and a reason, for the one who restarts:
#       wait      something still runs or something queued would be lost
#       tighten   the big slot is free and nothing non-resumable waits for it:
#                 pause SCOPE all next, then check again
#       ready     nothing runs, nothing queued would be lost, both slots held: restart now
#
# What `check` counts as a reason to wait: a job in a slot; a service (`heavy bg`);
# the emulator; a pinned-cores job; a job inside the emulator's reservation; a queued
# job that would not be re-queued (an old-style client, or submitted before resume
# existed). Queued jobs that would be kept are listed, never waited for.
set -u
pause=/work/.pause
now() { date +%s; }

paused_info() { # -> "DEADLINE SCOPE REASON" if in force, else nothing
  local dl scope rest
  [ -f "$pause" ] || return 0
  read -r dl scope rest < "$pause" 2> /dev/null || return 0
  [ "${dl:-0}" -gt "$(now)" ] 2> /dev/null || return 0
  echo "$dl $scope $rest"
}

slot_busy() { # SLOT -> 0 if a job holds it
  [ -f "/work/.slots/$1" ] || return 1
  ! flock -n "/work/.slots/$1" true 2> /dev/null
}

# Tickets: "KEY CLASS RESUMABLE" per live ticket
tickets() {
  local t pid cls res
  for t in /work/.queue/*; do
    [ -e "$t" ] || continue
    pid=${t##*-}
    kill -0 "$pid" 2> /dev/null || continue
    cls=${t%-*}; cls=${cls##*-}
    res=no
    tr '\0' '\n' < "/proc/$pid/environ" 2> /dev/null | grep -qx 'HEAVY_RESUMABLE=1' && res=yes
    # An emulator reservation holder is not a job anyone can re-queue.
    grep -q '	\.emulator	' "$t" 2> /dev/null && res=no
    echo "$(basename "$t") $cls $res"
  done
}

reasons() { # prints one reason per line
  local s
  for s in big small; do
    slot_busy "$s" && echo "the $s slot is held: $(cut -f3,4 "/work/.slots/$s.job" 2> /dev/null | tr '\t' ' ' | cut -c1-90)"
  done
  if [ -f /work/.slots/cpus.job ] && ! flock -n /work/.slots/cpus true 2> /dev/null; then echo "a --cpus job holds the pinned cores"; fi
  local sh
  for sh in /work/.slots/shared/*; do [ -e "$sh" ] && kill -0 "$(basename "$sh")" 2> /dev/null && echo "a job runs inside the emulator's reservation"; done
  [ -z "$(bash /scripts/heavy-bg.sh list 2> /dev/null | grep -v '^$' | grep -vi '^no ')" ] || echo "a background service runs (heavy bg)"
  pgrep -f 'qemu-system.*-avd' > /dev/null && echo "the emulator runs"
  local key cls res
  while read -r key cls res; do
    [ "$res" = no ] && echo "a queued $cls job would be lost (old-style client or submitted before resume existed): $key"
  done < <(tickets)
}

case "${1:-status}" in
  status)
    echo "now: $(date -Is)"
    info=$(paused_info)
    if [ -n "$info" ]; then read -r dl scope rest <<< "$info"; echo "pause: scope $scope until $(date -d "@$dl" +%T) ($rest)"; else echo "pause: none"; fi
    echo "running / blocking a restart:"; reasons | sed 's/^/  /'
    echo "queued, kept by a restart: $(tickets | grep -c ' yes$'); lost: $(tickets | grep -c ' no$')"
    ;;
  pause)
    scope=${2:?usage: heavy-maint.sh pause big|all MINUTES [REASON...]}
    min=${3:?usage: heavy-maint.sh pause big|all MINUTES [REASON...]}
    case "$scope" in big | all) ;; *) echo "scope is big or all" >&2; exit 2 ;; esac
    [[ $min =~ ^[0-9]+$ ]] && [ "$min" -ge 1 ] && [ "$min" -le 720 ] || { echo "MINUTES is 1 to 720" >&2; exit 2; }
    shift 3
    echo "$(($(now) + min * 60)) $scope ${*:-pod restart}" > "$pause.new" && mv "$pause.new" "$pause"
    echo "paused: new starts of resumable jobs held ($scope) until $(date -d "@$(($(now) + min * 60))" +%T)"
    ;;
  unpause)
    rm -f "$pause"
    echo "pause lifted"
    ;;
  idle)
    # No pause involved: is this a moment at which a restart loses nothing?
    # Exit 0 and "idle" if nothing runs and nothing queued would be lost (queued
    # resumable jobs are kept), else exit 1 and "busy" with the first reason.
    mapfile -t why < <(reasons)
    if [ ${#why[@]} -eq 0 ]; then
      echo "idle: nothing runs and nothing queued would be lost; $(tickets | grep -c ' yes$') queued job(s) would be kept"
    else
      echo "busy: ${why[0]}$([ ${#why[@]} -gt 1 ] && echo " (+$((${#why[@]} - 1)) more)")"
      exit 1
    fi
    ;;
  check)
    info=$(paused_info)
    scope=none
    [ -z "$info" ] || { read -r _ scope _ <<< "$info"; }
    mapfile -t why < <(reasons)
    if [ "$scope" = all ]; then
      if [ ${#why[@]} -eq 0 ]; then
        echo "ready: nothing runs and nothing queued would be lost; $(tickets | grep -c ' yes$') queued job(s) will be queued again after the restart"
      else
        echo "wait: ${why[0]}$([ ${#why[@]} -gt 1 ] && echo " (+$((${#why[@]} - 1)) more)")"
      fi
    else
      # Not yet holding both slots: the big slot is the long pole. Tighten when
      # nothing but resumable work could start there and nothing big is running.
      big_old=$(tickets | grep -c '^[^ ]* big no$')
      if ! slot_busy big && [ "$big_old" = 0 ] && [ "$scope" = big ]; then
        echo "tighten: the big slot is free and no non-resumable big job waits; pause all, then check again"
      elif [ "$scope" != big ]; then
        echo "wait: no pause is in force (pause big first); ${why[0]:-nothing runs}"
      else
        echo "wait: ${why[0]:-big work remains}$([ ${#why[@]} -gt 1 ] && echo " (+$((${#why[@]} - 1)) more)")"
      fi
    fi
    ;;
  *)
    echo "usage: heavy-maint.sh status|pause SCOPE MIN [REASON]|unpause|check|idle" >&2
    exit 2
    ;;
esac
