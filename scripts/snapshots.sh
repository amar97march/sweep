#!/bin/sh
# Renders every screen with demo data at several window sizes into .build/snapshots/<size>/.
# Read-only measurements only: /Applications for Disk Map, System Data, tool status. Nothing is cleaned.
# LIVE=1 adds read-only scans of this Mac with Junk Files, Cloud Files and Health.
# Sheets, Settings and the menu bar dashboard are captured too; removal sheets are inert previews.
# Window frames and the Settings tab that macOS saves during the run are put back when the app quits.
set -eu
cd "$(dirname "$0")/.."
swift build --product SweepApp >/dev/null
if [ -n "${STEPS:-}" ]; then export SWEEP_SNAPSHOT_STEPS="$STEPS"; fi
if [ -n "${LIVE:-}" ]; then export SWEEP_SNAPSHOT_LIVE=1; fi
for size in ${SIZES:-1040x680 1280x820 1680x1050}; do
    out=".build/snapshots/$size"
    rm -rf "$out"
    SWEEP_SNAPSHOT_DIR="$PWD/$out" SWEEP_SNAPSHOT_SIZE="$size" .build/debug/SweepApp >/dev/null 2>&1
    echo "$size: $(ls "$out" | wc -l | tr -d ' ') screens"
done
