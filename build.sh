#!/bin/bash
# Fetches byedpi at the pinned release, checks the commit hash and builds ciadpi into bin/.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ "$(uname -s)" == "Darwin" ]] || die "This only runs on macOS."
for tool in git make cc codesign; do
    command -v "$tool" >/dev/null || die "'$tool' is missing. Install the Xcode Command Line Tools: xcode-select --install"
done

SRC="$KIT_DIR/.build/byedpi"
if [[ ! -d "$SRC/.git" ]]; then
    log "Downloading byedpi $BYEDPI_TAG"
    mkdir -p "$KIT_DIR/.build"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$BYEDPI_TAG" "$BYEDPI_REPO" "$SRC"
fi

actual="$(git -C "$SRC" rev-parse HEAD)"
[[ "$actual" == "$BYEDPI_COMMIT" ]] \
    || die "byedpi commit mismatch: expected $BYEDPI_COMMIT, got $actual. Delete .build/ and try again."

log "Building ciadpi"
make -s -C "$SRC" clean >/dev/null
# byedpi prints a few harmless upstream warnings; only show the output if the build fails.
if ! make -s -C "$SRC" -j"$(sysctl -n hw.ncpu)" > "$KIT_DIR/.build/make.log" 2>&1 || [[ ! -x "$SRC/ciadpi" ]]; then
    cat "$KIT_DIR/.build/make.log" >&2
    die "Build failed."
fi

# Copy to a fresh file (new inode) and re-sign. Overwriting a signed binary in
# place makes Apple Silicon kill it on launch with "Killed: 9".
mkdir -p "$KIT_DIR/bin"
rm -f "$BIN"
cp "$SRC/ciadpi" "$BIN"
codesign --force --sign - "$BIN" 2>/dev/null
log "Built $BIN ($(du -h "$BIN" | cut -f1 | tr -d ' '))"
