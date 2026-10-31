import AndroMacKit
import AppKit
import Combine
import SwiftUI

/// The phone's SMS conversations, held only while the main window's Messages page is open
/// (PROTOCOL §5, Messages). Nothing is written to disk: leaving the page drops every thread and
/// message, and opening it asks the phone again. No timer and no polling: the phone says
/// `sms_changed` and the page asks again only then (§6).
@MainActor
final class Messages: ObservableObject {

    static let shared = Messages()

    enum Phase: Equatable { case disconnected, loading, off, noPermission, ready }

    /// A text sent from this window, shown before the phone has it in its own store.
    struct Outgoing: Identifiable, Equatable {
        enum State: Equatable { case pending, sent, failed(String) }
        /// The `sms_send` id, which `sms_sent` echoes.
        let id: String
        let to: String
        let body: String
        let date: Date
        var thread: Int64?
        var state: State
    }

    enum Bubble: Identifiable, Equatable {
        case message(SMS.Message)
        case local(Outgoing)

        var id: String {
            switch self {
            case .message(let m): return "m\(m.id)"
            case .local(let o): return "l\(o.id)"
            }
        }

        var date: Date {
            switch self {
            case .message(let m): return m.date
            case .local(let o): return o.date
            }
        }
    }

    /// The phone the window shows: the panel's open phone when it has Messages, otherwise the first
    /// connected one that does.
    @Published private(set) var deviceID: String?
    @Published private(set) var phoneName = ""
    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var threads: [SMS.Thread] = []
    @Published private(set) var selection: Int64?
    @Published private(set) var composingNew = false
    @Published var newNumber = ""
    @Published private(set) var messages: [SMS.Message] = []
    @Published private(set) var conversationLoading = false
    @Published private(set) var outgoing: [Outgoing] = []
    /// Kept apart from the model, so a keystroke redraws the composer and not the whole window.
    let draft = Draft()

    @MainActor
    final class Draft: ObservableObject {
        @Published var text = ""
    }

    private var isOpen = false
    private var watch: AnyCancellable?
    /// A text went to a number with no conversation in the list yet; once the list has one, it opens.
    private var selectWhenListed: String?

    // MARK: window

    func open() {
        guard !isOpen else { return }
        isOpen = true
        // Event-driven: AppState publishes when a phone connects, leaves, advertises its caps or the
        // panel switches phones. The first value arrives at once and picks the phone.
        watch = AppState.shared.$devices
            .combineLatest(AppState.shared.$focusedDeviceID)
            .sink { [weak self] devices, focused in
                MainActor.assumeIsolated { self?.follow(devices, focused: focused) }
            }
    }

    func close() {
        isOpen = false
        watch = nil
        deviceID = nil
        reset()
        phase = .disconnected
    }

    private func reset() {
        phoneName = ""
        threads = []; messages = []; outgoing = []
        selection = nil; composingNew = false; newNumber = ""; draft.text = ""
        conversationLoading = false; selectWhenListed = nil
    }

    private func follow(_ devices: [AppState.DeviceState], focused: String?) {
        let capable = devices.filter { $0.caps.contains("sms") }
        let target = capable.first { $0.id == focused } ?? capable.first
        guard target?.id != deviceID else {
            // Every battery reading republishes the list; only a rename is worth a redraw here.
            if let target, let name = AppState.displayName(target.name), name != phoneName { phoneName = name }
            return
        }
        deviceID = target?.id
        reset()
        guard let target else { phase = .disconnected; return }
        phoneName = AppState.displayName(target.name) ?? ""
        phase = .loading
        request()
    }

    // MARK: navigation

    func select(_ thread: Int64?) {
        guard thread != selection || composingNew else { return }
        selection = thread
        composingNew = false
        newNumber = ""
        draft.text = ""         // a reply typed for one conversation must not go to the next
        messages = []
        conversationLoading = thread != nil
        if let thread { request(thread: thread) }
    }

    func startNew() {
        selection = nil
        messages = []
        conversationLoading = false
        newNumber = ""
        draft.text = ""
        composingNew = true
    }

    var selectedThread: SMS.Thread? { threads.first { $0.id == selection } }

    /// Where Send goes: the open conversation's number, or the one typed for a new message.
    var address: String {
        composingNew ? newNumber.trimmingCharacters(in: .whitespaces) : selectedThread?.address ?? ""
    }

    var canReply: Bool { SMS.isValidAddress(address) }
    var canSend: Bool { phase == .ready && canReply && SMS.sendable(draft.text) != nil }

    /// The phone's messages, then this window's own texts the phone does not list yet.
    var bubbles: [Bubble] {
        let address = address
        let here = outgoing.filter { o in
            o.thread.map { $0 == selection } ?? (!address.isEmpty && SMS.sameNumber(o.to, address))
        }
        let listed = Self.listed(here, in: messages)
        return messages.map(Bubble.message) + here.filter { !listed.contains($0.id) }.map(Bubble.local)
    }

    /// The phone writes a text into its store while sending it, so the same text could show twice:
    /// once as the window's pending bubble and once from the phone. The phone's copy wins unless
    /// this one failed, which is the one that carries Retry.
    ///
    /// Each of the phone's messages stands in for one bubble at most, so "ok" sent twice stays two
    /// bubbles until the phone lists both. Ten minutes either way absorbs a phone clock that is off.
    private static func listed(_ local: [Outgoing], in messages: [SMS.Message]) -> Set<String> {
        var used = Set<Int64>()
        var listed = Set<String>()
        for o in local {
            if case .failed = o.state { continue }
            guard let match = messages.first(where: {
                $0.outgoing && !used.contains($0.id) && $0.body == o.body
                    && abs($0.date.timeIntervalSince(o.date)) <= 600
            }) else { continue }
            used.insert(match.id)
            listed.insert(o.id)
        }
        return listed
    }

    // MARK: sending

    func send() {
        guard canSend, let body = SMS.sendable(draft.text) else { return }
        let to = address
        if composingNew {
            if let known = threads.first(where: { SMS.sameNumber($0.address, to) }) {
                select(known.id)
            } else {
                selectWhenListed = to
            }
        }
        let item = Outgoing(id: SMS.newID(), to: to, body: body, date: Date(), thread: selection, state: .pending)
        outgoing.append(item)
        draft.text = ""
        transmit(item)
    }

    func retry(_ id: String) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        let old = outgoing.remove(at: index)
        let item = Outgoing(id: SMS.newID(), to: old.to, body: old.body, date: Date(), thread: old.thread, state: .pending)
        outgoing.append(item)
        transmit(item)
    }

    private func transmit(_ item: Outgoing) {
        guard let deviceID else { return }
        if DemoMode.isOn { demoSend(item); return }
        Task {
            let sent = await Server.shared.sendSMS(
                ["t": "sms_send", "id": item.id, "to": item.to, "body": item.body], to: deviceID
            )
            if !sent { self.result(SMS.Sent(id: item.id, ok: false, reason: "offline"), from: deviceID) }
        }
    }

    // MARK: from the phone

    func threadsArrived(_ list: SMS.Threads, from device: String) {
        guard isOpen, device == deviceID else { return }
        switch list.state {
        case .off: phase = .off
        case .noPermission: phase = .noPermission
        case .ok: phase = .ready
        }
        var listed = list.threads
        // The open conversation can fall out of the newest 50 the phone lists. Kept at the end, it
        // still has its number, so it can still be replied to. A shorter list means it was deleted.
        if list.state == .ok, listed.count >= SMS.maxThreads, let selection,
           !listed.contains(where: { $0.id == selection }),
           let open = threads.first(where: { $0.id == selection }) {
            listed.append(open)
        }
        threads = listed
        guard phase == .ready, let wanted = selectWhenListed,
              let match = threads.first(where: { SMS.sameNumber($0.address, wanted) }) else { return }
        selectWhenListed = nil
        for index in outgoing.indices where outgoing[index].thread == nil && SMS.sameNumber(outgoing[index].to, wanted) {
            outgoing[index].thread = match.id
        }
        if composingNew && SMS.sameNumber(address, wanted) { select(match.id) }
    }

    func messagesArrived(_ list: SMS.Messages, from device: String) {
        guard isOpen, device == deviceID, list.thread == selection else { return }
        switch list.state {
        case .off: phase = .off; return
        case .noPermission: phase = .noPermission; return
        case .ok: break
        }
        messages = list.messages
        conversationLoading = false
        // Sent texts are in the phone's list now; the pending and failed ones stay.
        let address = selectedThread?.address ?? ""
        outgoing.removeAll { o in
            o.state == .sent && (o.thread == list.thread || SMS.sameNumber(o.to, address))
        }
    }

    func result(_ sent: SMS.Sent, from device: String) {
        guard isOpen, device == deviceID, let index = outgoing.firstIndex(where: { $0.id == sent.id }) else { return }
        if sent.ok {
            outgoing[index].state = .sent
            refresh()
        } else {
            outgoing[index].state = .failed(Self.reason(sent.reason))
        }
    }

    /// Also how the window learns Messages was turned on or off on the phone, so it asks again
    /// from any phase, `off` and `no_permission` included.
    func changed(from device: String) {
        guard isOpen, device == deviceID else { return }
        refresh()
    }

    private func refresh() {
        request()
        if let selection { request(thread: selection) }
    }

    private func request(thread: Int64? = nil) {
        guard let deviceID else { return }
        if DemoMode.isOn { demoAnswer(thread: thread); return }
        Task {
            var msg: [String: Any] = ["t": "sms_request"]
            if let thread { msg["thread"] = thread }
            await Server.shared.sendSMS(msg, to: deviceID)
        }
    }

    static func reason(_ code: String?) -> String {
        switch code {
        case "off": return String(localized: "Messages is off on the phone")
        case "no_permission": return String(localized: "No SMS access on the phone")
        case "invalid": return String(localized: "Invalid number")
        case "no_service": return String(localized: "No service")
        case "offline": return String(localized: "Phone not connected")
        default: return String(localized: "Not sent")
        }
    }

    // MARK: demo

    private func demoAnswer(thread: Int64?) {
        guard let deviceID else { return }
        if let thread {
            messagesArrived(SMS.Messages(thread: thread, state: .ok, messages: DemoMode.smsMessages(thread)), from: deviceID)
        } else {
            threadsArrived(SMS.Threads(state: .ok, threads: DemoMode.smsThreads), from: deviceID)
            if selection == nil, !composingNew, let first = threads.first { select(first.id) }
        }
    }

    /// The demo has no radio: a text to the first conversation stays pending, any other fails, so
    /// both states can be seen.
    private func demoSend(_ item: Outgoing) {
        guard let deviceID, item.thread != DemoMode.smsThreads.first?.id else { return }
        result(SMS.Sent(id: item.id, ok: false, reason: "no_service"), from: deviceID)
    }
}

// MARK: - window

/// The main window's Messages page, two panes like a small Messages.app: conversations on the
/// left, the open one on the right. The texts are held only while the page is on screen.
struct MessagesView: View {

    @ObservedObject private var model = Messages.shared

    var body: some View {
        HSplitView {
            threadList
            detail
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.startNew() } label: {
                    Label("New message", systemImage: "square.and.pencil")
                }
                .help("New message")
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.phase != .ready)
            }
        }
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }

    private var title: String {
        if model.composingNew { return String(localized: "New message") }
        return model.selectedThread?.title ?? String(localized: "Messages")
    }

    private var subtitle: String {
        if let thread = model.selectedThread, thread.name != nil { return thread.address }
        return model.phoneName
    }

    private var threadList: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            ForEach(model.threads) { thread in
                ThreadRow(thread: thread).tag(thread.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.phase == .loading { ProgressView().controlSize(.small) }
        }
        .emptyState(model.phase == .ready && model.threads.isEmpty, symbol: "message",
                    message: String(localized: "No messages"))
        .softScrollEdges()
        .frame(minWidth: 220, idealWidth: 270, maxWidth: 360, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.phase {
        case .disconnected:
            EmptyState(symbol: "iphone.slash", message: String(localized: "Phone not connected"))
        case .loading:
            ProgressView()
        case .off:
            EmptyState(symbol: "message", message: String(localized: "Turn on Messages on your phone"))
        case .noPermission:
            EmptyState(symbol: "lock", message: String(localized: "Allow SMS access on your phone"))
        case .ready:
            if model.selection != nil || model.composingNew {
                ConversationView()
            } else {
                EmptyState(symbol: "bubble.left.and.bubble.right",
                           message: String(localized: "No conversation selected"))
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: SMS.Thread

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.small) {
            Circle()
                .fill(thread.unread > 0 ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.title)
                        .font(Theme.Font.heading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Space.tight)
                    RelativeTime(date: thread.date)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }
                Text(thread.snippet)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Theme.Space.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let time = RelativeTime.string(thread.date)
        return thread.unread > 0
            ? String(localized: "\(thread.title), unread, \(time): \(thread.snippet)")
            : String(localized: "\(thread.title), \(time): \(thread.snippet)")
    }
}

// MARK: - conversation

private struct ConversationView: View {

    @ObservedObject private var model = Messages.shared
    @FocusState private var numberFocused: Bool

    var body: some View {
        let bubbles = model.bubbles
        VStack(spacing: 0) {
            if model.composingNew {
                to
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.Space.tight) {
                        ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
                            if SMS.startsGroup(previous: index > 0 ? bubbles[index - 1].date : nil, current: bubble.date) {
                                Text(Self.stamp(bubble.date))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, Theme.Space.small)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            row(bubble).id(bubble.id)
                        }
                    }
                    .padding(Theme.inset)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: bubbles.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .overlay {
                if model.conversationLoading && bubbles.isEmpty { ProgressView().controlSize(.small) }
            }
            Divider()
            Composer(model: model, draft: model.draft)
        }
        .onAppear { if model.composingNew { numberFocused = true } }
        .onChange(of: model.composingNew) { _, new in if new { numberFocused = true } }
    }

    private var to: some View {
        HStack(spacing: Theme.Space.small) {
            Text("To:").foregroundStyle(.secondary)
            TextField("Phone number", text: $model.newNumber)
                .textFieldStyle(.plain)
                .focused($numberFocused)
                .accessibilityLabel("To")
        }
        .font(Theme.Font.body)
        .padding(.horizontal, Theme.inset)
        .padding(.vertical, Theme.Space.small)
    }

    @ViewBuilder
    private func row(_ bubble: Messages.Bubble) -> some View {
        switch bubble {
        case .message(let m):
            BubbleView(text: m.body, outgoing: m.outgoing, date: m.date, sender: sender,
                       note: m.status == .pending ? String(localized: "Sending…")
                           : m.status == .failed ? String(localized: "Not sent") : nil,
                       failed: m.status == .failed, retry: nil)
        case .local(let o):
            switch o.state {
            case .pending:
                BubbleView(text: o.body, outgoing: true, date: o.date, sender: sender,
                           note: String(localized: "Sending…"), failed: false, retry: nil)
            case .sent:
                BubbleView(text: o.body, outgoing: true, date: o.date, sender: sender,
                           note: nil, failed: false, retry: nil)
            case .failed(let reason):
                BubbleView(text: o.body, outgoing: true, date: o.date, sender: sender,
                           note: reason, failed: true, retry: { model.retry(o.id) })
            }
        }
    }

    private var sender: String { model.selectedThread?.title ?? model.address }

    /// The time alone today, the day and time before.
    static func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

/// The reply field and Send. It watches the draft, which the rest of the conversation does not.
private struct Composer: View {

    @ObservedObject var model: Messages
    @ObservedObject var draft: Messages.Draft
    @State private var composeHeight: CGFloat = ComposeField.minHeight

    @ViewBuilder
    var body: some View {
        if !model.canReply && !model.composingNew {
            Text("Can't reply to this sender")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(Theme.inset)
        } else {
            HStack(alignment: .bottom, spacing: Theme.Space.small) {
                ComposeField(text: $draft.text, height: $composeHeight,
                             placeholder: String(localized: "Text message"),
                             focusKey: "\(model.selection ?? -1)", focusNow: !model.composingNew,
                             submit: model.send)
                    .frame(height: composeHeight)
                    .padding(.horizontal, Theme.Space.small)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.35)))
                Button(action: model.send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .help("Send")
                .accessibilityLabel("Send")
            }
            .padding(Theme.inset)
            .overlay(alignment: .topTrailing) { counter }
        }
    }

    /// Only near the limit, where it helps.
    @ViewBuilder
    private var counter: some View {
        let count = draft.text.utf16.count
        if count > SMS.maxBody - 200 {
            Text(verbatim: "\(count)/\(SMS.maxBody)")
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(count > SMS.maxBody ? Color.red : Color.secondary)
                .padding(.trailing, Theme.inset + 32)
                .padding(.top, Theme.Space.hair)
        }
    }
}

private struct BubbleView: View {
    let text: String
    let outgoing: Bool
    let date: Date
    let sender: String
    let note: String?
    let failed: Bool
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: outgoing ? .trailing : .leading, spacing: Theme.Space.hair) {
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(outgoing ? Color.white : Color.primary)
                .padding(.horizontal, Theme.Space.medium)
                .padding(.vertical, 7)
                .background(outgoing ? Color.accentColor : Color.secondary.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .opacity(note != nil && !failed ? 0.7 : 1)
                .frame(maxWidth: 440, alignment: outgoing ? .trailing : .leading)
                .accessibilityLabel(label)
            if let note {
                HStack(spacing: Theme.Space.tight) {
                    if failed { Image(systemName: "exclamationmark.circle.fill") }
                    Text(note)
                    if let retry { Button("Retry", action: retry).buttonStyle(.link) }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(failed ? Color.red : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    private var label: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return outgoing
            ? String(localized: "You, \(time): \(text)")
            : String(localized: "\(sender), \(time): \(text)")
    }
}

/// The compose field: Return sends, Shift-Return or Option-Return starts a new line. SwiftUI's
/// vertical `TextField` cannot tell those apart, so this is a plain `NSTextView`.
private struct ComposeField: NSViewRepresentable {

    static let minHeight: CGFloat = 30
    static let maxHeight: CGFloat = 120

    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    /// The conversation it belongs to; a new one takes the keyboard focus.
    let focusKey: String
    let focusNow: Bool
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = Coordinator.font
        view.textContainerInset = NSSize(width: 0, height: 7)
        view.setAccessibilityLabel(placeholder)
        view.setAccessibilityPlaceholderValue(placeholder)
        context.coordinator.placeholder.stringValue = placeholder
        context.coordinator.attachPlaceholder(to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
            coordinator.textChanged(view)
        }
        if focusNow, coordinator.focusedKey != focusKey {
            coordinator.focusedKey = focusKey
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.systemFont(ofSize: 13)
        var parent: ComposeField
        var focusedKey: String?
        let placeholder = NSTextField(labelWithString: "")

        init(_ parent: ComposeField) { self.parent = parent }

        func attachPlaceholder(to view: NSTextView) {
            placeholder.font = Self.font
            placeholder.textColor = .placeholderTextColor
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            placeholder.setAccessibilityElement(false)
            view.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                                     constant: view.textContainer?.lineFragmentPadding ?? 5),
                placeholder.topAnchor.constraint(equalTo: view.topAnchor, constant: view.textContainerInset.height),
            ])
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            textChanged(view)
        }

        func textChanged(_ view: NSTextView) {
            placeholder.isHidden = !view.string.isEmpty
            // Grows with the text up to a few lines, then scrolls.
            let padding = view.textContainer?.lineFragmentPadding ?? 5
            let width = max(view.bounds.width - padding * 2, 50)
            var text = view.string
            if text.isEmpty || text.hasSuffix("\n") { text += " " }
            let used = (text as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: Self.font]
            ).height
            let height = min(max(ceil(used) + view.textContainerInset.height * 2, ComposeField.minHeight),
                             ComposeField.maxHeight)
            if height != parent.height {
                let binding = parent.$height
                DispatchQueue.main.async { binding.wrappedValue = height }
            }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), !view.hasMarkedText() else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                view.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.submit()
            }
            return true
        }
    }
}
