cask "burnblame" do
  version "1.0.0"
  sha256 "46139ff6134770515625ca1bf8188cb82381c5abeb493bd12af84c61033fa3e9"

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
