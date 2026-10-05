import AndroMacKit
import SwiftUI

/// The same phone actions in history and the expanded menu bar card.
struct NotificationActions: View {
    let entry: NotificationHistory.Entry
    @ObservedObject private var history = NotificationHistory.shared
    @ObservedObject private var state = AppState.shared
    @State private var replying: NotificationAction?
    @State private var reply = ""
    @State private var sending = false
    @State private var sentIndex: Int?
    @State private var failed = false
    @FocusState private var replyFocused: Bool

    static func height(_ entry: NotificationHistory.Entry) -> CGFloat {
        CGFloat(entry.buttons.count) * 28
    }

    private var available: Bool {
        guard let peer = entry.peer else { return false }
        return history.activeIDs.contains(entry.id) && state.devices.contains { $0.id == peer }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entry.buttons, id: \.index) { action in
                Button {
                    if action.reply {
                        reply = ""
                        replying = action
                    } else {
                        send(action)
                    }
                } label: {
                    HStack(spacing: Theme.Space.tight) {
                        if sentIndex == action.index { Image(systemName: "checkmark") }
                        Text(verbatim: action.title).lineLimit(1)
                        if action.reply { Image(systemName: "arrowshape.turn.up.left") }
                    }
                }
                .buttonBorderShape(.capsule)
                .secondaryAction()
                .controlSize(.small)
                .disabled(!available || sending)
                .help(available ? action.title : String(localized: "This notification is no longer available on the connected phone."))
                .popover(isPresented: Binding(
                    get: { replying?.index == action.index },
                    set: { if !$0 { replying = nil } }
                )) {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        Text(verbatim: action.title).font(Theme.Font.heading)
                        TextField("Reply", text: $reply, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                            .focused($replyFocused)
                        HStack {
                            Button("Cancel") { replying = nil }
                            Spacer()
                            Button("Send") { send(action, text: reply) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!available || sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(Theme.Space.medium)
                    .frame(width: 280)
                    .onAppear { replyFocused = true }
                }
            }
        }
        .font(Theme.Font.label)
        .frame(height: Self.height(entry), alignment: .topLeading)
        .alert("Could not send the action. Reconnect your phone and try again.", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func send(_ action: NotificationAction, text: String? = nil) {
        guard available, !sending, let peer = entry.peer else { return }
        sending = true
        Task {
            var message: [String: Any] = ["t": "notification_action", "id": entry.phoneID, "action": action.index]
            if let text { message["reply"] = text }
            let sent = await Server.shared.send(message, to: peer)
            sending = false
            if sent {
                replying = nil
                sentIndex = action.index
                try? await Task.sleep(for: .milliseconds(1200))
                sentIndex = nil
            } else {
                failed = true
            }
        }
    }
}
