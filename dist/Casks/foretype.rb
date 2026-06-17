cask "foretype" do
  version "0.1.9"
  sha256 "5e7f4919a46667fcf78d55dcb0e79a9af176760c36067875b7cf44aaf9462ff1"

  url "https://github.com/nikitaclicks/foretype/releases/download/v#{version}/Foretype-v#{version}.zip"
  name "Foretype"
  desc "Menu-bar inline autocomplete with ghost text"
  homepage "https://github.com/nikitaclicks/foretype"

  depends_on macos: :sonoma # macOS 14+, matches LSMinimumSystemVersion

  app "Foretype.app"

  # Not notarized: the bundle is signed with a stable self-signed certificate,
  # so strip the quarantine flag on install so the app launches without a
  # Gatekeeper "unidentified developer" block.
  postflight do
    system "xattr", "-dr", "com.apple.quarantine", "#{appdir}/Foretype.app"
  end

  uninstall quit: "com.foretype.Foretype"

  zap trash: "~/Library/Preferences/com.foretype.Foretype.plist"
end
