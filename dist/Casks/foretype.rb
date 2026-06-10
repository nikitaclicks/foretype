cask "foretype" do
  version "0.1.6"
  sha256 "90b2a4d048ca043946ae0d83ee2ea4ba2d166244e5170e4b5eec2d99375620c6"

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
