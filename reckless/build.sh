#!/bin/sh
# Build fb_button and nano3s_ui for the Nano 3S (riscv64, static) in the
# container from reckless/Containerfile. Dependencies come from a vendor
# directory, so the build itself needs no network.
#   usage: reckless/build.sh OUT_DIR VENDOR_DIR
# Re-running rebuilds into the same OUT_DIR; the printed hashes say whether
# anything changed.
set -eu
out=$(realpath "$1"); vendor=$(realpath "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
image=localhost/nano3s-display-build:$(sha256sum "$root/reckless/Containerfile" | cut -c1-12)
podman image exists "$image" || podman build -t "$image" -f "$root/reckless/Containerfile" "$root/reckless"
mkdir -p "$out/target" "$out/bin"
for crate in fb_hijack nano3s_ui; do
    podman run --rm --network=none --cpus=8 \
        -v "$root":/src -v "$vendor":/vendor:ro -v "$out/target":/target \
        -e CARGO_TARGET_DIR=/target -e RUSTFLAGS="-C target-feature=+crt-static" \
        -w "/src/$crate" "$image" \
        cargo build --release --offline --locked \
            --config 'source.crates-io.replace-with="vendored-sources"' \
            --config 'source.vendored-sources.directory="/vendor"'
done
cp "$out/target/riscv64gc-unknown-linux-gnu/release/fb_button" "$out/target/riscv64gc-unknown-linux-gnu/release/nano3s_ui" "$out/bin/"
(cd "$out/bin" && sha256sum fb_button nano3s_ui | tee SHA256SUMS)
