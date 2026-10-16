package com.soumoparno.zeolite

import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var clock: MethodChannel? = null

    // The app's clock waits on a timer for the next class or midnight; a time
    // or zone set while the app is open would otherwise leave it waiting for
    // the wrong moment until the next resume.
    private val clockChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            clock?.invokeMethod("changed", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        clock = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLOCK_CHANNEL)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "current" -> result.success(current())
                    "select" -> {
                        val name = call.argument<String>("icon")
                        if (name == null || !ICONS.contains(name)) {
                            result.error("unknown_icon", "No launcher icon named $name", null)
                        } else {
                            select(name)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SETTINGS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        if (openNotificationSettings(call.argument<String>("channel"))) {
                            result.success(null)
                        } else {
                            result.error("no_settings", "No settings screen to open", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
        }
        // Both are system broadcasts, which reach a receiver that is not
        // exported; nothing else needs to.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(clockChanged, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(clockChanged, filter)
        }
    }

    override fun onStop() {
        unregisterReceiver(clockChanged)
        super.onStop()
    }

    // Below Android 8 there are no channels and no notification screen of the
    // app's own, so the app info page is the nearest thing.
    private fun openNotificationSettings(channel: String?): Boolean {
        val intent = when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ->
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", packageName, null))
            channel != null ->
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, channel)
            else ->
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        }
        // Some OEM and Go builds ship without the notification screens, and an
        // uncaught throw here takes the app down from a settings row.
        return start(intent) ||
            start(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", packageName, null))
            )
    }

    private fun start(intent: Intent): Boolean =
        try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }

    private fun current(): String =
        ICONS.firstOrNull {
            packageManager.getComponentEnabledSetting(component(it)) ==
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } ?: DEFAULT

    // Enabled before the outgoing one is disabled: with no launcher component
    // in between, some launchers drop the app rather than swapping its icon.
    private fun select(name: String) {
        if (current() == name) return
        enable(name, PackageManager.COMPONENT_ENABLED_STATE_ENABLED)
        ICONS.filter { it != name }
            .forEach { enable(it, PackageManager.COMPONENT_ENABLED_STATE_DISABLED) }
    }

    // DONT_KILL_APP is what keeps this from tearing the process down mid-tap.
    // Android is free to ignore it, so the caller still has to survive being
    // killed here.
    private fun enable(name: String, state: Int) {
        packageManager.setComponentEnabledSetting(
            component(name), state, PackageManager.DONT_KILL_APP)
    }

    private fun component(name: String) = ComponentName(
        packageName,
        "$packageName.Launcher${name.replaceFirstChar { it.uppercase() }}",
    )

    private companion object {
        const val CHANNEL = "zeolite/launcher_icon"
        const val SETTINGS_CHANNEL = "zeolite/notification_settings"
        const val CLOCK_CHANNEL = "zeolite/clock"
        const val DEFAULT = "default"

        val ICONS = listOf(
            DEFAULT, "teal", "sky", "indigo", "violet", "plum", "magenta", "slate")
    }
}
