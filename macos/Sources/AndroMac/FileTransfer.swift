import AndroMacKit
import AppKit
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Both directions of the file transfer (docs/PROTOCOL.md §5 `file_*`, §6.12).
///
/// Everything runs on the main actor: reading, hashing and base64-encoding one 512 KiB chunk
/// takes about a millisecond, and the protocol never has more than one chunk in flight, so the
/// panel stays responsive. Every message goes out through `Server.send`, so the link counters see
/// the file traffic like any other message.
/// ponytail: main-actor disk I/O; move the chunk work to a detached task if the panel ever stutters.
@MainActor
final class FileTransfer: ObservableObject {

    static let shared = FileTransfer()

    struct Progress: Equatable {
        let name: String
        let outgoing: Bool
        let percent: Int
    }

    /// The one row the panel shows; nil when nothing is running. Assigned only when it changes,
    /// so a 4 GB transfer redraws the panel a hundred times, not eight thousand.
    @Published private(set) var progress: Progress?

    private let maxQueue = 50
    private let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    // MARK: entry points (Server)

    func handle(_ type: String, _ msg: [String: Any]) async {
        guard let id = msg["id"] as? String, !id.isEmpty, id.count <= 64 else { return }
        switch type {
        case "file_offer": await offered(id, msg)
        case "file_accept": await accepted(id)
        case "file_reject", "file_result": finished(id, type: type, msg)
        case "file_chunk": await chunk(id, msg)
        case "file_ack": await acked(id, msg)
        case "file_done": await done(id, msg)
        case "file_cancel": cancelled(id)
        default: break
        }
    }

    /// The session dropped: nothing is resumed, temporary files go (§5 step 6).
    func sessionEnded() {
        queue.removeAll()
        finishOutgoing()
        discardIncoming()
    }

    // MARK: entry points (panel)

    /// Files are queued and offered one at a time (§5 step 1). Directories and anything above
    /// 4 GiB are skipped silently.
    func send(urls: [URL]) {
        for url in urls where queue.count < maxQueue {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, Int64(size) <= FileTransferMath.maxFileSize
            else { continue }
            queue.append(url)
        }
        Task { await offerNext() }
    }

    /// The panel's Cancel button: the direction the row shows, outgoing first.
    func cancel() {
        Task {
            if outgoing != nil {
                queue.removeAll()
                await cancelOutgoing(reason: "user")
            } else if incoming != nil {
                await cancelIncoming(reason: "user")
            }
        }
    }

    // MARK: sender

    private final class Outgoing {
        enum Phase { case offered, streaming, done }
        let id: String
        let name: String
        let size: Int64
        let handle: FileHandle
        var hasher = SHA256()
        var phase = Phase.offered
        var nextSeq = 0
        var sent: Int64 = 0

        init(id: String, name: String, size: Int64, handle: FileHandle) {
            self.id = id; self.name = name; self.size = size; self.handle = handle
        }
    }

    private var queue: [URL] = []
    private var outgoing: Outgoing?

    private func offerNext() async {
        guard outgoing == nil, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let handle = try? FileHandle(forReadingFrom: url)
        else { await offerNext(); return }

        let out = Outgoing(id: Self.newID(), name: url.lastPathComponent, size: Int64(size), handle: handle)
        outgoing = out
        refreshProgress()
        var offer: [String: Any] = ["t": "file_offer", "id": out.id, "name": out.name, "size": out.size]
        if let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType { offer["mime"] = mime }
        await Server.shared.send(offer)
    }

    private func accepted(_ id: String) async {
        guard let out = outgoing, out.id == id, out.phase == .offered else { return }
        out.phase = .streaming
        await sendNextChunk()
    }

    private func acked(_ id: String, _ msg: [String: Any]) async {
        guard let out = outgoing, out.id == id, out.phase == .streaming else { return }
        guard msg["seq"] as? Int == out.nextSeq - 1 else {
            await cancelOutgoing(reason: "protocol"); return
        }
        refreshProgress()
        await sendNextChunk()
    }

    /// Window = 1 (§5 step 3): the next chunk leaves only after the previous ack arrived. The hash
    /// is computed while streaming so the file is read once (§6.12).
    private func sendNextChunk() async {
        guard let out = outgoing, out.phase == .streaming else { return }
        if out.sent >= out.size {
            out.phase = .done
            let hash = Self.hex(out.hasher.finalize())
            await Server.shared.send(["t": "file_done", "id": out.id, "sha256": hash])
            return
        }
        let want = Int(min(Int64(FileTransferMath.chunkSize), out.size - out.sent))
        guard let data = try? out.handle.read(upToCount: want), data.count == want else {
            // The file shrank or vanished while we were sending it.
            await cancelOutgoing(reason: "read_error"); return
        }
        out.hasher.update(data: data)
        out.sent += Int64(data.count)
        let seq = out.nextSeq
        out.nextSeq += 1
        await Server.shared.send(["t": "file_chunk", "id": out.id, "seq": seq, "data": data.base64EncodedString()])
    }

    /// `file_reject` or `file_result`: this file is over either way. A rejection also drops the
    /// rest of the queue — the user on the phone said no, asking again for every file would nag.
    private func finished(_ id: String, type: String, _ msg: [String: Any]) {
        guard let out = outgoing, out.id == id else { return }
        if type == "file_reject" || msg["ok"] as? Bool != true {
            NSLog("AndroMac: file not delivered — %@", msg["reason"] as? String ?? type)
            queue.removeAll()
        }
        finishOutgoing()
        Task { await offerNext() }
    }

    private func cancelOutgoing(reason: String) async {
        guard let out = outgoing else { return }
        let id = out.id
        finishOutgoing()
        await Server.shared.send(["t": "file_cancel", "id": id, "reason": reason])
    }

    private func finishOutgoing() {
        try? outgoing?.handle.close()
        outgoing = nil
        refreshProgress()
    }

    // MARK: receiver

    private final class Incoming {
        let id: String
        let name: String            // sanitized
        let size: Int64
        let part: URL
        /// Nil until the user accepted: nothing is written to disk before `file_accept` (§5 step 2).
        var handle: FileHandle?
        var hasher = SHA256()
        var received: Int64 = 0
        var nextSeq = 0

        init(id: String, name: String, size: Int64, part: URL) {
            self.id = id; self.name = name; self.size = size; self.part = part
        }
    }

    private var incoming: Incoming?

    private func offered(_ id: String, _ msg: [String: Any]) async {
        guard let size = (msg["size"] as? NSNumber)?.int64Value, size >= 0 else { return }
        if incoming != nil { await reject(id, "busy"); return }
        guard Store.shared.fileTransfer else { await reject(id, "disabled"); return }
        guard size <= FileTransferMath.maxFileSize else { await reject(id, "too_large"); return }
        guard size <= freeSpace() else { await reject(id, "no_space"); return }

        let name = FileNames.sanitize(msg["name"] as? String ?? "")
        // `.<name>.part` must itself fit in a path component; the final name is the sanitized one.
        let stem = String(decoding: name.utf8.prefix(FileNames.maxBytes - 6), as: UTF8.self)
        let inc = Incoming(id: id, name: name, size: size, part: downloads.appendingPathComponent(".\(stem).part"))
        incoming = inc

        // Auto-accept applies only to the pinned phone — the only device that can reach this code.
        if Store.shared.fileAutoAccept {
            await accept(inc)
        } else {
            FileConsentWindow.show(phone: AppState.displayName(Store.shared.pairedName), name: name, size: size) {
                [weak self] approved in
                Task { await self?.decide(inc, approved: approved) }
            }
        }
    }

    private func decide(_ inc: Incoming, approved: Bool) async {
        guard incoming === inc else { return }         // the session ended while the window was up
        if approved {
            await accept(inc)
        } else {
            incoming = nil
            await reject(inc.id, "declined")
        }
    }

    private func accept(_ inc: Incoming) async {
        guard FileManager.default.createFile(atPath: inc.part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: inc.part)
        else {
            incoming = nil
            await reject(inc.id, "write_error")
            return
        }
        inc.handle = handle
        refreshProgress()
        await Server.shared.send(["t": "file_accept", "id": inc.id])
    }

    private func chunk(_ id: String, _ msg: [String: Any]) async {
        // An id that was not accepted is dropped before anything is decoded or allocated.
        guard let inc = incoming, inc.id == id, let handle = inc.handle else { return }
        guard msg["seq"] as? Int == inc.nextSeq,
              let raw = msg["data"] as? String, raw.utf8.count <= 699_052,     // base64 of 512 KiB
              let data = Data(base64Encoded: raw),
              data.count <= FileTransferMath.chunkSize,
              inc.received + Int64(data.count) <= inc.size
        else { await cancelIncoming(reason: "protocol"); return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            await cancelIncoming(reason: "write_error"); return
        }
        inc.hasher.update(data: data)
        inc.received += Int64(data.count)
        inc.nextSeq += 1
        refreshProgress()
        await Server.shared.send(["t": "file_ack", "id": id, "seq": inc.nextSeq - 1])
    }

    private func done(_ id: String, _ msg: [String: Any]) async {
        guard let inc = incoming, inc.id == id, let handle = inc.handle else { return }
        try? handle.close()
        let claimed = (msg["sha256"] as? String ?? "").lowercased()
        guard inc.received == inc.size, Self.hex(inc.hasher.finalize()) == claimed else {
            discardIncoming()
            await Server.shared.send(["t": "file_result", "id": id, "ok": false, "reason": "hash_mismatch"])
            return
        }
        do {
            let final = try place(inc)
            incoming = nil
            refreshProgress()
            notify(id: id, file: final)
            await Server.shared.send(["t": "file_result", "id": id, "ok": true])
        } catch {
            NSLog("AndroMac: could not place the received file — \(error.localizedDescription)")
            discardIncoming()
            await Server.shared.send(["t": "file_result", "id": id, "ok": false, "reason": "write_error"])
        }
    }

    /// Quarantine first, then the final name: like a browser download, Gatekeeper sees the file
    /// before anything else can. The attribute travels with the rename.
    private func place(_ inc: Incoming) throws -> URL {
        var part = inc.part
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "AndroMac",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
        ]
        try part.setResourceValues(values)
        let fm = FileManager.default
        let name = FileNames.unique(inc.name) { fm.fileExists(atPath: downloads.appendingPathComponent($0).path) }
        let dest = downloads.appendingPathComponent(name)
        try fm.moveItem(at: part, to: dest)
        return dest
    }

    private func cancelled(_ id: String) {
        if let out = outgoing, out.id == id {
            queue.removeAll()
            finishOutgoing()
        }
        if let inc = incoming, inc.id == id { discardIncoming() }
    }

    private func cancelIncoming(reason: String) async {
        guard let inc = incoming else { return }
        let id = inc.id
        discardIncoming()
        await Server.shared.send(["t": "file_cancel", "id": id, "reason": reason])
    }

    private func discardIncoming() {
        FileConsentWindow.close()
        if let inc = incoming, inc.handle != nil {
            try? inc.handle?.close()
            try? FileManager.default.removeItem(at: inc.part)
        }
        incoming = nil
        refreshProgress()
    }

    private func reject(_ id: String, _ reason: String) async {
        await Server.shared.send(["t": "file_reject", "id": id, "reason": reason])
    }

    private func freeSpace() -> Int64 {
        (try? downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// One notification per file; clicking it reveals the file in Finder (NotificationMirror).
    /// The file is never opened automatically.
    private func notify(id: String, file: URL) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "File received")
        content.body = file.lastPathComponent
        content.sound = .default
        content.userInfo = ["file": file.path]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "andromac.file." + id, content: content, trigger: nil)
        ) { error in
            if let error { NSLog("AndroMac: could not present the file notification — \(error.localizedDescription)") }
        }
    }

    // MARK: helpers

    private func refreshProgress() {
        let next: Progress?
        if let out = outgoing {
            next = Progress(name: out.name, outgoing: true, percent: Self.percent(out.sent, of: out.size))
        } else if let inc = incoming, inc.handle != nil {
            next = Progress(name: inc.name, outgoing: false, percent: Self.percent(inc.received, of: inc.size))
        } else {
            next = nil
        }
        if next != progress { progress = next }
    }

    private static func percent(_ done: Int64, of size: Int64) -> Int {
        size == 0 ? 0 : Int(done * 100 / size)
    }

    private static func newID() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - consent window

/// "Accept this file?" — the same shape as PairingWindow: a floating window without a close
/// button, the two buttons are the only way out, so the transfer state never dangles.
@MainActor
enum FileConsentWindow {

    private static var window: NSWindow?

    static func show(phone: String?, name: String, size: Int64,
                     decide: @MainActor @escaping (Bool) -> Void) {
        close()
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "AndroMac"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: FileConsentView(phone: phone, name: name, size: size) { approved in
                close()
                decide(approved)
            }
        )
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct FileConsentView: View {

    let phone: String?
    let name: String
    let size: Int64
    let decide: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Incoming file")
                .font(Theme.Font.title)

            if let phone {
                Text("\(phone) wants to send you a file")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Theme.Font.body.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))

            Text("It is saved to your Downloads folder and never opened automatically.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Decline") { decide(false) }
                Button("Accept") { decide(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
