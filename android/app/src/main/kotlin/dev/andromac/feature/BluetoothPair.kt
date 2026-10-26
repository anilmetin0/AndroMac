package dev.andromac.feature

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import dev.andromac.ui.BluetoothPairActivity

/**
 * `bt_pair` from the Mac: bond with the Mac over Bluetooth so it can act as a hands-free device.
 *
 * Android does not reveal its own Bluetooth address to apps, so the phone dials the Mac and not
 * the other way round. The Mac's address arrives over the encrypted link; Android then shows its
 * own pairing dialog, and the user confirms the same code on both screens. No scan is started.
 */
object BluetoothPair {

    private val handler = Handler(Looper.getMainLooper())
    private val mac = Regex("^([0-9A-F]{2}:){5}[0-9A-F]{2}$")
    private var receiver: BroadcastReceiver? = null
    private var timeout: Runnable? = null

    fun granted(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 31 ||
            ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    /** Called from LinkService's read thread. */
    fun request(ctx: Context, address: String) {
        val app = ctx.applicationContext
        val addr = address.uppercase()
        if (!mac.matches(addr)) return
        handler.post {
            if (granted(app)) bond(app, addr) else askPermission(app, addr)
        }
    }

    /** Main thread only. */
    @SuppressLint("MissingPermission")
    fun bond(ctx: Context, addr: String) {
        val app = ctx.applicationContext
        app.getSystemService(NotificationManager::class.java).cancel(NOTIF_ID)
        if (!granted(app)) { report(STATE_PERMISSION); return }
        val adapter = app.getSystemService(BluetoothManager::class.java)?.adapter
        if (adapter == null || !adapter.isEnabled) { report(STATE_BLUETOOTH_OFF); return }
        val name = runCatching { adapter.name }.getOrNull().orEmpty()
        val device = adapter.getRemoteDevice(addr)
        if (device.bondState == BluetoothDevice.BOND_BONDED) { report(STATE_BONDED, name); return }

        stopWatching(app)
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                @Suppress("DEPRECATION")    // the typed overload is API 33; minSdk is 29
                val d: BluetoothDevice? = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                if (d?.address != addr) return
                when (i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)) {
                    BluetoothDevice.BOND_BONDED -> { stopWatching(app); report(STATE_BONDED, name) }
                    BluetoothDevice.BOND_NONE -> { stopWatching(app); report(STATE_FAILED) }
                }
            }
        }
        val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        else app.registerReceiver(r, filter)
        receiver = r
        // One delayed callback, not a timer: the user may simply walk away from the dialog.
        val t = Runnable { if (stopWatching(app)) report(STATE_FAILED) }
        timeout = t
        handler.postDelayed(t, TIMEOUT_MS)
        // An address the phone never scanned has no known type, and Android bonds it over Classic
        // Bluetooth, which is what hands-free calling uses.
        val started = runCatching { device.createBond() }.getOrDefault(false)
        if (!started) { stopWatching(app); report(STATE_FAILED) }
    }

    /** Returns whether a pairing was still being watched. */
    private fun stopWatching(ctx: Context): Boolean {
        timeout?.let(handler::removeCallbacks)
        timeout = null
        val r = receiver ?: return false
        receiver = null
        runCatching { ctx.unregisterReceiver(r) }
        return true
    }

    private fun report(state: String, name: String = "") {
        Link.send(Protocol.btPairResult(state, name))
    }

    /** A service cannot show the runtime dialog; the notification opens a screen that can. */
    private fun askPermission(ctx: Context, addr: String) {
        report(STATE_PERMISSION)
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, ctx.getString(R.string.bt_pair_channel), NotificationManager.IMPORTANCE_HIGH)
        )
        val open = PendingIntent.getActivity(
            ctx, REQ_OPEN,
            Intent(ctx, BluetoothPairActivity::class.java)
                .putExtra(BluetoothPairActivity.EXTRA_ADDRESS, addr)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        runCatching {
            nm.notify(
                NOTIF_ID,
                Notification.Builder(ctx, CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(ctx.getString(R.string.bt_pair_title))
                    .setContentText(ctx.getString(R.string.bt_pair_text))
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .build(),
            )
        }
    }

    const val STATE_BONDED = "bonded"
    const val STATE_FAILED = "failed"
    const val STATE_PERMISSION = "permission"
    const val STATE_BLUETOOTH_OFF = "bluetooth_off"

    private const val CHANNEL = "bt_pair"
    private const val NOTIF_ID = 20
    private const val REQ_OPEN = 20
    private const val TIMEOUT_MS = 120_000L
}
