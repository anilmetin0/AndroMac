package dev.andromac.feature

import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import dev.andromac.core.Store
import org.json.JSONObject

/**
 * Mirrors the playing track to the Mac and forwards transport commands from the Mac to the
 * session.
 *
 * [MediaSessionManager] opens up via the notification listener permission — no extra
 * permission, it reuses the [NotificationRelay] access that was already granted. Without it
 * a SecurityException is thrown; the bridge then stays silently disabled.
 *
 * Energy (PROTOCOL §6.10): fully event-driven. `MediaController.Callback` fires only when
 * the track or the playback state changes; sends are coalesced over 300 ms and an identical
 * body is never re-sent. **Playback position is not synced** — that would mean a message per
 * second; the progress bar is deliberately absent for this reason.
 */
class MediaBridge(context: Context, private val store: Store) {

    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(MediaSessionManager::class.java)
    private val component = ComponentName(context, NotificationRelay::class.java)

    // The Context itself is NOT HELD IN A FIELD: [active] is static and that chain triggers
    // a leak warning. All we actually need is package-name resolution.
    private val packages = context.applicationContext.packageManager

    private var controller: MediaController? = null
    private var registered = false
    private var lastSent: String? = null
    private var pending: Runnable? = null
    private var warned = false

    private val sessionsListener =
        MediaSessionManager.OnActiveSessionsChangedListener { onSessions(it.orEmpty()) }

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = schedule()
        override fun onPlaybackStateChanged(state: PlaybackState?) = schedule()
        override fun onSessionDestroyed() {
            controller = null
            schedule()
        }
    }

    /** When the session comes up. Called from the service thread. */
    fun start() {
        handler.post {
            active = this
            lastSent = null
            register()
        }
    }

    /** When the link drops. The listener is released: waking up while disconnected is pointless. */
    fun stop() {
        handler.post {
            if (active === this) active = null
            unregister()
            lastSent = null
        }
    }

    /** A `media_control` from the Mac. Unknown commands are ignored. */
    fun control(cmd: String) {
        handler.post {
            if (!store.syncMedia) return@post
            val transport = controller?.transportControls ?: return@post
            when (cmd) {
                "play" -> transport.play()
                "pause" -> transport.pause()
                "next" -> transport.skipToNext()
                "previous" -> transport.skipToPrevious()
            }
        }
    }

    // ---------------------------------------------------------------- registration

    private fun register() {
        if (registered || !store.syncMedia) return
        val sessions = try {
            // The 2-argument overload uses the calling thread's looper, and we always arrive
            // here via the main handler. The Executor overload is API 30+, minSdk is 29.
            manager.addOnActiveSessionsChangedListener(sessionsListener, component)
            manager.getActiveSessions(component)
        } catch (e: SecurityException) {
            runCatching { manager.removeOnActiveSessionsChangedListener(sessionsListener) }
            if (!warned) {
                warned = true
                Log.i(Link.TAG, "cannot read media sessions, no notification access: ${e.message}")
            }
            return
        }
        registered = true
        onSessions(sessions)
    }

    private fun unregister() {
        if (!registered) return
        registered = false
        runCatching { manager.removeOnActiveSessionsChangedListener(sessionsListener) }
        controller?.let { runCatching { it.unregisterCallback(callback) } }
        controller = null
        pending?.let(handler::removeCallbacks)
        pending = null
    }

    private fun onSessions(sessions: List<MediaController>) {
        controller?.let { runCatching { it.unregisterCallback(callback) } }
        // A playing session wins; otherwise the first one carrying metadata. A single paused
        // session must show up too, so the user can resume it from the Mac.
        controller = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: sessions.firstOrNull { it.metadata != null }
        controller?.registerCallback(callback, handler)
        schedule()
    }

    // ---------------------------------------------------------------- sending

    /** 300 ms coalescing: on a track change, metadata and state fire as separate callbacks. */
    private fun schedule() {
        pending?.let(handler::removeCallbacks)
        val task = Runnable {
            pending = null
            if (store.syncMedia) publish(payload())
        }
        pending = task
        handler.postDelayed(task, COALESCE_MS)
    }

    private fun publish(msg: JSONObject) {
        val json = msg.toString()
        if (json == lastSent) return                 // an identical body is never re-sent
        if (Link.send(msg)) lastSent = json
    }

    private fun payload(): JSONObject {
        val c = controller ?: return Protocol.mediaInactive()
        val state = c.playbackState?.state ?: PlaybackState.STATE_NONE
        if (state == PlaybackState.STATE_NONE ||
            state == PlaybackState.STATE_STOPPED ||
            state == PlaybackState.STATE_ERROR
        ) {
            return Protocol.mediaInactive()
        }
        val meta = c.metadata
        return Protocol.media(
            active = true,
            playing = state == PlaybackState.STATE_PLAYING,
            title = meta.text(
                MediaMetadata.METADATA_KEY_TITLE, MediaMetadata.METADATA_KEY_DISPLAY_TITLE,
            ),
            artist = meta.text(
                MediaMetadata.METADATA_KEY_ARTIST, MediaMetadata.METADATA_KEY_ALBUM_ARTIST,
            ),
            album = meta.text(MediaMetadata.METADATA_KEY_ALBUM),
            app = packages.appLabel(c.packageName),
            pkg = c.packageName,
        )
    }

    /** Returns the first non-empty key; an empty string when none of them is set. */
    private fun MediaMetadata?.text(vararg keys: String): String =
        keys.firstNotNullOfOrNull { this?.getString(it)?.takeIf(String::isNotEmpty) }.orEmpty()

    /** The user turned the "Media" toggle off: tell the Mac there is nothing and stop listening. */
    private fun applySetting() {
        if (store.syncMedia) {
            register()
        } else if (registered) {
            unregister()
            publish(Protocol.mediaInactive())
        }
    }

    companion object {
        private const val COALESCE_MS = 300L

        /** The settings screen has no handle on the link; this is how it finds the live bridge. */
        @Volatile
        private var active: MediaBridge? = null

        fun settingChanged() {
            val bridge = active ?: return
            bridge.handler.post { bridge.applySetting() }
        }
    }
}
