#!/bin/sh
# Builds the pinned terminal engine with Octet's small native-UI patches, then
# copies the resulting binary into Vendor/engine for Xcode to bundle.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
revision="621e6b73c4fe4c13562c0906699003d0ca59f0f1"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/octet-engine.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

git clone --filter=blob:none https://github.com/herdrdev/herdr.git "$build_dir/source"
git -C "$build_dir/source" checkout "$revision"
git -C "$build_dir/source" apply "$root/scripts/engine-scrollbar-capsule.patch"
# Bell and desktop-notification events, and OSC 133 prompt marks (pane.marks).
git -C "$build_dir/source" apply "$root/scripts/engine-attention-marks.patch"

(
    cd "$build_dir/source"
    CARGO_INCREMENTAL=0 CARGO_PROFILE_RELEASE_DEBUG=0 cargo build --release --locked
    cargo test --release --locked scrollbar_renders_only_a_capped_thumb
    cargo test --release --locked prompt_marks
)

"$root/scripts/fetch-engine.sh" "$build_dir/source/target/release/herdr"
