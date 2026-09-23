# One rolling release per version, rebuilt from every push to main. The version here must equal
# the VERSION file (CI checks it); a rebuild of the same version keeps the same file name, so the
# checksum is not pinned and SHA256SUMS.txt on the release page carries it. The app updates
# itself between builds. Apple Silicon only: CI builds arm64 and there is no Intel build.
#
#   brew tap anilmetin0/andromac https://github.com/anilmetin0/AndroMac
#   brew trust anilmetin0/andromac
#   brew install --cask andromac
cask "andromac" do
  version "1.1.0"
  sha256 :no_check

  url "https://github.com/anilmetin0/AndroMac/releases/download/v#{version}/AndroMac-#{version}-macOS-arm64.dmg"
  name "AndroMac"
  desc "Sync battery, clipboard, notifications, media and files with Android phones"
  homepage "https://github.com/anilmetin0/AndroMac"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "AndroMac.app"

  uninstall quit: "io.github.anilmetin0.andromac"

  zap trash: [
    "~/Library/Application Support/AndroMac",
    "~/Library/Preferences/dev.andromac.plist",
    "~/Library/Preferences/io.github.anilmetin0.andromac.plist",
  ]

  caveats <<~EOS
    AndroMac is signed ad-hoc and not notarized, so macOS refuses the first launch.
    Clear the quarantine flag once:
      xattr -dr com.apple.quarantine /Applications/AndroMac.app
    or press "Open Anyway" in System Settings > Privacy & Security after the first try.
  EOS
end
