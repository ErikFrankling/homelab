#!/bin/bash
# heavy-emulator.sh start|stop|status — the single agent emulator (pixel_7,
# API 36 google_apis x86_64, the T3 Code fork's image).
#
# It runs in this pod, so `heavy` commands share its network: the emulator
# reaches their servers at 10.0.2.2, and their `adb` sees it as the only
# device. This pod's adb server owns it; the PC reaches that server through an
# SSH tunnel to 127.0.0.1:5037 (`heavy emulator start` sets that up).
#
# The emulator holds the big job slot while it runs: next to a Gradle build
# it starved (System UI ANRs, tests failing). `start` queues for the slot like
# a big job, through heavy-run.sh, which then runs `boot` here. `boot` starts
# the emulator and keeps the slot until the emulator stops (`stop`, or 30 idle
# minutes). Big jobs that use adb or the emulator run inside that reservation
# instead of queueing behind it (heavy-run.sh); other big jobs wait.
set -euo pipefail
state=/nix/var/worker/android
avd=pixel_7
idle_minutes=${HEAVY_EMULATOR_IDLE_MINUTES:-30}
export ANDROID_USER_HOME="$state/user" ANDROID_AVD_HOME="$state/avd" ANDROID_EMULATOR_HOME="$state/user"
log="$state/emulator.log"
hold_log="$state/hold.log"

sdk() {
  local link="$state/sdk"
  if [ ! -e "$link/libexec/android-sdk/emulator/emulator" ]; then
    echo "heavy: fetching the Android SDK and system image (first time takes a while)" >&2
    nix-build /scripts/android.nix --argstr nixpkgsRev "$(cat /nix/var/worker/nixpkgs-rev)" -o "$link" >&2
  fi
  echo "$(readlink -f "$link")/libexec/android-sdk"
}

grpc_port=8554

# PulseAudio (null sink "heavy") and python with grpc, from the pod's pinned
# nixpkgs, rooted under $state so garbage collection keeps them. Prints the
# env's path; starts the sound server if it is not running.
audio() {
  local env=$state/emu-audio rev
  if [ ! -e "$env/bin/pulseaudio" ]; then
    rev=$(cat /nix/var/worker/nixpkgs-rev)
    nix-build -o "$env" -E "let p = import (builtins.fetchTarball \"https://github.com/NixOS/nixpkgs/archive/$rev.tar.gz\") {}; in p.buildEnv { name = \"emu-audio\"; paths = [ p.pulseaudio (p.python3.withPackages (ps: [ ps.grpcio ps.grpcio-tools ps.protobuf ])) ]; }" >&2 || return 1
  fi
  mkdir -p "$state/bin" /run/heavy-pulse
  ln -sfn "$(readlink -f "$env")/bin/python3" "$state/bin/emulator-python"
  if ! PULSE_SERVER=unix:/run/heavy-pulse/native "$env/bin/pactl" info > /dev/null 2>&1; then
    PULSE_RUNTIME_PATH=/run/heavy-pulse HOME=/root "$env/bin/pulseaudio" --daemonize=yes \
      --exit-idle-time=-1 --disallow-exit -n --load="module-null-sink sink_name=heavy" \
      --load="module-native-protocol-unix auth-anonymous=1 socket=/run/heavy-pulse/native" \
      --log-target=file:/run/heavy-pulse/log >&2 || return 1
  fi
  echo "$env"
}

running() { pgrep -f "qemu-system.*-avd $avd" > /dev/null; }
holder_running() { [ -f "$state/holder.pid" ] && kill -0 "$(cat "$state/holder.pid")" 2> /dev/null; }

case "${1:-status}" in
  start)
    if running; then echo "already running"; exit 0; fi
    if ! holder_running; then
      mkdir -p /work/.emulator
      rm -f "$state/booted" "$state/boot-failed"
      : > "$hold_log"
      # The holder: heavy-run queues for the big slot, then runs `boot`. Its
      # stdin never closes, so it lives until `stop` or the emulator ends.
      HEAVY_CLASS=big HEAVY_DISPLAY="the emulator (pixel_7)" HEAVY_NO_STATS=1 \
        setsid bash -c 'exec bash /scripts/heavy-run.sh /work/.emulator . no bash /scripts/heavy-emulator.sh boot < <(exec sleep 2147483647)' \
        > "$hold_log" 2>&1 < /dev/null &
      echo $! > "$state/holder.pid"
    fi
    echo "heavy: the emulator takes the big job slot; leaving the queue: heavy emulator stop" >&2
    shown=0
    for _ in $(seq 1 7200); do
      lines=$(wc -l < "$hold_log")
      if [ "$lines" -gt "$shown" ]; then
        tail -n +"$((shown + 1))" "$hold_log" | head -n "$((lines - shown))" >&2
        shown=$lines
      fi
      [ ! -f "$state/booted" ] || { cat "$state/booted"; exit 0; }
      if [ -f "$state/boot-failed" ] || ! holder_running; then
        echo "emulator did not start; last log lines:" >&2
        tail -20 "$log" 2> /dev/null >&2 || true
        exit 1
      fi
      sleep 1
    done
    echo "still waiting after 2 hours; giving up (heavy emulator stop to leave the queue)" >&2
    exit 1
    ;;
  boot)
    # Run by heavy-run.sh once the big slot is ours.
    fail() { echo "$*" >&2; touch "$state/boot-failed"; exit 1; }
    root=$(sdk) || fail "could not fetch the SDK"
    export ANDROID_SDK_ROOT="$root" ANDROID_HOME="$root"
    image=$(ls -d "$root"/system-images/android-*/google_apis/x86_64 | sort -V | tail -1)
    api=$(basename "$(dirname "$(dirname "$image")")")
    mkdir -p "$ANDROID_AVD_HOME/$avd.avd" "$ANDROID_USER_HOME"
    cat > "$ANDROID_AVD_HOME/$avd.ini" <<INI
avd.ini.encoding=UTF-8
path=$ANDROID_AVD_HOME/$avd.avd
target=$api
INI
    cat > "$ANDROID_AVD_HOME/$avd.avd/config.ini" <<INI
image.sysdir.1=${image#"$root"/}/
tag.id=google_apis
abi.type=x86_64
hw.cpu.arch=x86_64
hw.cpu.ncore=4
hw.ramSize=4096
disk.dataPartition.size=8G
hw.device.name=pixel_7
hw.device.manufacturer=Google
hw.lcd.width=1080
hw.lcd.height=2400
hw.lcd.density=420
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
PlayStore.enabled=false
INI
    # The adb server must outlive this session.
    setsid adb start-server > /dev/null 2>&1 < /dev/null || true
    # Its own capped cgroup (cgroups.sh), so a job running out of memory never
    # takes it down, nor it a job; and normal priority, not the jobs' nice 19.
    bash /scripts/cgroups.sh 2> /dev/null || true
    cgroot=$(cat /nix/var/worker/cgroup 2> /dev/null || true)
    [ -z "$cgroot" ] || echo $$ > "$cgroot/emulator/cgroup.procs" 2> /dev/null || true
    renice -n 0 -p $$ > /dev/null 2>&1 || true
    # Audio for measured tests (Read aloud): the emulator plays into a
    # PulseAudio null sink in this pod (-allow-host-audio needs a host
    # backend), and its gRPC controller on 8554 streams what it plays
    # (streamAudio) and feeds the microphone (injectAudio). emulator-python
    # (on every job's PATH) has grpcio, grpcio-tools and protobuf for
    # scripts/voice-e2e/android/emulator_audio.py.
    audio_env=$(audio) || fail "could not set up emulator audio"
    export PULSE_SERVER=unix:/run/heavy-pulse/native
    setsid "$root/emulator/emulator" -avd "$avd" -port 5554 -no-window \
      -allow-host-audio -grpc "$grpc_port" \
      -no-boot-anim -no-snapshot -gpu swiftshader_indirect -accel on \
      > "$log" 2>&1 < /dev/null &
    : "$audio_env"
    booted=0
    for _ in $(seq 1 240); do
      if [ "$(adb -s emulator-5554 shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ]; then
        booted=1
        break
      fi
      running || fail "the emulator died while booting"
      sleep 2
    done
    [ "$booted" = 1 ] || { pkill -f "qemu-system.*-avd $avd" || true; fail "the emulator did not finish booting in 8 minutes"; }
    echo "booted: emulator-5554 ($avd, $api), gRPC on $grpc_port (audio: streamAudio/injectAudio; emulator-python has grpc); it holds the big job slot until heavy emulator stop" > "$state/booted"
    # Hold the slot while it runs; stop it after a while with no heavy job
    # (other than this holder) and no adb client.
    idle=0
    while running; do
      sleep 60
      if pgrep -af heavy-run.sh | grep -v ' /work/.emulator ' | grep -q . \
        || ss -Htn state established "( sport = :5037 )" | grep -q .; then
        idle=0
      else
        idle=$((idle + 1))
      fi
      if [ "$idle" -ge "$idle_minutes" ]; then
        echo "idle for $idle_minutes minutes; stopping" >> "$log"
        pkill -f "qemu-system.*-avd $avd" || true
      fi
    done
    rm -f "$state/booted"
    ;;
  stop)
    stopped=0
    if running; then
      adb -s emulator-5554 emu kill > /dev/null 2>&1 || true
      sleep 3
      pkill -f "qemu-system.*-avd $avd" || true
      stopped=1
    fi
    if holder_running; then
      kill -TERM -- "-$(cat "$state/holder.pid")" 2> /dev/null || true
      pkill -f 'heavy-emulator.sh boot' 2> /dev/null || true
      stopped=1
    fi
    rm -f "$state/holder.pid" "$state/booted"
    if [ "$stopped" = 1 ]; then echo "stopped (the big job slot is free again)"; else echo "not running"; fi
    ;;
  status)
    if running && holder_running; then
      echo "running: emulator-5554 ($avd), holding the big job slot since $(stat -c %y "$state/holder.pid" | cut -c12-16)"
    elif running; then
      echo "running: emulator-5554 ($avd), started before slot reservations (not holding the big slot)"
    elif holder_running; then
      echo "waiting for the big job slot"
    else
      echo stopped
    fi
    ;;
  *) echo "usage: heavy-emulator.sh start|stop|status" >&2; exit 2 ;;
esac
