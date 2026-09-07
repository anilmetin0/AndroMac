package dev.andromac.ui

import android.app.Activity
import android.app.AlertDialog
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Menu
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.ImageView
import android.widget.ListView
import android.widget.PopupMenu
import android.widget.TextView
import dev.andromac.R
import dev.andromac.core.Store
import dev.andromac.feature.AppModeSync

/**
 * The apps that have posted a notification, each with its three tiers.
 *
 * The tier is enforced on the phone: a notification from an OFF app is never sent, and the
 * content of a TITLE-ONLY app never leaves the phone (PROTOCOL §6.6).
 */
class AppsActivity : Activity() {

    private lateinit var store: Store
    private lateinit var adapter: AppsAdapter
    private val main = Handler(Looper.getMainLooper())

    /** Secondary text color resolved from the theme attribute (once, so the adapter need not read it per row). */
    private val secondaryTextColor: Int by lazy {
        val typed = android.util.TypedValue()
        theme.resolveAttribute(android.R.attr.textColorSecondary, typed, true)
        if (typed.resourceId != 0) getColor(typed.resourceId) else typed.data
    }

    private val modeLabels by lazy {
        arrayOf(
            getString(R.string.mode_off),
            getString(R.string.mode_title_only),
            getString(R.string.mode_full),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupDetailScreen(R.layout.activity_apps, R.string.apps_title)
        store = Store(this)

        val rows = store.seenApps.entries
            .map { AppRow(it.key, it.value) }
            .sortedBy { it.label.lowercase() }

        findViewById<TextView>(R.id.appsEmpty).visibility =
            if (rows.isEmpty()) View.VISIBLE else View.GONE
        // While empty the hint would repeat the empty-state text; it is shown only once the list has entries.
        findViewById<TextView>(R.id.appsHint).apply {
            visibility = if (rows.isEmpty()) View.GONE else View.VISIBLE
            text = resources.getQuantityString(R.plurals.apps_hint, rows.size, rows.size)
        }

        val action = findViewById<View>(R.id.headerAction)
        action.visibility = View.VISIBLE
        action.setOnClickListener { showOverflow(action) }

        adapter = AppsAdapter(rows)
        findViewById<ListView>(R.id.appsList).apply {
            this.adapter = this@AppsActivity.adapter
            setOnItemClickListener { _, _, position, _ -> pickMode(rows[position]) }
        }
        preloadIcons(rows)
    }

    /** The overflow menu in the header; it replaced res/menu/apps.xml. */
    private fun showOverflow(anchor: View) {
        PopupMenu(this, anchor).apply {
            menu.add(Menu.NONE, 0, Menu.NONE, R.string.apps_forget)
            setOnMenuItemClickListener { confirmForget(); true }
            show()
        }
    }

    private fun confirmForget() {
        AlertDialog.Builder(this)
            .setTitle(R.string.apps_forget)
            .setMessage(R.string.apps_forget_confirm)
            .setPositiveButton(R.string.apps_forget) { _, _ ->
                store.forgetApps()
                AppModeSync.push(store)
                recreate()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun pickMode(row: AppRow) {
        val current = store.modeFor(row.pkg)
        AlertDialog.Builder(this)
            .setTitle(row.label)
            .setSingleChoiceItems(modeLabels, current) { dialog, which ->
                store.setMode(row.pkg, which)
                AppModeSync.push(store)          // keep the list on the Mac in sync too
                adapter.notifyDataSetChanged()
                dialog.dismiss()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /**
     * Icons are loaded in the background. Calling `PackageManager.getApplicationIcon` inside
     * `getView()` makes scrolling stutter — rasterizing adaptive icons is not cheap.
     */
    private fun preloadIcons(rows: List<AppRow>) {
        Thread({
            val loaded = HashMap<String, Drawable>(rows.size)
            for (row in rows) {
                runCatching { packageManager.getApplicationIcon(row.pkg) }
                    .getOrNull()?.let { loaded[row.pkg] = it }
            }
            main.post {
                if (!isFinishing) {
                    adapter.icons.putAll(loaded)
                    adapter.notifyDataSetChanged()
                }
            }
        }, "andromac-icons").apply { isDaemon = true }.start()
    }

    private data class AppRow(val pkg: String, val label: String)

    private class ViewHolder(view: View) {
        val icon: ImageView = view.findViewById(R.id.appIcon)
        val label: TextView = view.findViewById(R.id.appLabel)
        val pkg: TextView = view.findViewById(R.id.appPackage)
        val mode: TextView = view.findViewById(R.id.appMode)
    }

    private inner class AppsAdapter(private val rows: List<AppRow>) : BaseAdapter() {

        val icons = HashMap<String, Drawable>()

        override fun getCount() = rows.size
        override fun getItem(position: Int) = rows[position]
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val view = convertView ?: layoutInflater.inflate(R.layout.item_app, parent, false)
                .also { it.tag = ViewHolder(it) }
            val holder = view.tag as ViewHolder
            val row = rows[position]
            val mode = store.modeFor(row.pkg)

            holder.label.text = row.label
            holder.pkg.text = row.pkg
            holder.icon.setImageDrawable(icons[row.pkg])   // on null the placeholder stays empty
            // The default (Full) reads quietly; restricted apps stand out in the accent color.
            // A real color rather than alpha: alpha makes the contrast ratio impossible to measure.
            holder.mode.text = modeLabels[mode]
            holder.mode.setTextColor(
                if (mode == Store.MODE_FULL) secondaryTextColor else getColor(R.color.am_accent)
            )
            return view
        }
    }
}
