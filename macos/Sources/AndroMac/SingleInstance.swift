import AppKit

/// One AndroMac per user. A second copy, a dev build next to the installed one or a second
/// double-click on a different path, would advertise a second Bonjour service, fight the first
/// over the phone and ask for the Keychain again. It hands over to the running copy and quits.
enum SingleInstance {

    /// Posted by a copy that is about to quit; the running copy answers by opening its window.
    static let showRequest = Notification.Name("dev.andromac.show")

    /// False when another copy is running. Restart and the updater start the new copy only after
    /// the old one has exited, so any other copy found here is really running.
    static func claim() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
        if running {
            DistributedNotificationCenter.default()
                .postNotificationName(showRequest, object: nil, deliverImmediately: true)
        }
        return !running
    }
}
