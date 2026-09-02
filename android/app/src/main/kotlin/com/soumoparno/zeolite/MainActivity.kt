package com.soumoparno.zeolite

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        const val DEFAULT = "default"

        val ICONS = listOf(
            DEFAULT, "teal", "sky", "indigo", "violet", "plum", "magenta", "slate")
    }
}
