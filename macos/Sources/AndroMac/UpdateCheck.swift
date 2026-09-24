import AndroMacKit
import AppKit
import Foundation
import UserNotifications

/// Finds the newest AndroMac release on GitHub.
///
/// This is the ONLY code in the app that talks to anything beyond the local network, and it runs
/// solely when the user turned it on: at launch and when the panel opens, at most once a day.
/// One HTTPS GET to api.github.com per check (`releases/latest`, or `releases?per_page=10` on the
/// beta channel); the request carries the app version in the User-Agent and nothing else. What
/// counts as "newer" is `Release.isNewer` in AndroMacKit. Mirrors `UpdateCheck.kt` on Android.
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

    /// The CI run that built this copy; 1 for local builds, 0 if unreadable.
    nonisolated static let currentBuild: Int =
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

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
        UpdateWindow.showDemoIfAsked()
    }

    /// The automatic check: on, and not run within the last day. Cheap to call often.
    ///
    /// Opening the panel is also the moment a downloaded update that was waiting for the Mac to
    /// be idle gets another go, whatever the daily window says.
    func checkIfDue() {
        guard !DemoMode.isOn else { return }
        Updater.shared.installIfWaiting()
        guard Store.shared.updateCheck else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        Task { await checkNow() }
    }

    /// The check at launch, plus the offer that follows it.
    ///
    /// A release the user skipped is never raised again, and neither is one they have already been
    /// asked about in this run: the prompt is an offer, not a nag.
    func checkAtLaunch() async {
        guard !DemoMode.isOn else { return }
        announceIfUpdated()
        guard Store.shared.updateCheck else { return }
        let due = lastChecked.map { Date().timeIntervalSince($0) >= Self.interval } ?? true
        // A release restored from disk carries only its version, commit and page: no asset list,
        // build or notes. A pending offer is worth one request even inside the daily window.
        let pending = Store.shared.updateFound != nil && available?.assets.isEmpty != false
        if due || pending { await checkNow() }
        offerIfAvailable()
    }

    /// The update window: notes, then Install now, Later, or Skip this version. Not while the
    /// automatic install is going to take care of it anyway.
    func offerIfAvailable() {
        guard let release = available, !offered else { return }
        guard release.label != Store.shared.updateSkipped else { return }
        if Updater.installsItself(release) { return }
        offered = true
        UpdateWindow.show(release)
    }

    /// Asked once per launch, whatever else opens the panel afterwards.
    private var offered = false

    /// The Beta switch moved. On, the beta channel is asked at once, the switch being the
    /// consent: a newer beta is downloaded to install when idle, or offered in the update window.
    /// Off, stable answers again, and never with a lower build than the one running (`isNewer`),
    /// so switching back is never a downgrade.
    func channelChanged() {
        // What was found or prepared on the old channel is no answer for this one.
        Updater.shared.cancelWaiting()
        available = nil
        Store.shared.updateFound = nil
        guard Store.shared.updateBeta || Store.shared.updateCheck, !DemoMode.isOn else { return }
        offered = false
        offerAfterCheck = true
        Task { await checkNow() }
    }

    /// Set by `channelChanged`: the check that is running, or the next one, ends with the offer.
    private var offerAfterCheck = false

    /// "Check now" works even while the automatic check is off: an explicit click is consent.
    func checkNow() async {
        // A demo sends nothing beyond this Mac; its update window has its own invented release.
        guard !checking, !DemoMode.isOn else { return }
        checking = true
        defer {
            checking = false
            if offerAfterCheck { offerAfterCheck = false; offerIfAvailable() }
        }
        do {
            // The Beta switch may move while the request is out: then the answer is for the
            // other channel, and the one now selected is asked instead.
            var beta: Bool
            var release: Release?
            repeat {
                beta = Store.shared.updateBeta
                release = try await Self.newest(beta: beta)
            } while beta != Store.shared.updateBeta
            available = release
            lastError = nil
            lastChecked = Date()
            Store.shared.updateLastCheck = lastChecked
            Store.shared.updateFound = release.map { ($0.version.description, $0.commit, $0.url.absoluteString) }
            if let release, release.label != Store.shared.updateSkipped, Updater.installsItself(release) {
                Updater.shared.installWhenIdle(release)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: after an update

    /// `1.0.0 (fd7d47a)`, the words the notification uses.
    nonisolated static var currentLabel: String {
        guard let commit = currentCommit, !commit.isEmpty else { return current.description }
        return "\(current) (\(commit))"
    }

    /// This build in one string: version, CI run and commit.
    nonisolated static let runningBuild = "\(current) \(currentBuild) \(currentCommit ?? "")"

    /// The first launch of a different build than last time says so, once.
    private func announceIfUpdated() {
        let last = Store.shared.updateLastRun
        Store.shared.updateLastRun = Self.runningBuild
        guard !last.isEmpty, last != Self.runningBuild else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "AndroMac was updated to \(Self.currentLabel)")
        let request = UNNotificationRequest(identifier: "andromac.updated", content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) } catch {
                NSLog("AndroMac: could not post the update notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: lookup (nonisolated: plain data in, plain data out)

    /// The release to offer, if it is newer than the running build (`Release.isNewer`); `nil` =
    /// up to date. Stable reads `releases/latest`, which never returns a prerelease; beta reads
    /// the last ten releases and takes the highest build.
    nonisolated static func newest(beta: Bool) async throws -> Release? {
        let release: Release?
        if beta {
            release = try await fetch("?per_page=10").flatMap { Release.newestBuild(Release.parseList($0)) }
        } else {
            release = try await fetch("/latest").flatMap(Release.parse)
        }
        guard let release, Release.isNewer(release, than: current, build: currentBuild,
                                            commit: currentCommit, beta: beta) else { return nil }
        return release
    }

    /// The response body, `nil` for 404, throws for anything else. Bounded: 1 MiB is far more
    /// than ten release objects need.
    private nonisolated static func fetch(_ path: String) async throws -> Data? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases\(path)")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AndroMac/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 404: return nil
        case 200: return data.count <= 1024 * 1024 ? data : nil
        default: throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
    }

    /// The persisted result, re-judged against this build: after an upgrade it is no longer news.
    /// It has no build number, so only a greater version survives until the launch check refreshes it.
    private static func stillNewer(_ found: (version: String, commit: String?, url: String)) -> Release? {
        guard let v = AppVersion.find(in: found.version), let u = URL(string: found.url) else { return nil }
        let release = Release(version: v, commit: found.commit, url: u)
        return Release.isNewer(release, than: current, build: currentBuild, commit: currentCommit) ? release : nil
    }
}
