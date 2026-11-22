import AndroMacKit
import AppKit
import SwiftUI

/// Dragging files onto the menu bar icon unfolds the paired phones under it; dropping the files
/// on one sends them there. A phone that is away gets them when it connects (`FileTransfer`).
/// The shelf lives for one drag: it goes away once the mouse button is up.
@MainActor
enum DropShelf {

    final class Model: ObservableObject {
        struct Phone: Identifiable, Equatable {
            let id: String
            let name: String
            let connected: Bool
        }
        @Published var phones: [Phone] = []
        @Published var target: String?
    }

    static let rowHeight: CGFloat = 44
    static let padding: CGFloat = Theme.Space.tight
    static let width: CGFloat = 240

    private static var panel: NSPanel?
    private static var watch: Timer?
    private static let model = Model()

    /// Phones a file can go to now or later: connected ones that take files, and paired ones away.
    private static func phones() -> [Model.Phone] {
        let live = AppState.shared.devices
        return Store.shared.pairedDevices.compactMap { device in
            if let session = live.first(where: { $0.id == device.id }) {
                return session.caps.contains("file")
                    ? .init(id: device.id, name: AppState.displayName(session.name) ?? device.name, connected: true) : nil
            }
            return .init(id: device.id, name: AppState.displayName(device.name) ?? device.name, connected: false)
        }
    }

    static func show(below button: NSView) {
        guard panel == nil, let window = button.window else { return }
        let phones = phones()
        guard !phones.isEmpty else { return }
        model.phones = phones
        model.target = nil

        let height = CGFloat(phones.count) * rowHeight + padding * 2
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        var frame = NSRect(x: icon.midX - width / 2, y: icon.minY - Theme.Space.tight - height, width: width, height: height)
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX + Theme.Space.tight), screen.maxX - width - Theme.Space.tight)
        }

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = ShelfDropView(rootView: ShelfView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel

        // The drag has no end event for a view it never entered: the button state tells when it is over.
        watch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { if NSEvent.pressedMouseButtons & 1 == 0 { hide() } }
        }
    }

    static func hide() {
        watch?.invalidate()
        watch = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    /// The row under a point in the shelf's own, top-down coordinates.
    static func phone(atTop y: CGFloat) -> Model.Phone? {
        let index = Int(((y - padding) / rowHeight).rounded(.down))
        return model.phones.indices.contains(index) ? model.phones[index] : nil
    }

    /// One drop target for the whole shelf: a SwiftUI `onDrop` per row would need the item
    /// providers' asynchronous loading, while the pasteboard is read here at once.
    final class ShelfDropView: NSHostingView<ShelfView> {
        required init(rootView: ShelfView) {
            super.init(rootView: rootView)
            registerForDraggedTypes([.fileURL])
        }

        @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func phone(for sender: any NSDraggingInfo) -> Model.Phone? {
            let point = convert(sender.draggingLocation, from: nil)
            return DropShelf.phone(atTop: isFlipped ? point.y : bounds.height - point.y)
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            let phone = phone(for: sender)
            if model.target != phone?.id { model.target = phone?.id }
            return phone == nil ? [] : .copy
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) { model.target = nil }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { DropShelf.hide() }
            guard let phone = phone(for: sender),
                  let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                      options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            return FileSending.send(urls, to: phone.id)
        }
    }
}

struct ShelfView: View {
    @ObservedObject var model: DropShelf.Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.phones.enumerated()), id: \.element.id) { index, phone in
                row(phone)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : -10)
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75)
                        .delay(Double(index) * 0.05), value: shown)
            }
        }
        .padding(DropShelf.padding)
        .frame(width: DropShelf.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .scaleEffect(shown || reduceMotion ? 1 : 0.92, anchor: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: shown)
        .onAppear { shown = true }
    }

    private func row(_ phone: DropShelf.Model.Phone) -> some View {
        let targeted = model.target == phone.id
        return HStack(spacing: Theme.Space.small) {
            Image(systemName: targeted ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                .font(.system(size: 18))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(phone.name).font(Theme.Font.body.weight(.medium)).lineLimit(1)
                Text(phone.connected ? String(localized: "Connected") : String(localized: "Sends when it connects"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.small)
        .frame(height: DropShelf.rowHeight)
        .background(targeted ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .scaleEffect(targeted && !reduceMotion ? 1.03 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: targeted)
    }
}
