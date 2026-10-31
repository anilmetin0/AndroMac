# One stable release per version; the nightly builds published in between are prereleases the cask never
# sees. The version here must equal the VERSION file (CI checks it). Raising it sets the checksum
# back to :no_check; scripts/pin-cask.sh pins the release's checksum once it is built, and again
# after a re-publish. The app updates itself. Apple Silicon only: CI builds arm64 and there is no
# Intel build.
#
#   brew tap anilmetin0/andromac https://github.com/anilmetin0/AndroMac
#   brew trust anilmetin0/andromac
#   brew install --cask andromac
cask "andromac" do
  version "1.6.0"
  sha256 "a6095008cbc8f6d591511ccfc37c981cf7867b5f80f25bc0a10cc32a180b840e"

  url "https://github.com/anilmetin0/AndroMac/releases/download/v#{version}/AndroMac-#{version}-macOS-arm64.dmg"
  name "AndroMac"
  desc "Sync battery, clipboard, notifications, media and files with Android phones"
  homepage "https://github.com/anilmetin0/AndroMac"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  conflicts_with cask: "andromac@nightly"
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
