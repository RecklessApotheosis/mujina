#!/bin/sh
# The build job itself: runs INSIDE the Dendrite Rust job image, in /w, with
# no network. Started by reckless/remote-build.sh; not meant to be run by hand.
# The cd into each crate matters: cargo reads .cargo/config.toml from the
# working directory. RUSTFLAGS in the environment replaces every config
# rustflags entry, which also drops the repo root's developer-machine -L path.
set -eu
vendored=/w/reckless/vendored-sources.toml
# Unit tests first, on the build host's own target: a failing test stops
# the build before anything is cross-compiled.
for crate in fb_hijack nano3s_ui; do
    ( cd "/w/$crate" && cargo +1.94 test --offline --locked \
        --target x86_64-unknown-linux-gnu --target-dir /w/target-test --config "$vendored" )
done
export RUSTFLAGS="-C target-feature=+crt-static"
export CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER=riscv64-linux-gnu-gcc
export CARGO_TARGET_DIR=/w/target
for crate in fb_hijack nano3s_ui; do
    ( cd "/w/$crate" && cargo +1.94 build --release --offline --locked \
        --target riscv64gc-unknown-linux-gnu \
        --config "$vendored" )
done
