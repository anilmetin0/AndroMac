import AndroMacKit
import CryptoKit
import Foundation
import Network

/// A responder (role B) that runs the real `Session.accept` code without a GUI.
/// The `:vectors handshake` client on the Kotlin side connects to it — so the SEQUENCE of the
/// handshake, not just the crypto vectors, is verified against the real code.
private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var _round = 0
    private var _pinned: [Data] = []

    func nextRound() -> Int { lock.lock(); defer { lock.unlock() }; _round += 1; return _round }
    var pinned: [Data] {
        get { lock.lock(); defer { lock.unlock() }; return _pinned }
        set { lock.lock(); _pinned = newValue; lock.unlock() }
    }
}

/// How many data frames to pass in each direction. Must be >1 to exercise the counter logic.
let messageCount = 12

func runHandshakeResponder(port: UInt16, timeout: TimeInterval = 30) {
    let queue = DispatchQueue(label: "dev.andromac.selftest")
    let staticKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    let state = State()
    let done = DispatchSemaphore(value: 0)

    guard let nwPort = NWEndpoint.Port(rawValue: port),
          let listener = try? NWListener(using: .tcp, on: nwPort) else {
        print("error=could not open listener")
        return
    }

    listener.newConnectionHandler = { conn in
        Task {
            let round = state.nextRound()
            do {
                let session = try await Session.accept(
                    connection: conn, queue: queue, staticKey: staticKey,
                    peerName: "SelfTest", pinnedKeys: state.pinned
                )
                print("round\(round)=connected sas=\(session.sas)")
                try await session.send([
                    "t": "hello", "name": "SelfTestMac", "platform": "macos", "proto": 3,
                ])

                // Counter progression: a SINGLE message never pushes the nonce past 1. A counter
                // desynchronisation blows up silently on the Nth message, not on the first —
                // which is why we pass more than one frame in both directions.
                for i in 1...messageCount {
                    try await session.send(["t": "ping", "seq": i])
                }
                var received: [Int] = []
                for _ in 1...messageCount {
                    let msg = try await session.receive()
                    received.append(msg["seq"] as? Int ?? -1)
                }
                print("round\(round)_seq=\(received.map(String.init).joined(separator: ","))")

                let last = try await session.receive()
                let type = last["t"] as? String ?? "?"
                print("round\(round)_recv=\(type) text=\(last["text"] as? String ?? "")")
                await session.close()
                done.signal()
            } catch let WireError.untrusted(key, _, sas, isFirstDevice) {
                print("round\(round)=untrusted sas=\(sas) first=\(isFirstDevice)")
                print("round\(round)_peerkey=\(key.map { String(format: "%02x", $0) }.joined())")
                state.pinned.append(key)    // simulate the user's approval
            } catch {
                // Expected on the wrong-pin round (the phone hangs up before message 3); the
                // test ends on the connected round or on the timeout.
                print("round\(round)=error \(error.localizedDescription)")
            }
        }
    }

    listener.start(queue: queue)
    print("listening=\(port)")
    if done.wait(timeout: .now() + timeout) == .timedOut { print("error=timed out") }
    listener.cancel()
}
