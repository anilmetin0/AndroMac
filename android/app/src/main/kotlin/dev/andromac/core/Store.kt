package dev.andromac.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import dev.andromac.feature.UpdateCheck
import java.security.KeyStore
import java.security.PrivateKey
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Persistent identity, the single paired peer, and the user toggles.
 *
 * The static private key is NEVER stored in the clear on disk: the PKCS#8 blob is wrapped
 * with an AES-256-GCM key held in the AndroidKeyStore and saved as `iv || ciphertext`. The
 * wrapping key is non-exportable; someone who reads the prefs file on a rooted device or
 * out of an adb backup cannot recover the private key.
 *
 * LIMITS: during ECDH the key sits in process memory in the clear (the P-256 key itself is
 * not kept in the Keystore — `PURPOSE_AGREE_KEY` is API 31+, minSdk is 29). User
 * authentication is not required: the link must come up even while the screen is locked.
 */
class Store(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("andromac", Context.MODE_PRIVATE)

    // --- persistent identity ---

    private fun b64(v: ByteArray) = Base64.encodeToString(v, Base64.NO_WRAP)
    private fun unb64(v: String) = Base64.decode(v, Base64.NO_WRAP)

    fun identity(): Pair<PrivateKey, ByteArray> = synchronized(LOCK) {
        val pub = prefs.getString(K_PUB, null)
        val wrapped = prefs.getString(K_PRIV_WRAPPED, null)
        val legacy = prefs.getString(K_PRIV, null)

        if (pub != null && wrapped != null) {
            unwrap(unb64(wrapped))?.let { return Crypto.decodePrivate(it) to unb64(pub) }
            // The wrapping key is gone or invalid (fingerprint reset, device restored):
            // the private key is unrecoverable. Silently switching to a new identity would
            // break the pairing too, so we clear the pairing here — the user re-pairs.
            Log.w(Link.TAG, "static key could not be unwrapped, regenerating identity")
            unpair()
        } else if (pub != null && legacy != null) {
            // Migration: the plaintext record is wrapped and then deleted.
            val bytes = unb64(legacy)
            wrap(bytes)?.let {
                prefs.edit().putString(K_PRIV_WRAPPED, b64(it)).remove(K_PRIV).apply()
            }
            return Crypto.decodePrivate(bytes) to unb64(pub)
        }

        val kp = Crypto.generateKeyPair()
        val pubBytes = Crypto.encodePublic(kp.public)
        val privBytes = Crypto.encodePrivate(kp.private)
        val edit = prefs.edit().putString(K_PUB, b64(pubBytes))
        val sealed = wrap(privBytes)
        // Some devices have a broken Keystore; there we fall back to plaintext rather than lose the identity.
        if (sealed != null) edit.putString(K_PRIV_WRAPPED, b64(sealed)).remove(K_PRIV)
        else edit.putString(K_PRIV, b64(privBytes)).remove(K_PRIV_WRAPPED)
        edit.apply()
        kp.private to pubBytes
    }

    /** The wrapping key in the AndroidKeyStore; generated if absent. Non-exportable. */
    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getEntry(WRAP_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        gen.init(
            KeyGenParameterSpec.Builder(
                WRAP_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun wrap(plain: ByteArray): ByteArray? = try {
        val c = Cipher.getInstance(WRAP_TRANSFORM)
        c.init(Cipher.ENCRYPT_MODE, wrapKey())
        c.iv + c.doFinal(plain)
    } catch (e: Exception) {
        if (!warnedWrap) {
            warnedWrap = true
            Log.w(Link.TAG, "no Keystore wrapping available, storing the key in the clear", e)
        }
        null
    }

    private fun unwrap(blob: ByteArray): ByteArray? = try {
        require(blob.size > IV_LEN)
        val c = Cipher.getInstance(WRAP_TRANSFORM)
        c.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, blob, 0, IV_LEN))
        c.doFinal(blob, IV_LEN, blob.size - IV_LEN)
    } catch (e: Exception) {
        Log.w(Link.TAG, "could not unwrap the stored key: ${e.message}")
        null
    }

    // --- paired Mac ---

    var pairedKey: ByteArray?
        get() = prefs.getString(K_PEER_KEY, null)?.let(::unb64)
        set(v) = prefs.edit().apply {
            if (v == null) remove(K_PEER_KEY) else putString(K_PEER_KEY, b64(v))
        }.apply()

    var pairedName: String
        get() = prefs.getString(K_PEER_NAME, "") ?: ""
        set(v) = prefs.edit().putString(K_PEER_NAME, v).apply()

    /** Last address that worked — tried before the mDNS scan (PROTOCOL §1). */
    var lastEndpoint: String?
        get() = prefs.getString(K_ENDPOINT, null)
        set(v) = prefs.edit().apply {
            if (v == null) remove(K_ENDPOINT) else putString(K_ENDPOINT, v)
        }.apply()

    fun unpair() {
        prefs.edit().remove(K_PEER_KEY).remove(K_PEER_NAME).remove(K_ENDPOINT).apply()
    }

    val isPaired: Boolean get() = pairedKey != null

    // --- user toggles ---

    var syncBattery: Boolean
        get() = prefs.getBoolean(K_SYNC_BATTERY, true)
        set(v) = prefs.edit().putBoolean(K_SYNC_BATTERY, v).apply()

    var syncClipboard: Boolean
        get() = prefs.getBoolean(K_SYNC_CLIPBOARD, true)
        set(v) = prefs.edit().putBoolean(K_SYNC_CLIPBOARD, v).apply()

    /** Report the playing track to the Mac and accept transport commands from it. Requires notification access. */
    var syncMedia: Boolean
        get() = prefs.getBoolean(K_SYNC_MEDIA, true)
        set(v) = prefs.edit().putBoolean(K_SYNC_MEDIA, v).apply()

    // --- clipboard details ---

    /** Write text arriving from the Mac into the clipboard automatically. When off, only a notification is posted. */
    var clipboardAutoPaste: Boolean
        get() = prefs.getBoolean(K_CLIP_AUTO, true)
        set(v) = prefs.edit().putBoolean(K_CLIP_AUTO, v).apply()

    /** Show a notification when the Mac's clipboard arrives. If auto-paste is blocked, this is the only route left. */
    var clipboardNotify: Boolean
        get() = prefs.getBoolean(K_CLIP_NOTIFY, true)
        set(v) = prefs.edit().putBoolean(K_CLIP_NOTIFY, v).apply()

    /**
     * Never send clipboard content flagged as sensitive. Password managers and OTP fields
     * set `ClipDescription.EXTRA_IS_SENSITIVE` when copying (API 33+). Default ON: putting
     * a password on the wire, even a local network, is not something the user asked for.
     */
    var clipboardSkipSensitive: Boolean
        get() = prefs.getBoolean(K_CLIP_SENSITIVE, true)
        set(v) = prefs.edit().putBoolean(K_CLIP_SENSITIVE, v).apply()

    var syncNotifications: Boolean
        get() = prefs.getBoolean(K_SYNC_NOTIF, true)
        set(v) = prefs.edit().putBoolean(K_SYNC_NOTIF, v).apply()

    // --- notification app filter ---
    //
    // THREE tiers per app. The default is FULL (block-list model): the user must not
    // silently lose notifications from an app they just installed.
    //   OFF        : send nothing. The filter runs at the source, so the radio never wakes.
    //   TITLE_ONLY : "New notification from X" is sent; title/text/actions are NOT.
    //                For apps whose content is sensitive: banking, health, messaging.
    //   FULL       : everything is sent.

    fun modeFor(pkg: String): Int = appModes[pkg] ?: MODE_FULL

    val appModes: Map<String, Int>
        get() = modeCache ?: synchronized(LOCK) {
            modeCache ?: decode(prefs.getStringSet(K_MODES, null) ?: migrateFromBlockList())
                .also { modeCache = it }
        }

    fun setMode(pkg: String, mode: Int) = synchronized(LOCK) {
        val updated = appModes.toMutableMap().apply {
            if (mode == MODE_FULL) remove(pkg) else put(pkg, mode)   // do not store the default
        }
        prefs.edit().putStringSet(K_MODES, updated.map { "${it.key}$SEP${it.value}" }.toSet()).apply()
        modeCache = updated.toMap()
    }

    private fun decode(raw: Set<String>): Map<String, Int> = raw.mapNotNull { entry ->
        val (pkg, value) = splitEntry(entry) ?: return@mapNotNull null
        val mode = value.toIntOrNull() ?: return@mapNotNull null
        if (mode in MODE_OFF..MODE_FULL) pkg to mode else null
    }.toMap()

    /** Migrates the binary block list from older versions to the three-tier model. */
    private fun migrateFromBlockList(): Set<String> {
        val legacy = prefs.getStringSet(K_BLOCKED, emptySet()).orEmpty()
        val migrated = legacy.map { "$it$SEP$MODE_OFF" }.toSet()
        prefs.edit().putStringSet(K_MODES, migrated).remove(K_BLOCKED).apply()
        return migrated
    }

    /** Apps that have sent a notification (package -> display label). The filter screen lists these. */
    val seenApps: Map<String, String>
        get() = (prefs.getStringSet(K_SEEN, emptySet()) ?: emptySet())
            .mapNotNull(::splitEntry)
            .toMap()

    fun recordApp(pkg: String, label: String): Unit = synchronized(LOCK) {
        val current = prefs.getStringSet(K_SEEN, emptySet()) ?: emptySet()
        val entry = "$pkg$SEP$label"
        if (current.contains(entry)) return
        val updated = current.filterNot { splitEntry(it)?.first == pkg }.toMutableSet()
        updated += entry
        prefs.edit().putStringSet(K_SEEN, updated).apply()
    }

    fun forgetApps() = synchronized(LOCK) {
        prefs.edit().remove(K_SEEN).remove(K_MODES).apply()
        modeCache = null
    }

    /**
     * Send only while the phone is locked. Seeing the same notification again on the Mac
     * while looking at the phone is pointless; when off, everything is always sent.
     * Default OFF.
     */
    var onlyWhenLocked: Boolean
        get() = prefs.getBoolean(K_ONLY_LOCKED, false)
        set(v) = prefs.edit().putBoolean(K_ONLY_LOCKED, v).apply()

    /**
     * Also send silent notifications (IMPORTANCE_LOW and below). Default OFF: they raise
     * no sound or banner on the phone either, so surfacing them on the Mac is mostly noise.
     */
    var syncSilentNotifications: Boolean
        get() = prefs.getBoolean(K_SYNC_SILENT, false)
        set(v) = prefs.edit().putBoolean(K_SYNC_SILENT, v).apply()

    /**
     * The alarm-stream level "find my phone" saved before raising it, or -1 when nothing is
     * outstanding. Persisted rather than kept in memory: a process death during the 30 s alarm
     * would otherwise leave the user's alarm stream pinned at maximum with no way back.
     */
    var savedAlarmVolume: Int
        get() = prefs.getInt(K_ALARM_VOLUME, -1)
        set(v) = prefs.edit().apply {
            if (v < 0) remove(K_ALARM_VOLUME) else putInt(K_ALARM_VOLUME, v)
        }.apply()

    // --- connection ---

    /**
     * Reconnect on its own whenever the Mac is reachable. Default ON. Off, the link waits for
     * "Connect now": the phone-side twin of the Mac's Disconnect.
     */
    var autoConnect: Boolean
        get() = prefs.getBoolean(K_AUTO_CONNECT, true)
        set(v) = prefs.edit().putBoolean(K_AUTO_CONNECT, v).apply()

    // --- file transfer ---

    /** Accept `file_offer` from the Mac and show the share-sheet target. Default ON. */
    var fileTransfer: Boolean
        get() = prefs.getBoolean(K_FILE_TRANSFER, true)
        set(v) = prefs.edit().putBoolean(K_FILE_TRANSFER, v).apply()

    /**
     * Skip the Accept/Decline notification. Default OFF. Only the pinned Mac can reach the
     * session at all (PROTOCOL §3), so this is a convenience toggle, not a security boundary.
     */
    var fileAutoAccept: Boolean
        get() = prefs.getBoolean(K_FILE_AUTO_ACCEPT, false)
        set(v) = prefs.edit().putBoolean(K_FILE_AUTO_ACCEPT, v).apply()

    // --- updates ---

    /**
     * Default ON. This is the single thing that ever leaves the local network: one request to
     * api.github.com when the app is opened, at most once a day (feature/UpdateCheck.kt).
     *
     * It was opt-in until 1.0. An app distributed as an APK outside any store has no other way to
     * tell its user that a fix exists, and a stale build of something holding a long-lived key on
     * the local network is the worse trade. It is one switch away, in Updates.
     */
    var updateCheck: Boolean
        get() = prefs.getBoolean(K_UPDATE_CHECK, true)
        set(v) = prefs.edit().putBoolean(K_UPDATE_CHECK, v).apply()

    /** The release the user chose to skip, so the launch prompt asks once per release, not daily. */
    var updateSkipped: String
        get() = prefs.getString(K_UPDATE_SKIPPED, "") ?: ""
        set(v) = prefs.edit().putString(K_UPDATE_SKIPPED, v).apply()

    /** Epoch millis of the last completed check, 0 = never. */
    var updateLastCheck: Long
        get() = prefs.getLong(K_UPDATE_LAST, 0L)
        set(v) = prefs.edit().putLong(K_UPDATE_LAST, v).apply()

    /**
     * The release the last check found, or null when up to date. Persisted with its commit so the
     * main screen can re-apply [UpdateCheck.isNewer] after a restart without another request.
     */
    var updateFound: UpdateCheck.Release?
        get() {
            val v = prefs.getString(K_UPDATE_FOUND_VERSION, null)?.let(Version::find) ?: return null
            val u = prefs.getString(K_UPDATE_FOUND_URL, null) ?: return null
            return UpdateCheck.Release(v, prefs.getString(K_UPDATE_FOUND_COMMIT, null), u)
        }
        set(r) = prefs.edit().apply {
            if (r == null) remove(K_UPDATE_FOUND_VERSION).remove(K_UPDATE_FOUND_COMMIT).remove(K_UPDATE_FOUND_URL)
            else putString(K_UPDATE_FOUND_VERSION, r.version.toString())
                .putString(K_UPDATE_FOUND_COMMIT, r.commit)
                .putString(K_UPDATE_FOUND_URL, r.url)
        }.apply()

    // --- permissions ---

    /** Which missing permissions the user dismissed the banner for, so it stays gone for those. */
    var permissionsDismissed: String
        get() = prefs.getString(K_PERM_DISMISSED, "") ?: ""
        set(v) = prefs.edit().putString(K_PERM_DISMISSED, v).apply()

    /** Notification access has no runtime dialog, so the app offers the settings screen once. */
    var notificationAccessOffered: Boolean
        get() = prefs.getBoolean(K_PERM_OFFERED, false)
        set(v) = prefs.edit().putBoolean(K_PERM_OFFERED, v).apply()

    var deviceName: String
        get() = prefs.getString(K_NAME, null) ?: android.os.Build.MODEL
        set(v) = prefs.edit().putString(K_NAME, v).apply()

    companion object {
        /**
         * Read-modify-write sections serialize on this. A per-instance lock is NOT enough:
         * LinkService, NotificationRelay, AppsActivity and ShareActivity each construct their
         * own [Store] object, yet all of them write the same prefs file; separate locks were
         * losing records on concurrent setMode/recordApp calls.
         *
         * Deliberate simplification: a single global lock. Writes are rare and take
         * microseconds; if it ever becomes a bottleneck it can be split into per-key locks.
         */
        private val LOCK = Any()

        /**
         * The decoded [K_MODES] map, shared by every [Store] in the process — the components
         * all live in one process and write the same file, so a per-instance cache would go
         * stale the moment another screen changed a mode. The relay asks for it on every
         * notification and used to pay a full string-set decode each time. Written under
         * [LOCK]; [setMode] and [forgetApps] replace or drop it.
         */
        @Volatile
        private var modeCache: Map<String, Int>? = null

        const val MODE_OFF = 0
        const val MODE_TITLE_ONLY = 1
        const val MODE_FULL = 2

        /** Legacy plaintext record. Read only for migration, never written. */
        const val K_PRIV = "static_priv"
        const val K_PRIV_WRAPPED = "static_priv_wrapped"
        const val K_PUB = "static_pub"
        const val K_PEER_KEY = "peer_key"
        const val K_PEER_NAME = "peer_name"
        const val K_ENDPOINT = "last_endpoint"
        const val K_SYNC_BATTERY = "sync_battery"
        const val K_SYNC_CLIPBOARD = "sync_clipboard"
        const val K_SYNC_MEDIA = "sync_media"
        const val K_SYNC_NOTIF = "sync_notifications"
        const val K_NAME = "device_name"
        const val K_BLOCKED = "blocked_apps"
        const val K_SEEN = "seen_apps"
        const val K_SYNC_SILENT = "sync_silent"
        const val K_MODES = "app_modes"
        const val K_ONLY_LOCKED = "only_when_locked"
        const val K_CLIP_AUTO = "clip_auto_paste"
        const val K_CLIP_NOTIFY = "clip_notify"
        const val K_CLIP_SENSITIVE = "clip_skip_sensitive"
        const val K_ALARM_VOLUME = "find_alarm_volume"
        const val K_UPDATE_CHECK = "update_check"
        const val K_UPDATE_LAST = "update_last_check"
        const val K_UPDATE_FOUND_VERSION = "update_found_version"
        const val K_UPDATE_FOUND_COMMIT = "update_found_commit"
        const val K_UPDATE_FOUND_URL = "update_found_url"
        const val K_UPDATE_SKIPPED = "update_skipped"
        const val K_PERM_DISMISSED = "permissions_dismissed"
        const val K_PERM_OFFERED = "notification_access_offered"
        const val K_AUTO_CONNECT = "auto_connect"
        const val K_FILE_TRANSFER = "file_transfer"
        const val K_FILE_AUTO_ACCEPT = "file_auto_accept"

        // --- static key wrapping ---
        private const val KEYSTORE = "AndroidKeyStore"
        private const val WRAP_ALIAS = "andromac-wrap"
        private const val WRAP_TRANSFORM = "AES/GCM/NoPadding"
        private const val IV_LEN = 12

        /** Avoid logging on every single call when the Keystore is broken. */
        @Volatile
        private var warnedWrap = false
        /**
         * Record separator. `\u0001` is NOT used: SharedPreferences is serialized to XML and
         * XML 1.0 does not permit control characters (Android writes `&#1;` and can read it
         * back itself, but that is invalid XML — backups and external tools break on it).
         * '|' is safe because a package name may only contain [a-zA-Z0-9_.] and we split on
         * the first occurrence.
         */
        const val SEP = '|'

        /** Keeps records written with the legacy `\u0001` separator readable. */
        private const val LEGACY_SEP = '\u0001'

        /** Splits a record into (key, value); cuts at the first separator. */
        fun splitEntry(entry: String): Pair<String, String>? {
            var index = entry.indexOf(SEP)
            if (index < 0) index = entry.indexOf(LEGACY_SEP)
            return if (index <= 0) null else entry.substring(0, index) to entry.substring(index + 1)
        }
    }
}
