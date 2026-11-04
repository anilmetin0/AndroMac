package dev.andromac.core

/** A sleeping Mac can relaunch with a different port. Never suppress discovery indefinitely. */
object ReconnectPolicy {
    const val BROWSE_EVERY = 4

    /**
     * [cachedRefused]: the cached address answered with a refusal for the first time. The Mac's
     * host is up but nothing listens on that port any more, so its new port is one browse away;
     * waiting for the next fourth attempt left the phone up to 20 minutes behind a Mac that was
     * already back. A refusal repeated on the same address (the app is not running) waits again.
     */
    fun shouldBrowse(hasCachedEndpoint: Boolean, attempt: Int, sameNetwork: Boolean, cachedRefused: Boolean = false): Boolean =
        !hasCachedEndpoint || attempt == 0 || cachedRefused || (sameNetwork && attempt % BROWSE_EVERY == 0)

    /** True for a connect error that means "host reached, port closed" (ECONNREFUSED). */
    fun isRefusal(e: java.io.IOException): Boolean =
        e is java.net.ConnectException && e.message.orEmpty().let { "ECONNREFUSED" in it || "refused" in it }
}
