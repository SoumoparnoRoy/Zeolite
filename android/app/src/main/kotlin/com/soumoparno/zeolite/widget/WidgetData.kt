package com.soumoparno.zeolite.widget

import android.content.Context
import android.graphics.Color
import org.json.JSONObject
import java.util.Calendar

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

    /**
     * An attendance figure as the app formats it. A payload pushed before the
     * app formatted it carries a whole number instead, and the launcher keeps
     * redrawing from it until the app next opens.
     */
    fun percentText(entry: JSONObject?): String =
        entry?.optString("percentText")?.takeIf { it.isNotEmpty() && it != "null" }
            ?: "${entry?.optInt("percent")}%"

    /** Today as the yyyymmdd number Dart keys its days by. */
    fun todayKey(): Int {
        val now = Calendar.getInstance()
        return now.get(Calendar.YEAR) * 10000 +
            (now.get(Calendar.MONTH) + 1) * 100 +
            now.get(Calendar.DAY_OF_MONTH)
    }

    /**
     * The entry Dart wrote for today out of a payload's `days`. Dart writes a
     * week ahead and the widgets redraw at midnight, so this is how they move
     * to the next day with the app closed. Null once the app has gone unopened
     * for longer than that.
     */
    fun today(payload: JSONObject?): JSONObject? {
        val days = payload?.optJSONArray("days") ?: return null
        val today = todayKey()
        for (index in 0 until days.length()) {
            val day = days.optJSONObject(index)
            if (day?.optInt("date") == today) return day
        }
        return null
    }

    /** How a mark is filed: the class's natural key, as Dart writes it. */
    fun markKey(subjectId: Int, date: Int, startMinutes: Int) = "$subjectId:$date:$startMinutes"

    /**
     * Taps the Today widget has drawn that Dart has not saved yet, by
     * [markKey]: the status, or "" for a cleared one; the latest tap on a class
     * wins. Each tap is its own preference, `pendingMark:<markKey>@<millis>`,
     * so Dart removes exactly the one it saved and never writes back over a tap
     * drawn meanwhile. One left past [PENDING_FOR_MS] means Dart never got to
     * it, and is ignored, so the widget shows what Dart last pushed rather than
     * a mark nobody saved; [WidgetMarkReceiver] sets a redraw for that moment.
     */
    fun pendingMarks(context: Context): Map<String, String> {
        val now = System.currentTimeMillis()
        val latest = mutableMapOf<String, Pair<Long, String>>()
        prefs(context).all.forEach { (name, value) ->
            val (key, at) = pendingTap(name) ?: return@forEach
            if (now - at !in 0 until PENDING_FOR_MS) return@forEach
            if (at >= (latest[key]?.first ?: Long.MIN_VALUE)) latest[key] = at to "$value"
        }
        return latest.mapValues { it.value.second }
    }

    /** Returns when it was drawn, which Dart uses to settle this tap and no later one. */
    fun putPendingMark(context: Context, key: String, status: String): Long {
        val at = System.currentTimeMillis()
        val prefs = prefs(context)
        val editor = prefs.edit()
        // Taps Dart never saved are dropped here, or they would pile up.
        prefs.all.keys.forEach { name ->
            val tap = pendingTap(name) ?: return@forEach
            if (at - tap.second !in 0 until PENDING_FOR_MS) editor.remove(name)
        }
        editor.putString("$PENDING_MARK$key@$at", status).apply()
        return at
    }

    private fun pendingTap(name: String): Pair<String, Long>? {
        if (!name.startsWith(PENDING_MARK)) return null
        val key = name.substringAfter(PENDING_MARK).substringBeforeLast('@')
        val at = name.substringAfterLast('@').toLongOrNull() ?: return null
        return key to at
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    private const val PENDING_MARK = "pendingMark:"
    const val PENDING_FOR_MS = 2 * 60 * 1000L

    /** Written here: what Dart cannot measure for itself, and taps not yet saved. */
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
