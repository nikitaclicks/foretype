cask "foretype" do
  version "0.1.4"
  sha256 "c32baeb190eefeff694b58499dfeef29d9de56efae89a3495832c49b6e5a9874"

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
