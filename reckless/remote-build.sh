#!/bin/sh
# Build the Nano 3S Linux-side programs on a leased Dendrite build lane,
# never on the machine this script is started from.
#   usage: reckless/remote-build.sh OUT_DIR DEPS_DIR [--miner]
# DEPS_DIR is what reckless/fetch-deps.sh made.
# Without --miner: fb_button and nano3s_ui (job reckless/sc-rust-build.sh).
# With --miner: also mujina-minerd, which embeds those two (job
# reckless/sc-rust-build-miner.sh).
#
# It sends the COMMITTED tree at HEAD (a dirty tree is refused, so the
# record's commit is what was built), plus VENDOR_DIR (and DEPS_DIR), checks
# the source hash at both ends, builds offline in the riscv64 Rust job image,
# pulls the binaries into OUT_DIR/bin, verifies SHA256SUMS, destroys the
# remote clone and releases the lease, whether the build passed or failed.
# Re-running rebuilds into the same OUT_DIR; the hashes say what changed.
#
# Only the Supercomplex lanes carry the Rust riscv64 toolchain (Dendrite Ops,
# 2026-11-11), so the lease is asked of those lanes directly, not of the
# pool: the first of NANO_BUILD_LANES that grants at once wins; a lane that
# would only queue is released again at once; the round repeats every 30 s
# for up to 10 minutes. All four lanes are one host, reached by one alias.
# Lane tools and their rules: dendrite/working/tools/HOW-TO-REQUEST-A-LANE.md
set -eu
out=$(realpath -m "$1"); deps=$(realpath "$2"); vendor=$deps/vendor
miner=0; [ "${3:-}" = --miner ] && miner=1
root=$(cd "$(dirname "$0")/.." && pwd)

LANES=${NANO_BUILD_LANES:-supercomplex-build supercomplex-build2 supercomplex-build3 supercomplex-build4}
HOST=${NANO_BUILD_HOST:-supercomplex-build}
LANE=""
IMAGE=${NANO_BUILD_IMAGE:-localhost/sc-build-rust:1.94.0-20261112-riscv64}
LANEDB=${LANEDB:-/home/ronald/projects/dendrite/working/supercomplex-build-20261020/bin/lanedb}
SR=/srv/store/build/toolchains/bin/sc-rust
remote() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "$@"; }
T=riscv64gc-unknown-linux-gnu/release
if [ $miner = 1 ]; then
    MINUTES=${NANO_BUILD_MINUTES:-30}; CPUS=12; MEM=32; job=reckless/sc-rust-build-miner.sh
    paths="target/$T/mujina-minerd.stripped target/display/nano3s_ui target/display/fb_button"
else
    MINUTES=${NANO_BUILD_MINUTES:-15}; CPUS=8; MEM=16; job=reckless/sc-rust-build.sh
    paths="target/$T/fb_button target/$T/nano3s_ui"
fi

[ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ] \
    || { echo "remote-build: commit or stash your changes first" >&2; exit 1; }
commit=$(git -C "$root" rev-parse HEAD)
branch=$(git -C "$root" rev-parse --abbrev-ref HEAD | tr '/' '-')
build="nano3s-$([ $miner = 1 ] && echo miner || echo display)-$(echo "$commit" | cut -c1-12)"
who="mujina-nano3s/$branch"

stage=$(mktemp -d); leased=0; put=0
cleanup() {
    rc=$?
    [ $put = 1 ] && remote "sc-build clean $build" || true
    [ $leased = 1 ] && "$LANEDB" session release "$LANE" --chit "$build" --who "$who" | grep '^message=' || true
    rm -rf "$stage"
    exit $rc
}
trap cleanup EXIT

# The source. Fixed order, owner and time, so the same inputs give the same
# tar hash.
mkdir "$stage/src"
if [ $miner = 1 ]; then
    git -C "$root" archive "$commit" | tar -x -C "$stage/src"
    mkdir "$stage/src/deps"
    cp -a "$deps/libudev-zero" "$stage/src/deps/libudev-zero"
    rm -rf "$stage/src/deps/libudev-zero/.git"
    cp -a "$deps/ipcmsg" "$stage/src/deps/ipcmsg"
else
    git -C "$root" archive "$commit" fb_hijack nano3s_ui reckless | tar -x -C "$stage/src"
fi
cp -a "$vendor" "$stage/src/vendor"
tar -cf "$stage/src.tar" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$stage/src" .
src_sum=$(sha256sum "$stage/src.tar" | cut -d' ' -f1)

tries=0
while [ -z "$LANE" ] && [ $tries -lt 20 ]; do
    for l in $LANES; do
        "$LANEDB" session request "$l" --chit "$build" --minutes "$MINUTES" --who "$who" > "$stage/lease.txt" 2>&1 || true
        if grep -q '^state=granted' "$stage/lease.txt"; then LANE=$l; break; fi
        "$LANEDB" session release "$l" --chit "$build" --who "$who" > /dev/null 2>&1 || true
    done
    [ -n "$LANE" ] || { tries=$((tries + 1)); echo "remote-build: every lane busy; asking again in 30 s" >&2; sleep 30; }
done
[ -n "$LANE" ] || { echo "remote-build: no lane free within 10 minutes" >&2; exit 1; }
leased=1
echo "lane granted: $LANE"
policy=$(sed -n 's/^on_overrun=//p' "$stage/lease.txt")

put=1
there=$(remote "sc-build put $build" < "$stage/src.tar" | cut -d' ' -f1 | tail -1)
[ "$there" = "$src_sum" ] || { echo "remote-build: source hash differs: here $src_sum, there $there" >&2; exit 1; }

remote "SC_RUST_IMAGE=$IMAGE $SR run $build --on-overrun ${policy:-expire} --cpus $CPUS --mem $MEM --timeout $((MINUTES * 60)) -- sh $job"
remote "$SR collect $build $paths"

mkdir -p "$out/bin"
remote "sc-build get $build" | tar -x -C "$out/bin"
( cd "$out/bin" && sha256sum -c SHA256SUMS )
image_id=$(remote "podman image inspect --format '{{.Id}}' $IMAGE")
{
    echo "commit=$commit"
    echo "source_tar_sha256=$src_sum"
    echo "job=$job"
    echo "lane=$LANE"
    echo "image=$IMAGE"
    echo "image_id=$image_id"
    sed -n 's/^\(lease\|run_id\)=/\1=/p' "$stage/lease.txt"
} > "$out/build-record.txt"
cat "$out/build-record.txt"; cat "$out/bin/SHA256SUMS"
