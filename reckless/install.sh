#!/bin/sh
# Make the Nano 3S's display programs, and optionally its miner, equal to
# the ones in BIN_DIR.
#   usage: reckless/install.sh BIN_DIR [IMAGE]
# BIN_DIR holds fb_button and nano3s_ui, and may hold mujina-minerd. IMAGE,
# if given, is installed as /data/reckless.rgb565.
#
# The miner goes last. From v5.0.5 it carries its own copies of the two
# display programs and, when it starts, overwrites the ones on disk that
# differ. Installing the display programs first, from the same build, means
# its start finds them equal and changes nothing.
#
# It converges: a file whose hash on the device already matches is left
# alone and its program is not restarted, so a second run changes nothing.
# Rollback is the same command with BIN_DIR set to the saved originals.
#
# A program is replaced by copying beside it and renaming over it, because
# overwriting a running binary in place can fail on this device's UBIFS.
# Only the display programs whose file changed are restarted; their
# supervisor loops in mujina_display_startup.sh start the new files.
# A changed miner REBOOTS the unit instead. Measured 2026-11-11: a miner
# killed and restarted by its supervisor blocks forever at "connecting to
# rtos_core" (v5.0.3 and v5.0.5 alike), and the startup script's watchdog did
# not reboot it within 4 minutes. After a reboot it connects within 30 s.
# The script then waits for the device and for the miner's IPC connection.
#
# Environment: NANO_SSH, the full ssh command for the device.
set -eu
bin=$1; image=${2:-}
: "${NANO_SSH:?set NANO_SSH to the ssh command for the device}"

sum() { sha256sum "$1" | cut -d' ' -f1; }
dev_sum() { $NANO_SSH "sha256sum $1 2>/dev/null | cut -d' ' -f1"; }

put() { # local-file device-path program-name-or-empty
    want=$(sum "$1"); have=$(dev_sum "$2")
    if [ "$want" = "$have" ]; then echo "unchanged  $2  $want"; return 0; fi
    $NANO_SSH "cat > $2.new && chmod 755 $2.new" < "$1"
    got=$(dev_sum "$2.new")
    if [ "$got" != "$want" ]; then
        $NANO_SSH "rm -f $2.new"
        echo "FAILED copy of $2: wanted $want, device has $got" >&2; exit 1
    fi
    $NANO_SSH "mv $2.new $2 && sync"
    echo "installed  $2  $want  (was ${have:-absent})"
    if [ -n "$3" ]; then
        old=$($NANO_SSH "pidof $3 || true")
        [ -n "$old" ] && $NANO_SSH "kill $old"
        i=0
        while [ $i -lt 20 ]; do
            sleep 1; new=$($NANO_SSH "pidof $3 || true")
            if [ -n "$new" ] && [ "$new" != "$old" ]; then echo "restarted  $3  pid $old -> $new"; return 0; fi
            i=$((i + 1))
        done
        echo "FAILED: $3 did not come back within 20 s" >&2; exit 1
    fi
}

[ -n "$image" ] && put "$image" /data/reckless.rgb565 ""
put "$bin/nano3s_ui" /data/nano3s_ui nano3s_ui
put "$bin/fb_button" /mntapp/release/linux/app/fb_button fb_button
if [ -f "$bin/mujina-minerd" ]; then
    before=$(dev_sum /data/mujina-minerd)
    put "$bin/mujina-minerd" /data/mujina-minerd ""
    if [ "$before" != "$(sum "$bin/mujina-minerd")" ]; then
        echo "rebooting   the miner changed; a restart alone cannot reconnect to rtos_core"
        $NANO_SSH "sync; reboot" || true
        i=0; up=""
        while [ $i -lt 60 ]; do
            sleep 5; i=$((i + 1))
            up=$($NANO_SSH "cut -d. -f1 /proc/uptime" 2>/dev/null || true)
            [ -n "$up" ] && [ "$up" -lt 600 ] && break
            up=""
        done
        [ -n "$up" ] || { echo "FAILED: device not back within 5 min" >&2; exit 1; }
        i=0
        while [ $i -lt 36 ]; do
            if [ "$($NANO_SSH 'grep -c "ipc_shim\] connected" /data/mujina-minerd.log' 2>/dev/null || echo 0)" -gt 0 ]; then
                echo "connected  mujina-minerd to rtos_core, device uptime ${up}s at boot check"; exit 0
            fi
            sleep 5; i=$((i + 1))
        done
        echo "FAILED: miner did not connect to rtos_core within 3 min of boot" >&2; exit 1
    fi
fi
exit 0
