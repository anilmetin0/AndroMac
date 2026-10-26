import AppKit
import Combine
import SwiftUI

/// All Mac entry points use the same destination and file validation rules.
@MainActor
enum FileSending {
    static var destination: AppState.DeviceState? {
        let state = AppState.shared
        // A focused phone without file support must not silently redirect a drop to another phone.
        return state.focusedDevice.flatMap { $0.caps.contains("file") ? $0 : nil }
    }

    @discardableResult
    static func send(_ urls: [URL], to peer: String? = nil) -> Bool {
        guard let target = peer ?? destination?.id,
              AppState.shared.devices.contains(where: { $0.id == target && $0.caps.contains("file") }) else {
            showError(String(localized: "Connect your phone to send files"))
            return false
        }
        guard !urls.isEmpty, urls.count <= 50,
              urls.allSatisfy({ url in
                  guard url.isFileURL,
                        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                        values.isRegularFile == true, let size = values.fileSize else { return false }
                  return size >= 0 && Int64(size) <= 4 * 1_024 * 1_024 * 1_024
              }) else {
            showError(String(localized: "Choose up to 50 files, each no larger than 4 GB. Folders cannot be sent."))
            return false
        }
        guard FileTransfer.shared.canQueue(urls.count) else {
            showError(String(localized: "The send queue is full. Wait for the current files to finish, then try again."))
            return false
        }
        FileTransfer.shared.send(urls: urls, to: target)
        return true
    }

    /// The share sheet always names the recipient before it sends, including with one phone.
    static func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        ShareFilesWindow.show(urls)
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not send files")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Retains each share until it is sent or cancelled. In particular a cold app launch must wait
/// for the phone's reconnect rather than lose Finder's files before the first hello arrives.
@MainActor
final class ShareFilesWindow: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: ShareFilesWindow] = [:]
    private let id = UUID()

    static func show(_ urls: [URL]) {
        let controller = ShareFilesWindow(urls: urls)
        open[controller.id] = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(urls: [URL]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: urls.count > 1 ? 320 : 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Send to Android")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ShareFilesView(urls: urls) { [weak self] in self?.close() }
            .environmentObject(AppState.shared))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) { Self.open[id] = nil }
}

private struct ShareFilesView: View {
    let urls: [URL]
    let close: () -> Void
    @EnvironmentObject private var state: AppState
    @State private var selected = ""
    private var phones: [AppState.DeviceState] { state.devices.filter { $0.caps.contains("file") } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            Text(urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) files"))
                .font(Theme.Font.title).lineLimit(2).truncationMode(.middle)
            // Every name is listed: the window can be opened by any app, so nothing goes unseen.
            if urls.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(urls, id: \.self) { url in
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.Font.label).foregroundStyle(.secondary)
                .frame(maxHeight: 96)
            }
            if phones.isEmpty {
                HStack(spacing: Theme.Space.small) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for phone").font(Theme.Font.body)
                }
                Text("Open AndroMac on the phone, on the same Wi‑Fi.")
                    .font(Theme.Font.label).foregroundStyle(.secondary)
            } else {
                Picker("Phone", selection: $selected) {
                    ForEach(phones) { phone in Text(phone.name).tag(phone.id) }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Send") {
                    if FileSending.send(urls, to: selected) { close() }
                }
                // Not the default button: a stray Return must not send files the user did not pick.
                .disabled(!phones.contains { $0.id == selected })
            }
        }
        .padding(Theme.Space.large)
        .frame(width: 360, height: urls.count > 1 ? 320 : 220)
        .onAppear(perform: selectPhone)
        .onChange(of: phones.map(\.id)) { _, _ in selectPhone() }
    }

    private func selectPhone() {
        if !phones.contains(where: { $0.id == selected }) {
            selected = phones.first(where: { $0.id == state.focusedDevice?.id })?.id ?? phones.first?.id ?? ""
        }
    }
}

/// A native drop destination; unlike a SwiftUI label on MenuBarExtra it receives Finder drags.
@MainActor
final class FileDropView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Ordinary clicks still belong to the menu bar button beneath this view.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onEnter?()
        return FileSending.destination == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        FileSending.destination == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onExit?() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        FileSending.destination != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty,
              let peer = FileSending.destination?.id else { return false }
        // The recipient is captured at the drop, before any asynchronous UI update.
        guard FileSending.send(urls, to: peer) else { return false }
        onDrop?(urls)
        return true
    }
}

/// Appears only during a file drag at the top edge. No idle timer, accessibility grant or polling.
/// The drag monitors exist only while a phone that accepts files is connected: otherwise every
/// window move and text selection on the Mac would wake AndroMac for nothing.
@MainActor
final class QuickSend {
    static let shared = QuickSend()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var devices: AnyCancellable?
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    /// The drag pasteboard keeps the last drag's files after it ends; only a newer drag counts.
    private var seenDrag = 0

    func start() {
        guard devices == nil else { return }
        devices = AppState.shared.$devices
            .map { $0.contains { $0.caps.contains("file") } }
            .removeDuplicates()
            .sink { [weak self] canSend in
                MainActor.assumeIsolated { canSend ? self?.watch() : self?.unwatch() }
            }
    }

    private func watch() {
        guard globalMonitor == nil else { return }
        seenDrag = NSPasteboard(name: .drag).changeCount
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { self.track(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { self.track(event) }
            return event
        }
    }

    private func unwatch() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        dismissal?.cancel()
        hide()
    }

    func attach(to button: NSStatusBarButton) {
        let drop = FileDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onEnter = { [weak self] in self?.show() }
        drop.onDrop = { [weak self] _ in self?.hide() }
        button.addSubview(drop)
    }

    private func track(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            seenDrag = NSPasteboard(name: .drag).changeCount
            // Every click on the Mac ends here; only a visible target has anything to dismiss.
            guard panel?.isVisible == true else { return }
            dismissal?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            dismissal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              point.y >= screen.frame.maxY - 40 else { return }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != seenDrag,
              board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        show(on: screen)
    }

    func show(on screen: NSScreen? = nil) {
        dismissal?.cancel()
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let drop = FileDropView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
            let hosted = NSHostingView(rootView: QuickSendLabel().environmentObject(AppState.shared))
            hosted.frame = drop.bounds
            hosted.autoresizingMask = [.width, .height]
            drop.addSubview(hosted)
            drop.onDrop = { [weak self] _ in self?.hide() }
            p.contentView = drop
            panel = p
        }
        guard let panel, let screen = screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 16,
                                     y: screen.visibleFrame.maxY - panel.frame.height - 12))
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func stop() {
        devices = nil
        unwatch()
    }
}

struct QuickSendLabel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: Theme.Space.medium) {
            Image(systemName: "arrow.up.doc").font(.system(size: 24))
                .foregroundStyle(FileSending.destination == nil ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text("Send to Android").font(Theme.Font.title)
                if let phone = state.focusedDevice, phone.caps.contains("file") {
                    Text("Drop files to send to \(phone.name)").font(Theme.Font.body)
                } else {
                    Text("Connect your phone to send files").font(Theme.Font.body)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.large)
        .frame(width: 320, height: 96)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .accessibilityElement(children: .combine)
    }
}
