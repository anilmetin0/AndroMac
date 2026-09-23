package io.github.anilmetin0.andromac

import android.app.Application
import io.github.anilmetin0.andromac.feature.Updater

/**
 * The process entry. Its only job: the automatic update counts the app's started screens, and
 * only a count that starts before the first screen exists is a true one ([Updater.watchScreens]).
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Updater.watchScreens(this)
    }
}
