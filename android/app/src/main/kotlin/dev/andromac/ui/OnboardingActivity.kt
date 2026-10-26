package dev.andromac.ui

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import dev.andromac.R
import dev.andromac.core.Link
import dev.andromac.core.Store

/**
 * The setup flow: a welcome, the permissions in their three groups, then the connection guide.
 * It opens by itself once, on the first launch of an unpaired phone, and again from Settings.
 *
 * Every step can be passed over with Next, and Skip leaves the whole flow; the main screen's
 * permission card and Settings, Permissions catch whatever was left. A step whose permissions are
 * all granted is passed over, and one the user completes moves on by itself. Nothing here runs
 * on a timer: the states are re-read when the user comes back from a dialog or a settings screen.
 */
class OnboardingActivity : Activity() {

    /** [bodyRes] 0: the step has no line under its title. */
    private enum class Step(val titleRes: Int, val bodyRes: Int, val kind: Permission.Kind? = null) {
        WELCOME(R.string.onboarding_welcome_title, R.string.onboarding_welcome_body),
        REQUIRED(R.string.onboarding_required_title, R.string.onboarding_required_body, Permission.Kind.REQUIRED),
        // One row whose note already says why.
        RECOMMENDED(R.string.onboarding_recommended_title, 0, Permission.Kind.RECOMMENDED),
        OPTIONAL(R.string.onboarding_optional_title, R.string.onboarding_optional_body, Permission.Kind.OPTIONAL),
        // The guide below the title says the rest.
        CONNECT(R.string.onboarding_connect_title, 0),
    }

    private lateinit var store: Store
    private lateinit var steps: List<Step>
    private var index = 0
    private val step get() = steps[index]

    private val title by lazy { findViewById<TextView>(R.id.onboardingTitle) }
    private val list by lazy { findViewById<LinearLayout>(R.id.onboardingList) }
    private val nextButton by lazy { findViewById<Button>(R.id.onboardingNext) }

    /** One delayed step forward after the last grant, so the check is seen before the page turns. */
    private val handler = Handler(Looper.getMainLooper())
    private val advance = Runnable { next() }
    /** Whether the step was complete when last drawn: only a change since then moves on by itself. */
    private var wasComplete = false

    /** A pairing request belongs on the main screen, which confirms the code. */
    private val listener: (Link.State) -> Unit = { s ->
        runOnUiThread {
            if (s is Link.State.NeedsPairing) openMain(pair = false)
            else if (step == Step.CONNECT) renderConnectionGuide()
        }
    }

    /** Back walks the steps; on the first one it is the system's, so the predictive animation stays. */
    private var backCallback: Any? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_onboarding)
        findViewById<View>(R.id.onboardingRoot).padForSystemBars()
        store = Store(this)
        // Seen once is enough: it never opens on its own again, however it is left.
        store.onboardingDone = true
        // A paired phone has nothing to connect; its flow ends with the permissions.
        steps = Step.entries.filter { it != Step.CONNECT || !store.isPaired }

        findViewById<View>(R.id.guideLabel).visibility = View.GONE
        bindConnectionGuide()
        findViewById<View>(R.id.onboardingSkip).setOnClickListener { finish() }
        nextButton.setOnClickListener { if (step == Step.CONNECT) openMain(pair = true) else next() }

        show(savedInstanceState?.getInt(KEY_STEP)?.coerceIn(steps.indices) ?: 0, animate = false)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt(KEY_STEP, index)
    }

    override fun onStart() {
        super.onStart()
        Link.addListener(listener)
    }

    /** Back from a dialog or a settings screen: re-read the states, and move on if this finished the step. */
    override fun onResume() {
        super.onResume()
        renderPermissionRows(list)
        renderNext()
        if (step == Step.CONNECT) renderConnectionGuide()
        val complete = isComplete(step)
        if (complete && !wasComplete) handler.postDelayed(advance, ADVANCE_DELAY_MS)
        wasComplete = complete
    }

    override fun onPause() {
        handler.removeCallbacks(advance)
        super.onPause()
    }

    override fun onStop() {
        Link.removeListener(listener)
        super.onStop()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        onPermissionsResult(permissions, grantResults)
    }

    /** API 29-32 only: from 33 the platform callback in [updateBack] gets the gesture instead. */
    @SuppressLint("GestureBackNavigation")
    @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
    override fun onBackPressed() {
        if (index > 0) previous() else super.onBackPressed()
    }

    // ---------------------------------------------------------------- steps

    /** A permission step with nothing left to grant. The others are never complete on their own. */
    private fun isComplete(s: Step): Boolean =
        s.kind != null && Permission.current(s.kind).all { it.granted(this) }

    private fun next() {
        handler.removeCallbacks(advance)
        var i = index + 1
        while (i < steps.size && isComplete(steps[i])) i++
        if (i < steps.size) show(i) else finish()
    }

    private fun previous() {
        var i = index - 1
        while (i > 0 && isComplete(steps[i])) i--
        show(i.coerceAtLeast(0))
    }

    private fun show(i: Int, animate: Boolean = true) {
        index = i
        val s = step
        title.setText(s.titleRes)
        findViewById<TextView>(R.id.onboardingBody).apply {
            if (s.bodyRes != 0) setText(s.bodyRes)
            visibility = if (s.bodyRes != 0) View.VISIBLE else View.GONE
        }
        findViewById<View>(R.id.onboardingIcon).visibility = if (s == Step.WELCOME) View.VISIBLE else View.GONE

        if (s.kind != null) addPermissionRows(list, Permission.current(s.kind))
        list.visibility = if (s.kind != null) View.VISIBLE else View.GONE
        findViewById<View>(R.id.onboardingSectionGuide).visibility = if (s == Step.CONNECT) View.VISIBLE else View.GONE
        if (s == Step.CONNECT) renderConnectionGuide()
        wasComplete = isComplete(s)

        renderNext()
        renderProgress()
        updateBack()

        val scroll = findViewById<ScrollView>(R.id.onboardingScroll)
        scroll.scrollTo(0, 0)
        // TalkBack reads the new step's title, as it would for a new screen.
        scroll.accessibilityPaneTitle = title.text
        if (animate && ValueAnimator.areAnimatorsEnabled()) {
            val content = findViewById<View>(R.id.onboardingContent)
            content.alpha = 0f
            content.translationY = resources.displayMetrics.density * 16
            content.animate().alpha(1f).translationY(0f).setDuration(220).start()
        }
    }

    private fun renderNext() {
        nextButton.setText(when {
            step == Step.WELCOME -> R.string.onboarding_start
            step == Step.CONNECT -> R.string.pair
            // Steps already complete are passed over, so this may be the last one shown.
            (index + 1 until steps.size).all { isComplete(steps[it]) } -> R.string.onboarding_done
            else -> R.string.onboarding_next
        })
    }

    /** One pill per step: done and current in primary, the current one wider, the rest outlined. */
    private fun renderProgress() {
        val bar = findViewById<LinearLayout>(R.id.onboardingProgress)
        val dp = resources.displayMetrics.density
        if (bar.childCount != steps.size) {
            bar.removeAllViews()
            repeat(steps.size) {
                bar.addView(View(this).apply {
                    setBackgroundResource(R.drawable.bg_progress_dot)
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                })
            }
        }
        for (i in 0 until bar.childCount) {
            bar.getChildAt(i).apply {
                layoutParams = LinearLayout.LayoutParams(((if (i == index) 24 else 8) * dp).toInt(), (8 * dp).toInt())
                    .apply { marginEnd = (6 * dp).toInt() }
                background.mutate().setTint(getColor(if (i <= index) R.color.am_primary else R.color.am_outline_variant))
            }
        }
        bar.contentDescription = getString(R.string.onboarding_progress, index + 1, steps.size)
    }

    private fun updateBack() {
        if (Build.VERSION.SDK_INT < 33) return
        val registered = backCallback as OnBackInvokedCallback?
        if (index > 0 && registered == null) {
            val callback = OnBackInvokedCallback { previous() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
            backCallback = callback
        } else if (index == 0 && registered != null) {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(registered)
            backCallback = null
        }
    }

    /** Back to the main screen, under which this flow usually runs; [pair] opens the Mac picker there. */
    private fun openMain(pair: Boolean) {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(MainActivity.EXTRA_PAIR, pair)
        )
        finish()
    }

    private companion object {
        const val KEY_STEP = "step"
        const val ADVANCE_DELAY_MS = 600L
    }
}
