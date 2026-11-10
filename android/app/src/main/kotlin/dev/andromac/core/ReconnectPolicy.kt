package dev.andromac.core

/** A sleeping Mac can relaunch with a different port. Never suppress discovery indefinitely. */
object ReconnectPolicy {
    const val BROWSE_EVERY = 4

    fun shouldBrowse(hasCachedEndpoint: Boolean, attempt: Int, sameNetwork: Boolean): Boolean =
        !hasCachedEndpoint || attempt == 0 || (sameNetwork && attempt % BROWSE_EVERY == 0)

    /** True for a connect error that means "host reached, port closed" (ECONNREFUSED). */
    fun isRefusal(e: java.io.IOException): Boolean =
        e is java.net.ConnectException && e.message.orEmpty().let { "ECONNREFUSED" in it || "refused" in it }
}
