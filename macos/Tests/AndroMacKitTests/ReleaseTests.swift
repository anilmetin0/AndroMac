import Foundation
import Testing
@testable import AndroMacKit

struct ReleaseTests {

    private let url = URL(string: "https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.0")!
    private let v100 = AppVersion(1, 0, 0)

    private func release(_ version: AppVersion, _ commit: String?) -> Release {
        Release(version: version, commit: commit, url: url)
    }

    /// The QR code in Settings encodes this and nothing else, so it has to point at the repository's
    /// own releases page — the same rule `parse` enforces for links that arrive over the network.
    @Test func latestURLPointsAtThisRepositoryOnly() {
        #expect(Release.latestURL.absoluteString == "https://github.com/anilmetin0/AndroMac/releases/latest")
        #expect(Release.latestURL.absoluteString.hasPrefix("https://github.com/\(Release.repo)/"))
    }

    private func release(_ version: AppVersion, build: Int?, beta: Bool = false) -> Release {
        Release(version: version, commit: "fd7d47a", url: url, build: build, prerelease: beta)
    }

    @Test func stableIsNewerByVersionThenBuild() {
        #expect(Release.isNewer(release(v100, build: 12), than: v100, build: 11, commit: "ed0a803"))
        #expect(!Release.isNewer(release(v100, build: 11), than: v100, build: 11, commit: "ed0a803"))
        #expect(Release.isNewer(release(AppVersion(1, 0, 1), build: 3), than: v100, build: 11, commit: "ed0a803"))
        #expect(!Release.isNewer(release(AppVersion(0, 9, 9), build: 99), than: v100, build: 11, commit: "ed0a803"))
    }

    /// A beta user switching back to stable keeps the newer beta until a stable build passes it.
    @Test func stableNeverOffersALowerBuild() {
        #expect(!Release.isNewer(release(v100, build: 10), than: v100, build: 15, commit: "ed0a803"))
    }

    @Test func betaIsNewerByBuildWithoutGoingBackAVersion() {
        let own = AppVersion(1, 1, 0)
        #expect(Release.isNewer(release(own, build: 16, beta: true), than: own, build: 15, commit: "ed0a803", beta: true))
        #expect(!Release.isNewer(release(own, build: 15, beta: true), than: own, build: 15, commit: "ed0a803", beta: true))
        #expect(!Release.isNewer(release(v100, build: 99), than: own, build: 15, commit: "ed0a803", beta: true))
        #expect(Release.isNewer(release(AppVersion(1, 2, 0), build: 16, beta: true), than: own, build: 15, commit: "ed0a803", beta: true))
    }

    @Test func unknownBuildOrLocalCommitOnlyCountsGreaterVersions() {
        for mine in ["local", "", nil] {
            #expect(!Release.isNewer(release(v100, build: 50), than: v100, build: 1, commit: mine))
            #expect(Release.isNewer(release(AppVersion(1, 0, 1), build: 50), than: v100, build: 1, commit: mine))
        }
        #expect(!Release.isNewer(release(v100, build: nil), than: v100, build: 1, commit: "ed0a803"))
        #expect(Release.isNewer(release(AppVersion(1, 0, 1), build: nil), than: v100, build: 1, commit: "ed0a803"))
    }

    @Test func betaChannelPicksTheHighestBuild() {
        let list = [release(v100, build: 20), release(v100, build: 23, beta: true), release(v100, build: nil),
                    release(v100, build: 21, beta: true)]
        #expect(Release.newestBuild(list)?.build == 23)
        #expect(Release.newestBuild([release(v100, build: nil)]) == nil)
        #expect(Release.newestBuild([]) == nil)
    }

    @Test func buildComesFromTheFooterThenTheBetaTag() {
        #expect(Release.build(body: "notes\n\n<sub>Build 212 · commit fd7d47a · APK signing: release</sub>", tag: "v1.0.0") == 212)
        // The current form: an HTML comment on the install line, hidden on the release page.
        let hidden = "### New\n\n- A change\n\n**Install:** see the [README](https://x). <!-- Build 214 · commit fd7d47a -->"
        #expect(Release.build(body: hidden, tag: "v1.2.0") == 214)
        #expect(!Release(version: AppVersion(1, 2, 0), commit: nil, url: URL(string: "https://x")!, assets: [],
                         build: 214, prerelease: true, body: hidden).notes(turkish: false).contains("Build"))
        #expect(Release.build(body: "", tag: "beta-213-fd7d47a") == 213)
        #expect(Release.build(body: "Build 1234567890 · commit x", tag: "v1.0.0") == nil)
        #expect(Release.build(body: "", tag: "v1.0.0") == nil)
    }

    @Test func parsesABeta() throws {
        let json = Data("""
        [{"tag_name":"beta-213-fd7d47a","name":"AndroMac 1.0.0 beta 213 (fd7d47a)","prerelease":true,\
        "target_commitish":"fd7d47a0000000000000000000000000000000000",\
        "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/beta-213-fd7d47a",\
        "body":"## What's new\\n\\n<sub>Build 213 · commit fd7d47a</sub>",\
        "assets":[{"name":"AndroMac-beta-213-macOS-arm64.dmg","size":5,\
         "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/beta-213-fd7d47a/AndroMac-beta-213-macOS-arm64.dmg"}]},\
        {"tag_name":"v1.0.0","name":"AndroMac 1.0.0","html_url":"https://github.com/someone-else/x"}]
        """.utf8)
        let list = Release.parseList(json)
        #expect(list.count == 1)
        let r = try #require(list.first)
        #expect(r.version == v100)
        #expect(r.build == 213)
        #expect(r.prerelease)
        #expect(r.label == "1.0.0 nightly 213 (fd7d47a)")
        #expect(r.macImage?.name == "AndroMac-beta-213-macOS-arm64.dmg")
    }

    private static let body = """
    ## What's new

    - Faster pairing, **bold** and [a link](https://example.com)
    - Second item


    <details>
    <summary><b>Türkçe</b></summary>

    ## Yenilikler

    - Daha hızlı eşleşme
    </details>

    ## Changes in this build

    - fix(macos): run one copy at a time (d6125ce)

    **Install:** see the [README](https://github.com/anilmetin0/AndroMac#install) ·
    **Kurulum:** [README.tr](https://github.com/anilmetin0/AndroMac/blob/main/README.tr.md#kurulum)

    <sub>Build 212 · commit fd7d47a · APK signing: release · checksums in SHA256SUMS.txt</sub>
    """

    @Test func englishNotesDropTheTurkishBlockAndTheHTML() {
        let notes = Release(version: v100, commit: nil, url: url, body: Self.body).notes(turkish: false)
        #expect(notes == """
        ## What's new

        - Faster pairing, **bold** and [a link](https://example.com)
        - Second item

        ## Changes in this build

        - fix(macos): run one copy at a time (d6125ce)
        """)
    }

    @Test func turkishNotesKeepTheFoldedBlockAndTheBuildChanges() {
        let notes = Release(version: v100, commit: nil, url: url, body: Self.body).notes(turkish: true)
        #expect(notes == """
        ## Yenilikler

        - Daha hızlı eşleşme

        ## Changes in this build

        - fix(macos): run one copy at a time (d6125ce)
        """)
        // No folded block: English is better than nothing.
        #expect(Release(version: v100, commit: nil, url: url, body: "- one\n").notes(turkish: true) == "- one")
    }

    @Test func notesAreBounded() {
        let r = Release(version: v100, commit: nil, url: url, body: String(repeating: "x", count: 50_000))
        #expect(r.body.count == Release.maxNotes)
    }

    @Test func parsesTagForVersionAndNameForCommit() throws {
        let json = Data("""
        {"tag_name":"v1.0.0","name":"AndroMac 1.0.0 (fd7d47a)",\
        "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.0"}
        """.utf8)
        let r = try #require(Release.parse(json))
        #expect(r.version == v100)
        #expect(r.commit == "fd7d47a")
        #expect(r.url == url)
        #expect(r.label == "1.0.0 (fd7d47a)")
    }

    @Test func tagTargetBeatsTheTitle() throws {
        let json = Data("""
        {"tag_name":"v1.0.0","name":"AndroMac 1.0.0","target_commitish":"E355642A1B2C3D4E5F60718293A4B5C6D7E8F901",\
        "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.0"}
        """.utf8)
        let r = try #require(Release.parse(json))
        #expect(r.commit == "e355642")
        #expect(r.label == "1.0.0 (e355642)")
        #expect(Release.commit(target: "main") == nil)
        #expect(Release.commit(target: "abc12") == nil)
    }

    @Test func nameWithoutParenthesesHasNoCommit() throws {
        let json = Data("""
        {"tag_name":"v1.0.0","name":"AndroMac 1.0.0",\
        "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.0"}
        """.utf8)
        let r = try #require(Release.parse(json))
        #expect(r.commit == nil)
        #expect(r.label == "1.0.0")
        #expect(Release.commit(in: "AndroMac 1.0.0 (12)") == nil)
        #expect(Release.commit(in: "AndroMac 1.0.0 (not-a-hash)") == nil)
    }

    @Test func linkOutsideTheRepoIsRejected() {
        let json = Data("""
        {"tag_name":"v9.9.9","name":"AndroMac 9.9.9 (fd7d47a)",\
        "html_url":"https://github.com/someone-else/AndroMac/releases/tag/v9.9.9"}
        """.utf8)
        #expect(Release.parse(json) == nil)
        #expect(Release.parse(Data("not json".utf8)) == nil)
    }
    @Test func parsesTheAssetsTheUpdaterNeeds() throws {
        let json = Data("""
        {"tag_name":"v1.0.0","name":"AndroMac 1.0.0 (fd7d47a)",\
        "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.0",\
        "assets":[\
        {"name":"AndroMac-1.0.0-macOS-arm64.dmg","size":1234,\
         "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.0/AndroMac-1.0.0-macOS-arm64.dmg"},\
        {"name":"AndroMac-1.0.0-android.apk","size":99,\
         "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.0/AndroMac-1.0.0-android.apk"},\
        {"name":"SHA256SUMS.txt","size":12,\
         "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.0/SHA256SUMS.txt"}]}
        """.utf8)
        let r = try #require(Release.parse(json))
        #expect(r.assets.count == 3)
        #expect(r.macImage?.name == "AndroMac-1.0.0-macOS-arm64.dmg")
        #expect(r.macImage?.size == 1234)
        #expect(r.checksums?.name == "SHA256SUMS.txt")
    }

    /// The updater downloads whatever this returns, so an asset served from anywhere but this
    /// repository's releases is dropped rather than trusted.
    @Test func assetsFromElsewhereAreDropped() throws {
        let json = Data("""
        {"tag_name":"v1.0.0","name":"AndroMac 1.0.0 (fd7d47a)",\
        "html_url":"https://github.com/anilmetin0/AndroMac/releases/tag/v1.0.0",\
        "assets":[\
        {"name":"AndroMac-1.0.0-macOS-arm64.dmg",\
         "browser_download_url":"https://example.com/AndroMac-1.0.0-macOS-arm64.dmg"},\
        {"name":"../escape-macOS-arm64.dmg",\
         "browser_download_url":"https://github.com/anilmetin0/AndroMac/releases/download/v1.0.0/x.dmg"}]}
        """.utf8)
        let r = try #require(Release.parse(json))
        #expect(r.assets.isEmpty)
        #expect(r.macImage == nil)
    }

    /// The updater installs only the bundle the release announced: same version, and the same
    /// CFBundleVersion when the release carries a build number.
    @Test func unpackedBundleMustMatchVersionAndBuild() {
        let built = release(v100, build: 212)
        #expect(built.matches(shortVersion: "1.0.0", bundleVersion: "212"))
        #expect(!built.matches(shortVersion: "1.0.0", bundleVersion: "211"))
        #expect(!built.matches(shortVersion: "1.0.0", bundleVersion: ""))
        #expect(!built.matches(shortVersion: "1.0.1", bundleVersion: "212"))
        let unnumbered = release(v100, build: nil)
        #expect(unnumbered.matches(shortVersion: "1.0.0", bundleVersion: "1"))
        #expect(!unnumbered.matches(shortVersion: "0.9.0", bundleVersion: "1"))
    }

    // MARK: the real GitHub API

    /// Responses saved from api.github.com on 2026-09-24 (`releases/latest`, `releases?per_page=10`)
    /// and the v1.1.0 `SHA256SUMS.txt`, whose hashes match the published DMG and APK.
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/github/\(name)"))
    }

    @Test func realLatestReleaseHasWhatTheUpdaterNeeds() throws {
        let r = try #require(Release.parse(try fixture("releases-latest.json")))
        #expect(r.version == AppVersion(1, 1, 0))
        #expect(r.build == 42)
        #expect(r.commit == "e105e58")
        #expect(!r.prerelease)
        let image = try #require(r.macImage)
        #expect(image.name == "AndroMac-1.1.0-macOS-arm64.dmg")
        #expect(image.url.absoluteString == "https://github.com/anilmetin0/AndroMac/releases/download/v1.1.0/AndroMac-1.1.0-macOS-arm64.dmg")
        #expect(r.checksums?.name == "SHA256SUMS.txt")
        let sums = try #require(String(data: try fixture("SHA256SUMS-v1.1.0.txt"), encoding: .utf8))
        #expect(Release.checksum(for: image.name, in: sums) == "587c9b1e49ebd95f6d144140c4cc82db07be1ee7d3e3604da192c49cfda41d76")
        #expect(r.matches(shortVersion: "1.1.0", bundleVersion: "42"))
    }

    /// Both channels on the real list: a 1.0.0 copy is offered 1.1.0, the 1.1.0 copy nothing, and a
    /// beta after 1.1.0 that switches Beta off is not "updated" back to the stable build.
    @Test func realReleaseListPerChannel() throws {
        let list = Release.parseList(try fixture("releases-per_page-10.json"))
        #expect(list.map(\.label) == ["1.1.0 (e105e58)", "1.0.0 (db1e492)"])
        let latest = try #require(Release.parse(try fixture("releases-latest.json")))
        let beta = try #require(Release.newestBuild(list))
        #expect(beta == latest)
        let v110 = AppVersion(1, 1, 0)
        for channel in [false, true] {
            let pick = channel ? beta : latest
            #expect(Release.isNewer(pick, than: v100, build: 27, commit: "db1e492", beta: channel))
            #expect(!Release.isNewer(pick, than: v110, build: 42, commit: "e105e58", beta: channel))
            #expect(!Release.isNewer(pick, than: v110, build: 57, commit: "abc1234", beta: channel))
        }
    }

    @Test func checksumLineMatchesTheExactName() {
        let hash = String(repeating: "ab", count: 32)
        let name = "AndroMac-1.1.0-macOS-arm64.dmg"
        #expect(Release.checksum(for: name, in: "\(hash.uppercased())  \(name)\n") == hash)
        #expect(Release.checksum(for: name, in: "\(hash) *\(name)\r\n") == hash)
        #expect(Release.checksum(for: name, in: "\(hash)  evil-\(name)\n") == nil)
        #expect(Release.checksum(for: name, in: "abc123  \(name)\n") == nil)
        #expect(Release.checksum(for: name, in: "") == nil)
    }
}
