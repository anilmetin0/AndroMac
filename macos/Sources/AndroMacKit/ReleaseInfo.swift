import Foundation

/// One GitHub release of AndroMac and the rules that decide whether it beats the running build.
///
/// Two kinds of release. A stable one per version (tag `v1.0.0`, title `AndroMac 1.0.0`), marked
/// latest, published when the version changes. A beta on every other push (tag `beta-212-fd7d47a`,
/// title `AndroMac 1.0.0 beta 212 (fd7d47a)`), a prerelease that is never latest. Every body ends
/// with a `Build 212 · commit fd7d47a` footer, which is where the build number is read. Pure data,
/// so it can be unit-tested; the network side lives in `UpdateCheck.swift` of the app.
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
    /// The commit the release was built from: the tag's target, or the one an older release
    /// named in its title. `nil` when neither is known.
    public let commit: String?
    public let url: URL
    public let assets: [Asset]
    /// The CI run number that built the release, from the footer of its notes or a `beta-N-sha`
    /// tag. `nil` when neither says.
    public let build: Int?
    /// A beta: published on every push, never marked latest.
    public let prerelease: Bool
    /// The release body as published, cut at `maxNotes` characters. `notes(turkish:)` cleans it.
    public let body: String

    public init(version: AppVersion, commit: String?, url: URL, assets: [Asset] = [],
                build: Int? = nil, prerelease: Bool = false, body: String = "") {
        self.version = version
        self.commit = commit
        self.url = url
        self.assets = assets
        self.build = build
        self.prerelease = prerelease
        self.body = String(body.prefix(Self.maxNotes))
    }

    /// The macOS build of this release: `AndroMac-<version>-macOS-arm64.dmg` for a stable one,
    /// `AndroMac-beta-<build>-macOS-arm64.dmg` for a beta.
    public var macImage: Asset? {
        assets.first { $0.name.hasPrefix("AndroMac-") && $0.name.hasSuffix("-macOS-arm64.dmg") }
    }

    /// The checksum file every release publishes. The updater refuses to install without it.
    public var checksums: Asset? { assets.first { $0.name == "SHA256SUMS.txt" } }

    /// `1.0.0 (fd7d47a)`, `1.0.0 beta 212 (fd7d47a)` for a beta, or just `1.0.0` when no commit is
    /// known. The words of the release title.
    public var label: String {
        let base = prerelease ? "\(version) beta \(build.map(String.init) ?? "?")" : version.description
        return commit.map { "\(base) (\($0))" } ?? base
    }

    public static let repo = "anilmetin0/AndroMac"

    /// The page that always points at the current stable build, whatever the version is.
    ///
    /// This is what the QR code in Settings encodes, so the phone can be pointed at the APK
    /// without typing anything.
    public static let latestURL = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// A GitHub release object → `Release`; `nil` when it carries no version or points elsewhere.
    public static func parse(_ json: Data) -> Release? {
        ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any]).flatMap(parse(object:))
    }

    /// The array `releases?per_page=N` returns, keeping the entries `parse` accepts.
    public static func parseList(_ json: Data) -> [Release] {
        ((try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] ?? []).compactMap(parse(object:))
    }

    private static func parse(object o: [String: Any]) -> Release? {
        // The link is opened in the browser: only ever a page of this repository, whatever the response says.
        guard let link = o["html_url"] as? String, link.hasPrefix("https://github.com/\(repo)/"),
              let url = URL(string: link) else { return nil }
        let name = o["name"] as? String ?? ""
        let tag = o["tag_name"] as? String ?? ""
        guard let version = AppVersion.find(in: tag) ?? AppVersion.find(in: name) else { return nil }
        let body = o["body"] as? String ?? ""
        return Release(
            version: version, commit: commit(target: o["target_commitish"] as? String) ?? commit(in: name),
            url: url, assets: assets(in: o), build: build(body: body, tag: tag),
            prerelease: o["prerelease"] as? Bool ?? false, body: body
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

    /// The build number: the footer every body ends with (`Build 212 · commit fd7d47a`), else the
    /// `beta-212-fd7d47a` tag. Only the tail of the body is searched, and at most 9 digits.
    public static func build(body: String, tag: String) -> Int? {
        let footer = String(body.suffix(2000)).matches(of: /Build (\d{1,9}) · commit/).last.flatMap { Int($0.1) }
        return footer ?? tag.firstMatch(of: /^beta-(\d{1,9})-/).flatMap { Int($0.1) }
    }

    /// The short form of the tag's target, when it is a commit hash rather than a branch name.
    public static func commit(target: String?) -> String? {
        guard let target, target.count >= 7, target.allSatisfy(\.isHexDigit) else { return nil }
        return String(target.prefix(7)).lowercased()
    }

    /// The `(fd7d47a)` part of a release title.
    public static func commit(in name: String) -> String? {
        name.firstMatch(of: /\(([0-9a-f]{7,40})\)/.ignoresCase()).map { String($0.1) }
    }

    /// Whether `release` should replace the running build.
    ///
    /// Stable: a greater version, or the same version with a greater build. Never a lower build,
    /// so a beta user who switches back to stable is not "updated" to an older build of the same
    /// version. Beta: a greater build whose version is not lower. A build whose commit is unknown
    /// ("local", empty) was not made by CI and its build number means nothing, so only a greater
    /// version counts for it; the same goes for a release without a build number.
    public static func isNewer(_ release: Release, than version: AppVersion, build: Int, commit: String?,
                               beta: Bool = false) -> Bool {
        let local = commit == nil || commit == "" || commit == "local"
        guard !local, let theirs = release.build else { return release.version > version }
        if beta { return theirs > build && release.version >= version }
        return release.version > version || (release.version == version && theirs > build)
    }

    /// Whether an unpacked app's Info.plist is this release: the same version and, when the
    /// release names a build, the same `CFBundleVersion`.
    public func matches(shortVersion: String, bundleVersion: String) -> Bool {
        guard AppVersion.find(in: shortVersion) == version else { return false }
        guard let build else { return true }
        return Int(bundleVersion) == build
    }

    /// The beta channel's pick from `releases?per_page=10`: the highest build, beta or stable.
    public static func newestBuild(_ releases: [Release]) -> Release? {
        releases.max { ($0.build ?? -1) < ($1.build ?? -1) }.flatMap { $0.build == nil ? nil : $0 }
    }

    // MARK: notes

    /// 20 000 characters: a long changelog is a few thousand.
    public static let maxNotes = 20_000

    /// The body as the update window shows it: Markdown, without the HTML the release page uses
    /// (`<details>`, `<summary>`, the `<sub>` footer) or the install links.
    ///
    /// The body has the English notes, the Turkish ones folded in `<details>`, then "Changes in
    /// this build". English drops the folded block; Turkish drops what comes before it, and falls
    /// back to English when there is no folded block.
    public func notes(turkish: Bool) -> String {
        var english: [String] = [], folded: [String] = []
        var inside = false, seen = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("<details") { inside = true; seen = true; continue }
            if t.hasPrefix("</details") { inside = false; continue }
            if t.hasPrefix("<summary") || t.hasPrefix("<sub>") || t.hasPrefix("**Install:**")
                || t.hasPrefix("**Kurulum:**") { continue }
            let line = t.isEmpty ? "" : String(raw).trimmingCharacters(in: .newlines)
                .replacing(/<\/?[a-zA-Z][^<>]{0,40}>/, with: "")
            if !inside { english.append(line) }
            if seen { folded.append(line) }
        }
        // Runs of blank lines collapse into one, and none at either end.
        var out: [String] = []
        for line in (turkish && seen ? folded : english) where !(line.isEmpty && (out.last?.isEmpty ?? true)) {
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
