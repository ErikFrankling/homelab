#!/bin/bash
# heavy-emulator.sh start|stop|status — the single agent emulator (pixel_7,
# API 36 google_apis x86_64, the T3 Code fork's image).
#
# It runs in this pod, so `heavy` commands share its network: the emulator
# reaches their servers at 10.0.2.2, and their `adb` sees it as the only
# device. This pod's adb server owns it; the PC reaches that server through an
# SSH tunnel to 127.0.0.1:5037 (`heavy emulator start` sets that up).
set -euo pipefail
state=/nix/var/worker/android
avd=pixel_7
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

running() { pgrep -f "qemu-system.*-avd $avd" > /dev/null; }

case "${1:-status}" in
  start)
    if running; then echo "already running"; exit 0; fi
    root=$(sdk)
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
    log="$state/emulator.log"
    # The adb server must outlive this SSH session.
    setsid adb start-server > /dev/null 2>&1 < /dev/null || true
    # The emulator gets its own capped cgroup (cgroups.sh), so a job running
    # out of memory never takes it down, nor it a job.
    cgroot=$(cat /nix/var/worker/cgroup 2> /dev/null || true)
    [ -z "$cgroot" ] || echo $$ > "$cgroot/emulator/cgroup.procs" 2> /dev/null || true
    setsid "$root/emulator/emulator" -avd "$avd" -port 5554 -no-window -no-audio \
      -no-boot-anim -no-snapshot -gpu swiftshader_indirect -accel on \
      > "$log" 2>&1 < /dev/null &
    # Idle watchdog: stop it after a while with no heavy job and no adb client.
    setsid bash -c '
      idle=0
      while sleep 60; do
        pgrep -f "qemu-system.*-avd '"$avd"'" > /dev/null || exit 0
        if pgrep -f /config/heavy-run.sh > /dev/null \
          || ss -Htn state established "( sport = :5037 )" | grep -q .; then
          idle=0
        else
          idle=$((idle + 1))
        fi
        if [ "$idle" -ge '"$idle_minutes"' ]; then
          echo "idle for '"$idle_minutes"' minutes; stopping" >> '"$log"'
          pkill -f "qemu-system.*-avd '"$avd"'"; exit 0
        fi
      done' > /dev/null 2>&1 < /dev/null &
    for _ in $(seq 1 240); do
      if [ "$(adb -s emulator-5554 shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ]; then
        echo "booted: emulator-5554 ($avd, $api)"
        exit 0
      fi
      running || { echo "emulator died; last log lines:" >&2; tail -20 "$log" >&2; exit 1; }
      sleep 2
    done
    echo "emulator did not finish booting in 8 minutes; see $log" >&2
    exit 1
    ;;
  stop)
    if running; then
      adb -s emulator-5554 emu kill > /dev/null 2>&1 || true
      sleep 3
      pkill -f "qemu-system.*-avd $avd" || true
      echo stopped
    else
      echo "not running"
    fi
    ;;
  status)
    if running; then echo "running: emulator-5554 ($avd)"; else echo stopped; fi
    ;;
  *) echo "usage: heavy-emulator.sh start|stop|status" >&2; exit 2 ;;
esac
