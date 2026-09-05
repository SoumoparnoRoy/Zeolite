package com.soumoparno.zeolite.widget

import android.content.Context
import android.graphics.Color
import org.json.JSONObject

/**
 * Reads what Dart pushed. Nothing here computes anything: the schedule and the
 * attendance maths run once, in Dart, and this side only draws the result.
 */
object WidgetData {

    // Named rather than reached through the plugin, so the list factory — which
    // is not a widget provider — can read it too.
    private const val PREFERENCES = "HomeWidgetPreferences"

    fun read(context: Context, key: String): JSONObject? {
        val raw = raw(context, key) ?: return null
        return runCatching { JSONObject(raw) }.getOrNull()
    }

    fun raw(context: Context, key: String): String? = context
        .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        .getString(key, null)

    /** The one thing this side writes: what Dart cannot measure for itself. */
    fun write(context: Context, key: String, value: String) {
        val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (prefs.getString(key, null) == value) return
        prefs.edit().putString(key, value).apply()
    }
}

/** The app's palette, falling back to dark the way the app itself opens. */
class WidgetTheme(private val json: JSONObject?) {

    val canvas get() = color("canvas", 0xFF0B0B11)
    val surface get() = color("surface", 0xFF16161F)
    val surfaceHigh get() = color("surfaceHigh", 0xFF1E1E28)
    val outline get() = color("outline", 0xFF2C2C39)
    val accent get() = color("accent", 0xFFA28FFF)
    val textPrimary get() = color("textPrimary", 0xFFF2F2F7)
    val textSecondary get() = color("textSecondary", 0xFFA3A3B2)
    val textTertiary get() = color("textTertiary", 0xFF7E7E92)
    val present get() = color("present", 0xFF3DD68C)
    val absent get() = color("absent", 0xFFE87C7C)
    val cancelled get() = color("cancelled", 0xFFE3C34A)
    val warning get() = color("warning", 0xFFFFCE85)

    private fun color(key: String, fallback: Long): Int {
        val value = json?.optInt(key, 0) ?: 0
        return if (value == 0) fallback.toInt() else value
    }

    fun dim(color: Int, alpha: Int): Int =
        Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))

    companion object {
        fun of(context: Context) = WidgetTheme(WidgetData.read(context, "theme"))
    }
}
