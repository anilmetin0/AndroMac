package dev.andromac.ui

import android.app.Activity
import android.os.Bundle
import dev.andromac.R
import dev.andromac.core.Store

/** File transfer: on/off, and whether an offer from the paired Mac is saved without asking. */
class FileSettingsActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_files, R.string.file_title)
        val store = Store(this)

        bindSwitchRow(R.id.rowEnabled, R.id.swEnabled, store.fileTransfer) {
            store.fileTransfer = it
            setRowEnabled(R.id.rowAuto, it)
        }
        bindSwitchRow(R.id.rowAuto, R.id.swAuto, store.fileAutoAccept) { store.fileAutoAccept = it }
        setRowEnabled(R.id.rowAuto, store.fileTransfer)
    }
}
