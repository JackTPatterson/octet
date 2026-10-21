#!/bin/sh
# Builds Octet's terminal engine from its fork (herdr with Octet's changes
# committed on the `octet` branch), then copies the binary into Vendor/engine
# for Xcode to bundle. Only committed work is built: the fork is cloned first.
#   OCTET_ENGINE_SOURCE  the fork (a path or URL); default ../octet-engine
#   OCTET_ENGINE_REVISION  what to build; default the pinned commit below
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
source="${OCTET_ENGINE_SOURCE:-$root/../octet-engine}"
# Upstream 621e6b73 plus Octet's changes: snapshots that ask every pane's
# foreground group at once, pane.stream (each pane drawn natively from its raw
# output, after a replay of its state), tab.set_viewport (a tab laid out at
# the size Octet shows it), and without the terminal client, remote sessions
# or self-update: Octet is the only client.
revision="${OCTET_ENGINE_REVISION:-5886a9ac}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/octet-engine.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

git clone --quiet "$source" "$build_dir/source"
git -C "$build_dir/source" checkout --quiet "$revision"

(
    cd "$build_dir/source"
    # Whole-program optimisation, one codegen unit and no symbols: about a
    # quarter smaller (22 MB to 16 MB) for the same engine.
    export CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 CARGO_PROFILE_RELEASE_STRIP=symbols
    # Without self-update: Octet ships and updates the engine itself.
    CARGO_INCREMENTAL=0 CARGO_PROFILE_RELEASE_DEBUG=0 cargo build --release --locked --no-default-features
    # Some engine tests write to the state and config folders: keep them
    # off the real ones (they once replaced the cached Codex rules).
    scratch="$build_dir/xdg"
    mkdir -p "$scratch/state" "$scratch/config" "$scratch/data"
    export XDG_STATE_HOME="$scratch/state" XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data"
    # What Octet relies on, each from one of its changes.
    for test in prompt_marks bundled_manifests_read_recorded_screens pane_layout copy_search_options \
        pane_stream set_viewport generated_protocol_schema_artifact_is_current; do
        cargo test --release --locked --no-default-features --bin herdr "$test"
    done
)

"$root/scripts/fetch-engine.sh" "$build_dir/source/target/release/herdr"
