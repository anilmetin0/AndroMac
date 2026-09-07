import Foundation

/// One GitHub release of AndroMac and the rule that decides whether it beats the running build.
///
/// There is a single rolling release per version: tag `v1.0.0`, title `AndroMac 1.0.0 (fd7d47a)`.
/// The tag carries the version, the title the short commit, and the same version is re-published
/// with a new commit on every push. Pure data, so it can be unit-tested; the network side lives in
/// `UpdateCheck.swift` of the app.
public struct Release: Equatable, Sendable {

    /// One published file of a release: what the in-app updater downloads.
    public struct Asset: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int

        public init(name: String, url: URL, size: Int) {
            self.name = name
            self.url = url
            self.size = size
        }
    }

    public let version: AppVersion
    /// The commit named in the release title, `nil` when the title has none.
    public let commit: String?
    public let url: URL
    public let assets: [Asset]

    public init(version: AppVersion, commit: String?, url: URL, assets: [Asset] = []) {
        self.version = version
        self.commit = commit
        self.url = url
        self.assets = assets
    }

    /// The macOS build of this release, `AndroMac-<version>-<commit>-macOS.zip`.
    public var macZip: Asset? { assets.first { $0.name.hasSuffix("-macOS.zip") } }

    /// The checksum file every release publishes. The updater refuses to install without it.
    public var checksums: Asset? { assets.first { $0.name == "SHA256SUMS.txt" } }

    /// `1.0.0 (fd7d47a)`, or just `1.0.0` when no commit is known. Same style as the app's version line.
    public var label: String {
        commit.map { "\(version) (\($0))" } ?? version.description
    }

    public static let repo = "anilmetin0/AndroMac"

    /// The page that always points at the current build, whatever the version is.
    ///
    /// There is one rolling release per version, so this URL never goes stale — it is what the
    /// QR code in Settings encodes, so the phone can be pointed at the APK without typing anything.
    public static let latestURL = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// A GitHub release object → `Release`; `nil` when it carries no version or points elsewhere.
    public static func parse(_ json: Data) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        // The link is opened in the browser: only ever a page of this repository, whatever the response says.
        guard let link = o["html_url"] as? String, link.hasPrefix("https://github.com/\(repo)/"),
              let url = URL(string: link) else { return nil }
        let name = o["name"] as? String ?? ""
        guard let version = AppVersion.find(in: o["tag_name"] as? String ?? "") ?? AppVersion.find(in: name)
        else { return nil }
        return Release(
            version: version, commit: commit(in: name), url: url, assets: assets(in: o)
        )
    }

    /// The downloadable files, keeping only what GitHub itself serves: an asset URL that points
    /// anywhere else is not something this app will fetch, whatever the response says.
    private static func assets(in object: [String: Any]) -> [Asset] {
        (object["assets"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let name = raw["name"] as? String, !name.isEmpty, !name.contains("/"),
                  let link = raw["browser_download_url"] as? String,
                  link.hasPrefix("https://github.com/\(repo)/releases/download/"),
                  let url = URL(string: link) else { return nil }
            return Asset(name: name, url: url, size: raw["size"] as? Int ?? 0)
        }
    }

    /// The `(fd7d47a)` part of a release title.
    public static func commit(in name: String) -> String? {
        name.firstMatch(of: /\(([0-9a-f]{7,40})\)/.ignoresCase()).map { String($0.1) }
    }

    /// A release is newer than the running build when its version is greater, or when the version
    /// is the same but the release names a different commit. A build whose commit is unknown
    /// ("local", empty) cannot tell same-version releases apart, so only a greater version counts.
    public static func isNewer(_ release: Release, than version: AppVersion, commit: String?) -> Bool {
        if release.version > version { return true }
        guard release.version == version, let mine = commit, !mine.isEmpty, mine != "local",
              let theirs = release.commit else { return false }
        return theirs.lowercased() != mine.lowercased()
    }
}
