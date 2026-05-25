#!/bin/sh
#
# build-release.sh — produce a self-contained kawpow-mac release archive.
#
# Output: dist/kawpow-mac-<VERSION>-macos-arm64.zip
# Contents:
#   kawpow-mac                            (release binary)
#   kawpow-mac_kawpow-mac.bundle/         (Metal shader resources)
#   config.example.json                   (sample config — user edits)
#   README.txt                            (run instructions)
#
# Usage:
#   sh scripts/build-release.sh [version]
# If <version> is omitted, today's date in YYYYMMDD is used as the version.
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(date +%Y%m%d)}"

echo "==> Building kawpow-mac release (version=$VERSION)"
swift build -c release

SRC_BIN="$ROOT/.build/release/kawpow-mac"
SRC_BUNDLE="$ROOT/.build/release/kawpow-mac_kawpow-mac.bundle"

if [ ! -x "$SRC_BIN" ]; then
  echo "ERROR: $SRC_BIN missing — build failed" >&2
  exit 1
fi
if [ ! -d "$SRC_BUNDLE" ]; then
  echo "ERROR: $SRC_BUNDLE missing — Metal shader bundle not produced" >&2
  exit 1
fi

STAGE="$ROOT/dist/kawpow-mac-$VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp "$SRC_BIN" "$STAGE/kawpow-mac"
cp -R "$SRC_BUNDLE" "$STAGE/kawpow-mac_kawpow-mac.bundle"
chmod +x "$STAGE/kawpow-mac"

# Ad-hoc sign so Gatekeeper does not trap the binary on launch.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$STAGE/kawpow-mac" 2>/dev/null || true
fi

cat > "$STAGE/config.example.json" <<'EOF'
{
  "user": "LTC:YOUR_LTC_ADDRESS.workername",
  "chosenURL": "kp.unmineable.com",
  "chosenPort": 3333,
  "deviceNumber": 0,
  "intensity": 10371840
}
EOF

cat > "$STAGE/README.txt" <<EOF
kawpow-mac $VERSION — KawPow miner for Apple Silicon Macs

Quick start
-----------
1. Edit config.example.json — replace YOUR_LTC_ADDRESS with your own,
   and change "workername" to whatever you want shown on the unMineable
   dashboard. (You can also change the LTC: prefix to BTC:, ETH:, RVN:,
   etc. depending on what coin you want as payout.)
2. Rename it to config.json:
       mv config.example.json config.json
3. Run:
       ./kawpow-mac

On first launch macOS may refuse to open this because it isn't notarized.
Either:
    - Right-click → Open (instead of double-click) the first time, OR
    - Run:  xattr -d com.apple.quarantine kawpow-mac

What you should see
-------------------
Self-tests pass, then it connects to kp.unmineable.com, builds the
KawPow DAG on GPU (~30-45 seconds the first time, depending on epoch),
then starts mining. You should see [miner] X.XX MH/s lines every ~5s
and [main] submitting share / [share] accepted lines as shares are
found and accepted by the pool.

Requirements
------------
- macOS 13 (Ventura) or newer
- Apple Silicon (M1 / M2 / M3 / M4 / M5)
- ~6-8 GB free unified memory for the DAG

Caveat
------
Mining on a Mac is not profitable. This is a "what hardware can do"
exercise — actual electricity-and-thermals cost will exceed any
payout. CPU mining via XMRig works on any Mac and pays out reliably
through the same pool, just at very small rates.

Source code, docs, bug chronicle:
    https://github.com/shiftingeden/kawpow-mac
EOF

ZIP_NAME="kawpow-mac-$VERSION-macos-arm64.zip"
ZIP_PATH="$ROOT/dist/$ZIP_NAME"
( cd "$ROOT/dist" && rm -f "$ZIP_NAME" && zip -q -9 -r "$ZIP_NAME" "kawpow-mac-$VERSION" )

echo "==> Created $ZIP_PATH"
ls -lh "$ZIP_PATH"
echo "==> Done."
