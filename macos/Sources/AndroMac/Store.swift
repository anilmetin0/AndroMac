import AndroMacKit
import CryptoKit
import Foundation
import Security
import ServiceManagement

/// Persistent identity + the single paired phone + the user's toggles.
/// The static private key lives in the Keychain; the settings live in UserDefaults.
/// `@unchecked Sendable`: the only mutable fields are behind `lock`; everything else is UserDefaults
/// and the Keychain, both thread-safe.
final class Store: @unchecked Sendable {

    static let shared = Store()
    private let defaults = UserDefaults.standard
    private let keychainAccount = "static-key"
    private let keychainService = "dev.andromac"

    // MARK: identity

    /// `identity()` is called both from the Server actor and from the MainActor; both were writing
    /// the same fields. A single lock is enough: the call is rare and short.
    private let lock = NSLock()
    private var cachedKey: P256.KeyAgreement.PrivateKey?
    private var deniedFlag = false
    private var cachedDevices: [PairedDevice]?

    /// Keychain access was denied by the user. In that case NO NEW KEY IS GENERATED: generating one
    /// would silently break the existing pairing and the phone would raise a "key has changed" warning.
    var keychainDenied: Bool {
        lock.lock(); defer { lock.unlock() }
        return deniedFlag
    }

    func identity() -> P256.KeyAgreement.PrivateKey {
        lock.lock(); defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        switch keychainRead() {
        case .found(let raw):
            if let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
                deniedFlag = false
                cachedKey = key
                return key
            }
            NSLog("AndroMac: the key in the Keychain is corrupt, generating a new one")

        case .locked:
            // At login the Keychain may not be unlocked yet. We DO NOT CACHE the ephemeral key and
            // we do not call it "denied": the next call retries, and once the Keychain unlocks the
            // real key comes back. Caching it would make the phone say "key has changed".
            NSLog("AndroMac: Keychain locked — ephemeral key for this round, will retry later")
            return Crypto.generateKeyPair()

        case .denied:
            deniedFlag = true
            NSLog("AndroMac: Keychain access denied — the listener will not start")
            // The ephemeral key IS NOT CACHED: the next start() retries and, if the user granted
            // access, the real identity comes back. The Server does not go on the air this round.
            return Crypto.generateKeyPair()

        case .missing:
            break
        }

        let key = Crypto.generateKeyPair()
        keychainWrite(key.rawRepresentation)
        deniedFlag = false
        cachedKey = key
        return key
    }

    var publicKey: Data { Crypto.encodePublic(identity().publicKey) }

    // MARK: writing
    //
    // Every setting goes out through these two. A demo instance (ANDROMAC_DEMO=1) shares this
    // machine's preferences domain with the real app — the screenshots it seeds must not cost the
    // user a pairing or flip a setting behind their back — so in that mode nothing is written at
    // all and the values live only in this process.

    private func write(_ value: Any?, _ key: String) {
        guard !DemoMode.isOn else { return }
        defaults.set(value, forKey: key)
    }

    private func forget(_ key: String) {
        guard !DemoMode.isOn else { return }
        defaults.removeObject(forKey: key)
    }

    // MARK: paired phones

    /// Every trusted phone, keyed by its static public key (see `PairedDevice`).
    ///
    /// Stored as one JSON blob rather than a spray of defaults keys: the list is short, it is always
    /// read and written whole, and a single key makes the migration below a single decision.
    var pairedDevices: [PairedDevice] {
        get {
            lock.lock(); defer { lock.unlock() }
            if let cachedDevices { return cachedDevices }
            // A demo instance never reads the real list either: the screenshots show invented
            // devices, and the machine's own pairings are none of their business.
            let devices = DemoMode.isOn ? [] : loadDevices()
            cachedDevices = devices
            return devices
        }
        set {
            lock.lock()
            cachedDevices = newValue
            write(try? JSONEncoder().encode(newValue), "pairedDevices")
            lock.unlock()
            // Store is not an ObservableObject — it is read from the network actor as well as the
            // UI — so the views that show this list learn about a change through AppState. Without
            // this a per-device switch wrote its new value to disk and then redrew from the old
            // in-memory copy, which looked exactly like a switch that does not move.
            Task { @MainActor in AppState.shared.pairedDevicesChanged += 1 }
        }
    }

    /// Reads the list, migrating the old single-phone keys on first run after the update.
    ///
    /// The v1 layout was one `peerKey` + one `peerName`. Anyone upgrading has a working pairing in
    /// those two defaults, and losing it would mean re-pairing by hand for no reason, so the first
    /// read folds them into a one-element list and removes the old keys. `pairedAt` is unknown for
    /// a migrated device, so it gets `.distantPast` — it sorts oldest, which is true.
    private func loadDevices() -> [PairedDevice] {
        let (devices, migrated) = PairedDevice.load(
            stored: defaults.data(forKey: "pairedDevices"),
            legacyKey: defaults.data(forKey: "peerKey"),
            legacyName: defaults.string(forKey: "peerName") ?? ""
        )
        if migrated {
            write(try? JSONEncoder().encode(devices), "pairedDevices")
            forget("peerKey")
            forget("peerName")
            NSLog("AndroMac: migrated the single paired phone into the device list")
        }
        return devices
    }

    func device(forKey key: Data) -> PairedDevice? {
        pairedDevices.first { $0.key == key }
    }

    func device(id: String) -> PairedDevice? {
        pairedDevices.first { $0.id == id }
    }

    /// Add a newly paired device, or refresh the name of one we already trust.
    func remember(_ device: PairedDevice) {
        var devices = pairedDevices
        if let index = devices.firstIndex(where: { $0.key == device.key }) {
            devices[index].name = device.name
        } else {
            devices.append(device)
        }
        pairedDevices = devices
    }

    /// Apply a change to one device in place. No-op if it is not paired.
    func updateDevice(id: String, _ change: (inout PairedDevice) -> Void) {
        var devices = pairedDevices
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        change(&devices[index])
        pairedDevices = devices
    }

    var isPaired: Bool { !pairedDevices.isEmpty }

    // MARK: single-phone bridge
    //
    // The storage above holds N phones; the Server, the panel and the settings still speak in terms
    // of one. These two properties are that translation, and they are the list of call sites the
    // multi-device work has to visit — when the last one is gone, so are they.
    // Deliberately "the first device", not "the connected one": with a single pairing they are the
    // same thing, and that is the only case that exists until the Server learns to hold several.

    var pairedKey: Data? {
        get { pairedDevices.first?.key }
        set {
            guard let newValue else { unpairAll(); return }
            remember(PairedDevice(key: newValue, name: pairedDevices.first?.name ?? ""))
        }
    }

    var pairedName: String {
        get { pairedDevices.first?.name ?? "" }
        set {
            guard let first = pairedDevices.first else { return }
            updateDevice(id: first.id) { $0.name = newValue }
        }
    }

    func unpair() { unpairAll() }

    /// Forget one phone. The others stay.
    func unpair(id: String) {
        pairedDevices = pairedDevices.filter { $0.id != id }
    }

    func unpairAll() {
        pairedDevices = []
    }

    // MARK: user toggles

    private func flag(_ key: String, default def: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? def
    }

    var syncBattery: Bool {
        get { flag("syncBattery", default: true) }
        set { write(newValue, "syncBattery") }
    }
    var syncClipboard: Bool {
        get { flag("syncClipboard", default: true) }
        set { write(newValue, "syncClipboard") }
    }
    /// Send automatically to the phone whenever something is copied on the Mac. When off, the
    /// clipboard flows only from the phone to the Mac; sending manually from the history still works.
    var clipboardAutoSend: Bool {
        get { flag("clipboardAutoSend", default: true) }
        set { write(newValue, "clipboardAutoSend") }
    }
    /// Never send a clipboard a password manager marked as concealed. The counterpart of the
    /// phone's `clipboardSkipSensitive` (`ClipDescription.EXTRA_IS_SENSITIVE`); PROTOCOL §5 promises
    /// the behaviour on both sides. On by default, and it applies to manual sends too.
    var clipboardSkipSensitive: Bool {
        get { flag("clipboardSkipSensitive", default: true) }
        set { write(newValue, "clipboardSkipSensitive") }
    }

    var syncNotifications: Bool {
        get { flag("syncNotifications", default: true) }
        set { write(newValue, "syncNotifications") }
    }

    var syncMedia: Bool {
        get { flag("syncMedia", default: true) }
        set { write(newValue, "syncMedia") }
    }

    /// Receive files from the phone (PROTOCOL §5 `file_offer`). Off → every offer is rejected
    /// with `disabled` before the user is asked.
    var fileTransfer: Bool {
        get { flag("fileTransfer", default: true) }
        set { write(newValue, "fileTransfer") }
    }

    /// Skip the consent window. Only the pinned phone can reach the offer, so this trusts one
    /// device, not the network.
    var fileAutoAccept: Bool {
        get { flag("fileAutoAccept", default: false) }
        set { write(newValue, "fileAutoAccept") }
    }

    /// Show a notification on the Mac when the phone drops below 15%.
    var lowBatteryAlert: Bool {
        get { flag("lowBatteryAlert", default: true) }
        set { write(newValue, "lowBatteryAlert") }
    }

    /// Launch at login. The system is the single source of truth: had we mirrored it into
    /// UserDefaults, the UI would lie once the user turned it off in System Settings.
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// A method rather than a setter: registration can throw (unsigned copy, quarantine) and that
    /// has to be surfaced to the user. Returns the error, `nil` = success.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Error? {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            NSLog("AndroMac: could not set launch at login — \(error.localizedDescription)")
            return error
        }
    }

    /// Show the battery percentage as text in the menu bar. Off by default: the menu bar is
    /// cramped, so the user turns it on if they want it.
    var showBatteryInMenuBar: Bool {
        get { flag("showBatteryInMenuBar", default: false) }
        set { write(newValue, "showBatteryInMenuBar") }
    }

    /// Ask the phone for its clipboard when the panel opens. Default ON: it is the only way a copy
    /// made on the phone reaches the Mac without the user tapping something there, and the phone
    /// still answers only when it is unlocked and allowed to (see `ClipboardBridge` on Android).
    var clipboardPull: Bool {
        get { flag("clipboardPull", default: true) }
        set { write(newValue, "clipboardPull") }
    }

    // MARK: updates

    /// Default ON. This is the single thing that ever leaves the local network: one request to
    /// api.github.com at launch and when the panel opens, at most once a day (`UpdateCheck.swift`).
    ///
    /// It was opt-in until 1.0. An app distributed outside the App Store has no other way to tell
    /// its user that a fix exists, and a stale build of something that holds a long-lived key on
    /// the local network is the worse trade. One switch in Settings turns it off.
    var updateCheck: Bool {
        get { flag("updateCheck", default: true) }
        set { write(newValue, "updateCheck") }
    }

    /// The release the user chose to skip, so the launch prompt asks once per release, not daily.
    var updateSkipped: String {
        get { defaults.string(forKey: "updateSkipped") ?? "" }
        set { write(newValue, "updateSkipped") }
    }

    var updateLastCheck: Date? {
        get { defaults.object(forKey: "updateLastCheck") as? Date }
        set { write(newValue, "updateLastCheck") }
    }

    /// The newest release the last check found, as (version, commit, page URL), or nil when up to date.
    /// Persisted so the panel can show it after a relaunch without another request.
    var updateFound: (version: String, commit: String?, url: String)? {
        get {
            guard let v = defaults.string(forKey: "updateFoundVersion"),
                  let u = defaults.string(forKey: "updateFoundURL") else { return nil }
            return (v, defaults.string(forKey: "updateFoundCommit"), u)
        }
        set {
            write(newValue?.version, "updateFoundVersion")
            write(newValue?.commit, "updateFoundCommit")
            write(newValue?.url, "updateFoundURL")
        }
    }

    var deviceName: String {
        get { defaults.string(forKey: "deviceName") ?? Host.current().localizedName ?? "Mac" }
        set { write(newValue, "deviceName") }
    }

    // MARK: Keychain

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private enum KeychainResult {
        case found(Data)
        case missing            // never written -> generating a new key is correct
        case locked             // Keychain locked -> ephemeral key, but DO NOT CACHE it
        case denied             // the user refused -> warn persistently
    }

    private func keychainRead() -> KeychainResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)

        switch status {
        case errSecSuccess:
            return (out as? Data).map(KeychainResult.found) ?? .missing
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            // A locked Keychain is temporary; treating it as a permanent refusal would break the pairing.
            return .locked
        default:
            // errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed…
            NSLog("AndroMac: Keychain read error (%d)", Int(status))
            return .denied
        }
    }

    private func keychainWrite(_ data: Data) {
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("AndroMac: Keychain write failed (\(status))")
        }
    }
}
