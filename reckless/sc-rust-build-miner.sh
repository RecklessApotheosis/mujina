#!/bin/sh
# Build job for the whole Nano 3S Linux side: the display programs, then
# mujina-minerd, which embeds them (nano3s.rs, companion_binaries). Runs
# INSIDE the Dendrite Rust riscv64 job image, in /w, with no network.
# Started by reckless/remote-build.sh --miner; not meant to be run by hand.
#
# Every native input is built here from source, except one:
#   /w/deps/libudev-zero      libudev-zero source (ISC), built here into a
#                             static riscv64 libudev.a and its .pc file
#   /w/deps/ipcmsg            Canaan k230_sdk v2.0 libipcmsg.a ("host", the
#                             Linux side) and headers: a prebuilt archive,
#                             Canaan ships no source for it
# Crates for the miner come from the lane's read-only registry cache (the
# Cargo.lock here); crates for the display programs from /w/vendor.
set -eu
vendored=/w/reckless/vendored-sources.toml
target=riscv64gc-unknown-linux-gnu

# 1. Display programs: tests on the host target, then the device build into
#    each crate's own target/, the path the miner's include_bytes! reads.
for crate in fb_hijack nano3s_ui; do
    ( cd "/w/$crate" && cargo +1.94 test --offline --locked \
        --target x86_64-unknown-linux-gnu --target-dir /w/target-test --config "$vendored" )
done
for crate in fb_hijack nano3s_ui; do
    ( cd "/w/$crate" && \
      RUSTFLAGS="-C target-feature=+crt-static" \
      CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER=riscv64-linux-gnu-gcc \
      cargo +1.94 build --release --offline --locked --target $target --config "$vendored" )
done

# 2. libudev for riscv64, static, from source.
sysroot=/w/sysroot/usr
mkdir -p "$sysroot/lib/pkgconfig" "$sysroot/include"
( cd /w/deps/libudev-zero && make clean >/dev/null 2>&1 || true
  make CC=riscv64-linux-gnu-gcc AR=riscv64-linux-gnu-ar PREFIX="$sysroot" libudev.a libudev.pc
  cp libudev.a "$sysroot/lib/" && cp libudev.pc "$sysroot/lib/pkgconfig/" && cp udev.h "$sysroot/include/libudev.h" )

# 3. Canaan's IPC library where mujina-miner/build.rs links it from.
mkdir -p /w/rtos_core/vendor/sdk_libs
cp /w/deps/ipcmsg/libipcmsg.a /w/rtos_core/vendor/sdk_libs/libipcmsg.a

# 4. The miner. RUSTFLAGS replaces the repo root config's developer -L path.
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_ALL_STATIC=1
export PKG_CONFIG_PATH_riscv64gc_unknown_linux_gnu="$sysroot/lib/pkgconfig"
export PKG_CONFIG_LIBDIR_riscv64gc_unknown_linux_gnu="$sysroot/lib/pkgconfig"
export RUSTFLAGS="-C target-feature=+crt-static -C target-cpu=generic-rv64"
export CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER=riscv64-linux-gnu-gcc
export CC_riscv64gc_unknown_linux_gnu=riscv64-linux-gnu-gcc
export AR_riscv64gc_unknown_linux_gnu=riscv64-linux-gnu-ar
cd /w && cargo +1.94 build --release --offline --locked --target $target \
    --target-dir /w/target -p mujina-miner --features nano3s --bin mujina-minerd
riscv64-linux-gnu-strip --strip-all -o /w/target/$target/release/mujina-minerd.stripped \
    /w/target/$target/release/mujina-minerd
mkdir -p /w/target/display
cp /w/nano3s_ui/target/$target/release/nano3s_ui /w/fb_hijack/target/$target/release/fb_button /w/target/display/
