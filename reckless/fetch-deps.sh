#!/bin/sh
# Fetch every input the Nano 3S build needs that is not in this repository,
# at pinned versions, and check each one. The only step that uses the
# network; the build itself runs offline on a Dendrite lane.
#   usage: reckless/fetch-deps.sh DEPS_DIR
# DEPS_DIR ends up holding:
#   vendor/         crates for fb_hijack and nano3s_ui, from their Cargo.lock
#                   files (cargo checks each against the lock's checksum)
#   libudev-zero/   source, tag 1.0.5, checked by git commit id; ISC licence
#   ipcmsg/         Canaan k230_sdk v2.0 libipcmsg.a (Linux "host" variant)
#                   and headers, checked by sha256; prebuilt by Canaan, no
#                   source published
# The miner's own crates are not fetched: the lane's registry cache holds
# every crate in the root Cargo.lock.
#
# It converges: an input already present and correct is left alone, so a
# second run fetches nothing. Changing a pin below is a deliberate act:
# Ronald's rule is releases at least 14 days old, and a go per fetch.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
deps=$(realpath -m "$1"); mkdir -p "$deps"

UDEV_REPO=https://github.com/illiliti/libudev-zero.git
UDEV_TAG=1.0.5
UDEV_COMMIT=7a6eee2db11f2eb0f7fd065ae9597fcd270e6734

SDK_RAW=https://raw.githubusercontent.com/kendryte/k230_sdk/7e302f733311d284be255f0d81d3463b6ae6ee6d
SDK_DIR=src/common/cdk/user/component/ipcmsg
# file in ipcmsg/   path under SDK_DIR   sha256
IPCMSG="libipcmsg.a host/lib/libipcmsg.a d1b1ecae0434cc4376fa238560355bf201c07a0499bb1144e138d6b6972759a2
k_ipcmsg.h include/k_ipcmsg.h e9f6721f0c5f24375c2096b18da4ad7a45abcf1c57f7292e91b20b2a6f5d5505
k_comm_ipcmsg.h include/k_comm_ipcmsg.h 6d24f0e60f99dbace80ae6d791257119ef97ac4e4219179677f5b11ae008e6e5"

# 1. Crates for the display programs.
if [ -d "$deps/vendor" ] && [ -n "$(ls -A "$deps/vendor")" ]; then
    echo "unchanged  vendor/"
else
    cargo vendor --locked \
        --manifest-path "$root/nano3s_ui/Cargo.toml" \
        --sync "$root/fb_hijack/Cargo.toml" "$deps/vendor" > /dev/null
    echo "fetched    vendor/ ($(ls "$deps/vendor" | wc -l) crates)"
fi

# 2. libudev-zero source.
have=$(git -C "$deps/libudev-zero" rev-parse HEAD 2>/dev/null || true)
if [ "$have" = "$UDEV_COMMIT" ]; then
    echo "unchanged  libudev-zero/ $UDEV_COMMIT"
else
    rm -rf "$deps/libudev-zero.new"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$UDEV_TAG" "$UDEV_REPO" "$deps/libudev-zero.new"
    got=$(git -C "$deps/libudev-zero.new" rev-parse HEAD)
    [ "$got" = "$UDEV_COMMIT" ] || { echo "FAILED: libudev-zero $UDEV_TAG is $got, pinned $UDEV_COMMIT" >&2; exit 1; }
    rm -rf "$deps/libudev-zero"; mv "$deps/libudev-zero.new" "$deps/libudev-zero"
    echo "fetched    libudev-zero/ $got"
fi

# 3. Canaan's IPC library and headers.
mkdir -p "$deps/ipcmsg"
echo "$IPCMSG" | while read -r name path want; do
    f="$deps/ipcmsg/$name"
    if [ -f "$f" ] && { [ "$want" = - ] || [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ]; }; then
        echo "unchanged  ipcmsg/$name"; continue
    fi
    curl -fsSL -o "$f.new" "$SDK_RAW/$SDK_DIR/$path"
    if [ "$want" != - ]; then
        got=$(sha256sum "$f.new" | cut -d' ' -f1)
        [ "$got" = "$want" ] || { rm -f "$f.new"; echo "FAILED: ipcmsg/$name is $got, pinned $want" >&2; exit 1; }
    fi
    mv "$f.new" "$f"; echo "fetched    ipcmsg/$name"
done
