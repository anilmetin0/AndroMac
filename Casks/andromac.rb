# One rolling release per version, rebuilt from every push to main; the zip is found on the
# latest release through the GitHub API, so nothing here needs a CI bump. The checksum is not
# pinned because the build changes on every push; SHA256SUMS.txt on the release page carries it.
#
#   brew tap anilmetin0/andromac https://github.com/anilmetin0/AndroMac
#   brew install --cask andromac
#   brew upgrade --cask --greedy-latest andromac   # pick up a newer build
cask "andromac" do
  version :latest
  sha256 :no_check

  url "https://api.github.com/repos/anilmetin0/AndroMac/releases/latest" do |page|
    page[%r{https://github\.com/anilmetin0/AndroMac/releases/download/[^"]+-macOS\.zip}]
  end
  name "AndroMac"
  desc "Sync battery, clipboard, notifications, media and files with Android phones"
  homepage "https://github.com/anilmetin0/AndroMac"

  depends_on macos: :sonoma

  app "AndroMac.app"

  uninstall quit: "dev.andromac"

  zap trash: [
    "~/Library/Application Support/AndroMac",
    "~/Library/Preferences/dev.andromac.plist",
  ]

  caveats <<~EOS
    AndroMac is signed ad-hoc and not notarized, so macOS refuses the first launch.
    Press "Open Anyway" in System Settings > Privacy & Security, or install without
    the quarantine flag instead:
      brew install --cask --no-quarantine andromac
  EOS
end
