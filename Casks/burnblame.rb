cask "burnblame" do
  version "1.0.0"
  sha256 :no_check # Updated automatically by scripts/update-homebrew-cask.sh on release

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
