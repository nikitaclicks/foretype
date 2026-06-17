cask "foretype" do
  version "0.1.8"
  sha256 "5234fb38257697fd4f178106831045e5c276e88911b4571aa5cb5b7e287deab6"

  url "https://github.com/nikitaclicks/foretype/releases/download/v#{version}/Foretype-v#{version}.zip"
  name "Foretype"
  desc "Menu-bar inline autocomplete with ghost text"
  homepage "https://github.com/nikitaclicks/foretype"

  depends_on macos: :sonoma # macOS 14+, matches LSMinimumSystemVersion

  app "Foretype.app"

  # Not notarized (AeroSpace-style): strip the quarantine flag on install so the
  # app launches without a Gatekeeper "unidentified developer" block.
  postflight do
    system "xattr", "-dr", "com.apple.quarantine", "#{appdir}/Foretype.app"
  end

  uninstall quit: "com.foretype.Foretype"

  zap trash: "~/Library/Preferences/com.foretype.Foretype.plist"
end
