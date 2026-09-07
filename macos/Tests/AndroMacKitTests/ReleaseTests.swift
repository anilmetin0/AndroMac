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

    @Test func sameVersionDifferentCommitIsNewer() {
        #expect(Release.isNewer(release(v100, "fd7d47a"), than: v100, commit: "ed0a803"))
        #expect(Release.isNewer(release(v100, "FD7D47A"), than: v100, commit: "ed0a803"))
    }

    @Test func sameVersionSameCommitIsNot() {
        #expect(!Release.isNewer(release(v100, "fd7d47a"), than: v100, commit: "fd7d47a"))
        #expect(!Release.isNewer(release(v100, "FD7D47A"), than: v100, commit: "fd7d47a"))
        #expect(!Release.isNewer(release(v100, nil), than: v100, commit: "fd7d47a"))
    }

    @Test func localBuildOnlyCountsGreaterVersions() {
        for mine in ["local", "", nil] {
            #expect(!Release.isNewer(release(v100, "fd7d47a"), than: v100, commit: mine))
            #expect(Release.isNewer(release(AppVersion(1, 0, 1), "fd7d47a"), than: v100, commit: mine))
        }
    }

    @Test func greaterVersionWithAnyCommitIsNewer() {
        #expect(Release.isNewer(release(AppVersion(1, 0, 1), nil), than: v100, commit: "fd7d47a"))
        #expect(Release.isNewer(release(AppVersion(2, 0, 0), "fd7d47a"), than: v100, commit: "fd7d47a"))
        #expect(!Release.isNewer(release(AppVersion(0, 9, 9), "abcdef0"), than: v100, commit: "fd7d47a"))
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
}
