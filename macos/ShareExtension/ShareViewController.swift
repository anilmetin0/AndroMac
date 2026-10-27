import AppKit
import UniformTypeIdentifiers

/// Finder's Share menu passes file URLs to the containing app, which selects the phone.
/// The extension never reads identity keys, connects to a phone or handles the file contents.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private var started = false
    private let message = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
        message.frame = NSRect(x: 20, y: 36, width: 280, height: 54)
        message.stringValue = String(localized: "Opening AndroMac…")
        view.addSubview(message)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 220, y: 8, width: 80, height: 28)
        view.addSubview(cancel)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        Task { await forwardFiles() }
    }

    private func forwardFiles() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= 50,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            message.stringValue = String(localized: "Choose up to 50 files in Finder, then share them with AndroMac.")
            return
        }
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL { continuation.resume(returning: url) }
                    else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                    else { continuation.resume(returning: nil) }
                }
            }
            guard let url, url.isFileURL else {
                message.stringValue = String(localized: "Could not read the shared files. Try sharing them from Finder.")
                return
            }
            urls.append(url)
        }
        // .app/Contents/PlugIns/AndroMacShare.appex
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // A second downloaded copy must hand off to the app already connected to the phone.
        let identifier = Bundle(url: app)?.bundleIdentifier ?? "dev.andromac"
        let recipient = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { !$0.isTerminated })?.bundleURL ?? app
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: recipient, configuration: configuration)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            message.stringValue = String(localized: "Could not open AndroMac. Open the app and try again.")
        }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
