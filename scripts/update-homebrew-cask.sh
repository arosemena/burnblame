#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <version> <sha256>" >&2
    exit 1
fi

VERSION="$1"
SHA256="$2"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CASK_FILE="$ROOT_DIR/Casks/burnblame.rb"

cat > "$CASK_FILE" <<EOF
cask "burnblame" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/arosemena/burnblame/releases/download/v#{version}/BurnBlame-#{version}.dmg"
  name "BurnBlame"
  desc "Lean macOS menu bar thermal & heat-culprit monitor"
  homepage "https://github.com/arosemena/burnblame"

  depends_on macos: ">= :sonoma"

  app "BurnBlame.app"

  zap trash: [
    "~/Library/Preferences/mx.lotus.burnblame.plist",
  ]
end
EOF

echo "Updated $CASK_FILE to v$VERSION ($SHA256)"
