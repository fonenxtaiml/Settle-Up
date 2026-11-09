package app.settleup.settle_up

import android.app.UiModeManager
import android.os.Build
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The single activity. Besides hosting Flutter it answers the
 * `app.settleup/window` channel (lib/ui/platform/app_window.dart):
 *
 * - `setSecure(bool)`: sets or clears FLAG_SECURE, so the invite QR (which
 *   carries the group key) is kept out of screenshots, screen recordings
 *   and the recents thumbnail while it is on screen.
 * - `setNightMode("system" | "light" | "dark")`: on API 31+ stores the
 *   in-app theme as the app's night mode, so the system splash and the
 *   launch window on the next cold start match the theme the user picked.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "setNightMode" -> result.success(setNightMode(call.arguments as? String))
                    else -> result.notImplemented()
                }
            }
    }

    /** Returns whether the night mode was stored (false below API 31). */
    private fun setNightMode(mode: String?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        val night = when (mode) {
            "light" -> UiModeManager.MODE_NIGHT_NO
            "dark" -> UiModeManager.MODE_NIGHT_YES
            else -> UiModeManager.MODE_NIGHT_AUTO // follow the system
        }
        return try {
            val manager = getSystemService(UiModeManager::class.java) ?: return false
            // Persisted by the system; the same value again is a no-op.
            manager.setApplicationNightMode(night)
            true
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not set the app night mode", e)
            false
        }
    }

    private companion object {
        const val CHANNEL = "app.settleup/window"
        const val TAG = "SettleUp"
    }
}
