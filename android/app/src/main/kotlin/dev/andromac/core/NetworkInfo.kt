package dev.andromac.core

import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * The device's local network address.
 *
 * Shown in the setup guide: the most common reason for a failed connection is that the phone
 * and the Mac are on DIFFERENT networks (phone on mobile data, Mac on another Wi-Fi). Seeing
 * both addresses side by side makes that obvious at a glance — reading the Wi-Fi name needs
 * the location permission, reading the IP does not.
 */
object NetworkInfo {

    /** For example "192.168.1.42", or null when there is no local network. */
    fun localIpv4(): String? = runCatching {
        NetworkInterface.getNetworkInterfaces()
            .asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { it.isSiteLocalAddress }
            ?.hostAddress
    }.getOrNull()

    /**
     * The network part of an address: `192.168.1.42` with prefix 24 is `192.168.1.0/24`. Part of
     * the key `LinkService` uses to recognise the network the Mac was last reached on.
     */
    fun networkPrefix(address: ByteArray, prefixLength: Int): String {
        val masked = address.mapIndexed { i, b ->
            val bits = (prefixLength - i * 8).coerceIn(0, 8)
            (b.toInt() and (0xFF shl (8 - bits))).toByte()
        }.toByteArray()
        return "${java.net.InetAddress.getByAddress(masked).hostAddress}/$prefixLength"
    }

    /** "192.168.1.42" -> "192.168.1" — used to compare whether two devices sit on the same subnet. */
    fun subnetOf(ip: String?): String? =
        ip?.substringBeforeLast('.', missingDelimiterValue = "")?.takeIf { it.isNotEmpty() }
}
