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
# Only the programs whose file changed are restarted; their supervisor loops
# in mujina_display_startup.sh start the new files. The miner is restarted
# only when BIN_DIR has a mujina-minerd that differs from the device's.
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
[ -f "$bin/mujina-minerd" ] && put "$bin/mujina-minerd" /data/mujina-minerd mujina-minerd
exit 0
