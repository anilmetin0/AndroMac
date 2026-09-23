import AndroMacKit
import AppKit
import SwiftUI

/// The update offer: what changed in the release, then Install now, Later or Skip this version.
/// Its own window rather than an alert, because the notes need room to be read.
@MainActor
enum UpdateWindow {

    private static var window: NSWindow?

    static func show(_ release: Release) {
        close()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // The title names the window in Mission Control and the Window menu; the view shows it.
        window.title = "AndroMac " + release.label
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: UpdateView(release: release) { close() })
        window.contentViewController = host
        // Sized from the view now: left to the hosting controller, the window sometimes came up
        // zero points wide.
        window.setContentSize(host.view.fittingSize)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }

    /// `ANDROMAC_DEMO=1 ANDROMAC_DEMO_UPDATE=1` raises the window with an invented release, for
    /// the screenshot. Nothing in it can install: `Updater` refuses to run in a demo.
    static func showDemoIfAsked() {
        guard DemoMode.isOn, ProcessInfo.processInfo.environment["ANDROMAC_DEMO_UPDATE"] == "1" else { return }
        let body = """
        ## What's new

        - **Settings** has its own window, with every section in the sidebar.
        - The clipboard history keeps the last 20 items, and one click copies an item back.
        - The phone's name shows while it connects.

        <details>
        <summary><b>Türkçe</b></summary>

        ## Yenilikler

        - **Ayarlar** artık kendi penceresinde, her bölüm kenar çubuğunda.
        - Pano geçmişi son 20 öğeyi tutar; tek tıkla geri kopyalanır.
        - Telefonun adı bağlanırken görünür.
        </details>

        ## Changes in this build

        - fix(macos): run one copy at a time (d6125ce)
        - docs: new screenshots, guide and changelog for the UI changes (dfd821c)

        <sub>Build 212 · commit fd7d47a · APK signing: release · checksums in SHA256SUMS.txt</sub>
        """
        let base = "https://github.com/\(Release.repo)/releases/download/v1.1.0/"
        let assets = ["AndroMac-1.1.0-macOS-arm64.dmg", "SHA256SUMS.txt"].map {
            Release.Asset(name: $0, url: URL(string: base + $0)!, size: 0)
        }
        let release = Release(version: AppVersion(1, 1, 0), commit: "fd7d47a", url: Release.latestURL,
                              assets: assets, build: 212, body: body)
        // After the demo's main window, which would otherwise take the focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { show(release) }
    }
}

struct UpdateView: View {

    let release: Release
    let dismiss: @MainActor () -> Void
    @ObservedObject private var updater = Updater.shared

    /// The Turkish notes when the app runs in Turkish, the English ones otherwise.
    private var notes: String {
        release.notes(turkish: Bundle.main.preferredLocalizations.first == "tr")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.medium) {
            Text("AndroMac " + release.label)
                .font(Theme.Font.title)

            if !notes.isEmpty {
                ScrollView {
                    ReleaseNotes(markdown: notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.medium)
                }
                .frame(height: 300)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .fill(Color.secondary.opacity(0.08))
                )
            }

            if case .failed(let reason) = updater.phase {
                Text(reason)
                    .font(Theme.Font.label)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.small) {
                Button("Skip this version") {
                    Store.shared.updateSkipped = release.label
                    Updater.shared.cancelWaiting()
                    dismiss()
                }
                .secondaryAction()
                Spacer(minLength: 0)
                Button("Later") { dismiss() }
                    .secondaryAction()
                    .keyboardShortcut(.cancelAction)
                if Updater.canInstall(release) {
                    Button("Install now") {
                        dismiss()
                        Task { await Updater.shared.install(release) }
                    }
                    .prominentAction()
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open the release page") {
                        dismiss()
                        NSWorkspace.shared.open(release.url)
                    }
                    .prominentAction()
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(Theme.Space.large)
        .frame(width: 460)
    }
}

/// The release notes, drawn the way the release page draws them, near enough: headings, bullets,
/// and inline Markdown (bold, code, links) in each line.
struct ReleaseNotes: View {

    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            ForEach(Array(markdown.split(separator: "\n").enumerated()), id: \.offset) { index, line in
                row(String(line), first: index == 0)
            }
        }
        .font(Theme.Font.body)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ line: String, first: Bool) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            Text(Self.inline(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                .font(Theme.Font.heading)
                .padding(.top, first ? 0 : Theme.Space.small)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                Text(Self.inline(String(trimmed.dropFirst(2))))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(Self.inline(trimmed)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
