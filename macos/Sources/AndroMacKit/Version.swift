import Foundation

/// A version as the release pipeline writes it: `1.0.0`. A `-dev.N` suffix is still parsed and
/// ordered below the plain number (`1.0.1-dev.42 < 1.0.1`), so a build that carried one can
/// update to the release. Mirrors `Version.kt` on Android line for line; both have a unit test.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {

    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The run number of a development build; `nil` for a stable release.
    public let dev: Int?

    public init(_ major: Int, _ minor: Int, _ patch: Int, dev: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.dev = dev
    }

    public var isDev: Bool { dev != nil }

    public var description: String {
        "\(major).\(minor).\(patch)" + (dev.map { "-dev.\($0)" } ?? "")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.dev ?? Int.max)
            < (rhs.major, rhs.minor, rhs.patch, rhs.dev ?? Int.max)
    }

    /// The first version inside any text: a tag (`v1.0.0`), a release title
    /// (`Development build 1.0.1-dev.42`) or the label the apps show (`1.0.0 (12 · abc1234)`).
    public static func find(in text: String) -> AppVersion? {
        let pattern = /(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:-dev\.(\d{1,9}))?/
        guard let m = text.firstMatch(of: pattern),
              let major = Int(m.1), let minor = Int(m.2), let patch = Int(m.3)
        else { return nil }
        return AppVersion(major, minor, patch, dev: m.4.flatMap { Int($0) })
    }
}
