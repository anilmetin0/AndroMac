// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AndroMac",
    platforms: [.macOS(.v14)],
    targets: [
        // No dependencies: Network.framework, CryptoKit, AppKit and UserNotifications are enough.
        // Crypto lives in its own target because both the app and the self-test binary use it.
        .target(name: "AndroMacKit", path: "Sources/AndroMacKit"),
        .executableTarget(name: "AndroMac", dependencies: ["AndroMacKit"], path: "Sources/AndroMac"),
        .executableTarget(name: "andromac-selftest", dependencies: ["AndroMacKit"], path: "Sources/SelfTest"),
        // `swift test`: the Android-free logic that has no vector to compare against.
        .testTarget(name: "AndroMacKitTests", dependencies: ["AndroMacKit"], path: "Tests/AndroMacKitTests"),
    ],
    swiftLanguageModes: [.v6]
)
