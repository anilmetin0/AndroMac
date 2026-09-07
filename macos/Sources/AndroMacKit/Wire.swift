import Foundation
import Network

/// Guarantees that a continuation is resumed exactly once.
/// NWConnection state callbacks can fire more than once; a second `resume` is a crash.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Length-prefixed framing over NWConnection (docs/PROTOCOL.md §4).
/// Wraps the callback-based API in async so the handshake can be written sequentially.
public actor Wire {

    public static let maxFrame = 1 << 20      // 1 MiB

    private let conn: NWConnection
    private var closed = false

    public init(_ conn: NWConnection) { self.conn = conn }

    public func start(on queue: DispatchQueue) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { c.resume() }
                case .failed(let e):
                    if once.fire() { c.resume(throwing: e) }
                case .cancelled:
                    if once.fire() { c.resume(throwing: WireError.closed) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Reads exactly [count] bytes. Errors if fewer arrive.
    public func receive(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error { c.resume(throwing: error); return }
                guard let data, data.count == count else {
                    c.resume(throwing: isComplete ? WireError.closed : WireError.protocolError("short read"))
                    return
                }
                c.resume(returning: data)
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    public func readFrame() async throws -> Data {
        let header = try await receive(exactly: 4)
        let n = header.reduce(Int(0)) { ($0 << 8) | Int($1) }
        guard n > 0, n <= Self.maxFrame else {
            throw WireError.protocolError("invalid frame length: \(n)")
        }
        return try await receive(exactly: n)
    }

    public func writeFrame(_ payload: Data) async throws {
        var out = Data(capacity: payload.count + 4)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) })
        out.append(payload)
        try await send(out)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        conn.stateUpdateHandler = nil
        conn.cancel()
    }
}
