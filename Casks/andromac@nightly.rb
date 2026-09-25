# The newest build there is: the nightly release, which every push to main re-creates and every
# stable release refreshes with its own build. The file name never changes, so there is no
# version to follow; the app updates itself from the nightly channel after the install.
#
#   brew tap anilmetin0/andromac https://github.com/anilmetin0/AndroMac
#   brew trust anilmetin0/andromac
#   brew install --cask andromac@nightly
cask "andromac@nightly" do
  version :latest
  sha256 :no_check

  url "https://github.com/anilmetin0/AndroMac/releases/download/nightly/AndroMac-nightly-macOS-arm64.dmg"
  name "AndroMac Nightly"
  desc "Nightly build of AndroMac, the Android phone companion"
  homepage "https://github.com/anilmetin0/AndroMac"

  auto_updates true
  conflicts_with cask: "andromac"
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "AndroMac.app"

  uninstall quit: "dev.andromac"

  zap trash: [
    "~/Library/Application Support/AndroMac",
    "~/Library/Preferences/dev.andromac.plist",
  ]

  caveats <<~EOS
    AndroMac is signed with its own self-signed certificate and not notarized,
    so macOS refuses the first launch.
    Clear the quarantine flag once:
      xattr -dr com.apple.quarantine /Applications/AndroMac.app
    or press "Open Anyway" in System Settings > Privacy & Security after the first try.
  EOS
end
