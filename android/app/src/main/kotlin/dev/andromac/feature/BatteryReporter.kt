package dev.andromac.feature

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import dev.andromac.core.Link
import dev.andromac.core.Protocol
import dev.andromac.core.Store

/**
 * Battery state. The ACTION_BATTERY_CHANGED broadcast fires often; per PROTOCOL §6.2 we
 * send only on a 1% level change OR a charging-state change, and at most once every 60 s.
 * There is no separate timer — we piggyback on the broadcast the system already emits.
 */
class BatteryReporter(private val context: Context, private val store: Store) {

    private var receiver: BroadcastReceiver? = null
    private var lastLevel = -1
    private var lastCharging: Boolean? = null
    private var lastSentAt = 0L

    fun start() {
        if (!store.syncBattery || receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) = report(intent)
        }
        receiver = r
        // registerReceiver returns the sticky intent immediately, so the first report is free.
        val sticky = context.registerReceiver(r, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        sticky?.let(::report)
    }

    fun stop() {
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
        lastLevel = -1
        lastCharging = null
    }

    private fun report(intent: Intent) {
        // The toggle is rechecked here, not only in start(): turning Battery sync off
        // mid-session used to leave the receiver registered and frames flowing until the next
        // reconnect. Unregistering from inside onReceive is allowed.
        if (!store.syncBattery) {
            stop()
            return
        }
        val raw = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (raw < 0 || scale <= 0) return
        val level = raw * 100 / scale

        val statusCode = intent.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN)
        val charging = statusCode == BatteryManager.BATTERY_STATUS_CHARGING ||
            statusCode == BatteryManager.BATTERY_STATUS_FULL

        val now = System.currentTimeMillis()
        val levelChanged = level != lastLevel
        val chargeChanged = charging != lastCharging
        if (!levelChanged && !chargeChanged) return
        if (!chargeChanged && now - lastSentAt < MIN_INTERVAL_MS) return

        val tempTenths = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        val temp = if (tempTenths == Int.MIN_VALUE) null else tempTenths / 10.0

        val ok = Link.send(Protocol.battery(level, charging, statusName(statusCode), temp))
        if (ok) {
            lastLevel = level
            lastCharging = charging
            lastSentAt = now
        }
    }

    private fun statusName(code: Int) = when (code) {
        BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
        BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
        BatteryManager.BATTERY_STATUS_FULL -> "full"
        BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "not_charging"
        else -> "unknown"
    }

    private companion object {
        const val MIN_INTERVAL_MS = 60_000L
    }
}
