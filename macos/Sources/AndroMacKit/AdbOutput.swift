import Foundation

/// What `adb devices` and `adb mdns services` print, parsed. Screen mirroring (the app's
/// `ScreenMirror`) matches these against the address a phone's session came from.
public enum AdbOutput {

    public struct Device: Equatable, Sendable {
        public let serial: String
        public let state: String
    }

    public struct Service: Equatable, Sendable {
        public let name: String
        /// `_adb-tls-connect._tcp` or `_adb-tls-pairing._tcp`.
        public let type: String
        /// `ip:port`.
        public let address: String
        public var host: String { String(address.split(separator: ":").first ?? "") }
    }

    /// A header line, then `serial<TAB>state`. adb's own `* daemon started` chatter is skipped.
    public static func devices(_ output: String) -> [Device] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
            return Device(serial: fields[0], state: fields[1])
        }
    }

    /// A header line, then `instance<TAB>_adb-tls-….tcp<TAB>ip:port`.
    public static func services(_ output: String) -> [Service] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[1].hasPrefix("_adb"), fields[2].contains(":") else { return nil }
            return Service(name: fields[0], type: fields[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                           address: fields[2])
        }
    }

    /// The ready device at this address: `ip:port`, or the mDNS instance name adb uses for a phone
    /// it connected to by itself after pairing.
    public static func ready(_ devices: [Device], at host: String, services: [Service]) -> String? {
        let names = services.filter { $0.host == host }.map(\.name)
        return devices.first { device in
            device.state == "device" && (
                device.serial.hasPrefix("\(host):")
                    || names.contains { !$0.isEmpty && device.serial.hasPrefix($0) }
            )
        }?.serial
    }
}
