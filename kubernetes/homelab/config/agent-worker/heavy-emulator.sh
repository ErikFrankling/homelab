#!/bin/bash
# heavy-emulator.sh start|stop|status — the single agent emulator.
# ADB listens on 127.0.0.1:5555 inside the pod; the PC reaches it through an
# SSH tunnel (`heavy emulator start` sets that up) and `adb connect`.
set -euo pipefail
state=/nix/var/worker/android
avd=heavy
idle_minutes=${HEAVY_EMULATOR_IDLE_MINUTES:-30}
export ANDROID_USER_HOME="$state/user" ANDROID_AVD_HOME="$state/avd" ANDROID_EMULATOR_HOME="$state/user"

sdk() {
  local link="$state/sdk"
  if [ ! -e "$link/libexec/android-sdk/emulator/emulator" ]; then
    echo "heavy: fetching the Android SDK and system image (first time takes a while)" >&2
    nix-build /config/android.nix --argstr nixpkgsRev "$(cat /nix/var/worker/nixpkgs-rev)" -o "$link" >&2
  fi
  echo "$(readlink -f "$link")/libexec/android-sdk"
}

running() { pgrep -f "qemu-system.*-avd $avd" > /dev/null || pgrep -f "emulator.*-avd $avd" > /dev/null; }

case "${1:-status}" in
  start)
    if running; then echo "already running"; exit 0; fi
    root=$(sdk)
    export ANDROID_SDK_ROOT="$root" ANDROID_HOME="$root"
    image=$(ls -d "$root"/system-images/android-*/google_apis/x86_64 | sort -V | tail -1)
    mkdir -p "$ANDROID_AVD_HOME/$avd.avd" "$ANDROID_USER_HOME"
    api=$(basename "$(dirname "$(dirname "$image")")")
    cat > "$ANDROID_AVD_HOME/$avd.ini" <<INI
avd.ini.encoding=UTF-8
path=$ANDROID_AVD_HOME/$avd.avd
target=$api
INI
    cat > "$ANDROID_AVD_HOME/$avd.avd/config.ini" <<INI
image.sysdir.1=${image#"$root"/}/
abi.type=x86_64
hw.cpu.arch=x86_64
hw.cpu.ncore=4
hw.ramSize=3072
disk.dataPartition.size=6G
hw.lcd.width=1080
hw.lcd.height=2400
hw.lcd.density=420
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
PlayStore.enabled=false
INI
    log="$state/emulator.log"
    setsid "$root/emulator/emulator" -avd "$avd" -port 5554 -no-window -no-audio \
      -no-boot-anim -no-snapshot -gpu swiftshader_indirect -accel on \
      > "$log" 2>&1 < /dev/null &
    # Idle watchdog: stop it once no adb client has been connected for a while.
    setsid bash -c '
      idle=0
      while sleep 60; do
        pgrep -f "qemu-system.*-avd '"$avd"'" > /dev/null || exit 0
        if ss -Htn state established "( sport = :5555 )" | grep -q .; then idle=0; else idle=$((idle + 1)); fi
        if [ "$idle" -ge '"$idle_minutes"' ]; then
          echo "idle for '"$idle_minutes"' minutes; stopping" >> '"$log"'
          pkill -f "qemu-system.*-avd '"$avd"'"; exit 0
        fi
      done' > /dev/null 2>&1 < /dev/null &
    adb start-server > /dev/null 2>&1 || true
    for _ in $(seq 1 180); do
      if [ "$(adb -s emulator-5554 shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ]; then
        # The PC's adb, through the tunnel, must be the emulator's only client.
        adb kill-server > /dev/null 2>&1 || true
        echo "booted"; exit 0
      fi
      running || { echo "emulator died; last log lines:" >&2; tail -20 "$log" >&2; exit 1; }
      sleep 2
    done
    echo "emulator did not finish booting in 6 minutes; see $log" >&2
    exit 1
    ;;
  stop)
    pkill -f "qemu-system.*-avd $avd" && echo stopped || echo "not running"
    ;;
  status)
    if running; then echo running; else echo stopped; fi
    ;;
  *) echo "usage: heavy-emulator.sh start|stop|status" >&2; exit 2 ;;
esac
