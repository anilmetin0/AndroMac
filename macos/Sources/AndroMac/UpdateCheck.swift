import AndroMacKit
import AppKit
import Foundation

/// Finds the newest AndroMac release on GitHub.
///
/// This is the ONLY code in the app that talks to anything beyond the local network, and it runs
/// solely when the user turned it on: at launch and when the panel opens, at most once a day.
/// One HTTPS GET to api.github.com (`releases/latest`); the request carries the app version in the
/// User-Agent and nothing else. What counts as "newer" is `Release.isNewer` in AndroMacKit.
/// Mirrors `UpdateCheck.kt` on Android.
@MainActor
final class UpdateCheck: ObservableObject {

    static let shared = UpdateCheck()

    nonisolated static let repo = Release.repo
    nonisolated static let releasesPage = URL(string: "https://github.com/\(repo)/releases")!
    /// Once a day is plenty, and stays far below GitHub's unauthenticated rate limit.
    static let interval: TimeInterval = 24 * 60 * 60

    /// The version this build reports, or 0.0.0 if Info.plist is somehow unreadable.
    nonisolated static let current: AppVersion = {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return AppVersion.find(in: short) ?? AppVersion(0, 0, 0)
    }()

    /// The commit this build was made from; "local" (or absent) for builds outside CI.
    nonisolated static let currentCommit: String? = Bundle.main.infoDictionary?["AndroMacCommit"] as? String

    /// The newest known release, only while it is still newer than what is running.
    @Published private(set) var available: Release?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checking = false
    /// Not persisted: a flaky network at one launch should not show a warning at the next.
    @Published private(set) var lastError: String?

    private init() {
        lastChecked = Store.shared.updateLastCheck
        available = Store.shared.updateFound.flatMap(Self.stillNewer)
    }

    /// The automatic check: on, and not run within the last day. Cheap to call often.
    func checkIfDue() {
        guard Store.shared.updateCheck else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        Task { await checkNow() }
    }

    /// The check at launch, plus the offer that follows it.
    ///
    /// A release the user skipped is never raised again, and neither is one they have already been
    /// asked about in this run — the prompt is an offer, not a nag.
    func checkAtLaunch() async {
        guard Store.shared.updateCheck else { return }
        let due = lastChecked.map { Date().timeIntervalSince($0) >= Self.interval } ?? true
        // A release restored from disk carries only its version, commit and page — no asset list,
        // which is what the installer downloads. A pending offer is worth one request even inside
        // the daily window.
        if due || available?.assets.isEmpty == true { await checkNow() }
        offerIfAvailable()
    }

    /// "AndroMac 1.1.0 is available" — Install now, Later, or Skip this version.
    func offerIfAvailable() {
        guard let release = available, !offered else { return }
        guard release.label != Store.shared.updateSkipped else { return }
        offered = true

        let alert = NSAlert()
        alert.messageText = String(localized: "AndroMac \(release.label) is available")
        alert.informativeText = release.macZip == nil
            ? String(localized: "The release page has the download.")
            : String(localized: "AndroMac can download and install it now, then restart itself.")
        alert.addButton(withTitle: release.macZip == nil
                        ? String(localized: "Open the release page") : String(localized: "Install now"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Skip this version"))
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if release.macZip == nil {
                NSWorkspace.shared.open(release.url)
            } else {
                Task { await Updater.shared.install(release) }
            }
        case .alertThirdButtonReturn:
            Store.shared.updateSkipped = release.label
        default:
            break
        }
    }

    /// Asked once per launch, whatever else opens the panel afterwards.
    private var offered = false

    /// "Check now" works even while the automatic check is off: an explicit click is consent.
    func checkNow() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let release = try await Self.newest(current: Self.current)
            available = release
            lastError = nil
            lastChecked = Date()
            Store.shared.updateLastCheck = lastChecked
            Store.shared.updateFound = release.map { ($0.version.description, $0.commit, $0.url.absoluteString) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: lookup (nonisolated: plain data in, plain data out)

    /// `releases/latest`, if it is newer than the running build (`Release.isNewer`). `nil` = up to date.
    nonisolated static func newest(current: AppVersion) async throws -> Release? {
        guard let json = try await fetch("latest"), let release = Release.parse(json),
              Release.isNewer(release, than: current, commit: currentCommit) else { return nil }
        return release
    }

    /// The response body, `nil` for 404, throws for anything else. Bounded: 256 KiB is far more
    /// than one release object needs.
    private nonisolated static func fetch(_ path: String) async throws -> Data? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/\(path)")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AndroMac/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 404: return nil
        case 200: return data.count <= 256 * 1024 ? data : nil
        default: throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
    }

    /// The persisted result, re-judged against this build: after an upgrade it is no longer news.
    private static func stillNewer(_ found: (version: String, commit: String?, url: String)) -> Release? {
        guard let v = AppVersion.find(in: found.version), let u = URL(string: found.url) else { return nil }
        let release = Release(version: v, commit: found.commit, url: u)
        return isNewer(release) ? release : nil
    }

    private static func isNewer(_ release: Release) -> Bool {
        Release.isNewer(release, than: current, commit: currentCommit)
    }
}
