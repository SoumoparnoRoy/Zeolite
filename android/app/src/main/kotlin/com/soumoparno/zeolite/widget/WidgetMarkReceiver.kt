package com.soumoparno.zeolite.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import es.antonborri.home_widget.HomeWidgetBackgroundReceiver
import org.json.JSONObject

/**
 * Where a Today widget button lands.
 *
 * Saving a mark means starting Flutter, which after the process has died took
 * seconds before the button lit. So the tap is drawn here first, from what the
 * widget already holds, and then handed to Dart, which saves it and redraws
 * from the database. Dart redraws even when it refuses the tap or fails, so a
 * wrong guess here is put right. One Dart never reaches lapses (see
 * [WidgetData.pendingMarks]), and a redraw is set for when it does.
 */
class WidgetMarkReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val uri = intent.data ?: return
        // The list's template is mutable, so the widget host fills this URI in
        // and could name any class on any date. Only a class the widget is
        // showing right now, with a status the app knows, goes on to Dart.
        val tap = runCatching { tapOn(context, uri) }.getOrNull() ?: return
        // A head start only: nothing that goes wrong drawing it may stop the
        // tap reaching Dart.
        val drawnAt = runCatching { drawAtOnce(context, tap) }.getOrNull()
        // Rebuilt from what was checked, never passed on as it came: Android
        // reads the first of a repeated parameter and Dart the last, so a
        // second subject= would otherwise reach Dart unchecked.
        val checked = uri.buildUpon().clearQuery()
            .appendQueryParameter("subject", tap.subject.toString())
            .appendQueryParameter("date", tap.date.toString())
            .appendQueryParameter("start", tap.start.toString())
            .appendQueryParameter("status", tap.status)
        if (drawnAt != null) checked.appendQueryParameter("drawn", drawnAt.toString())
        val forwarded = checked.build()
        context.sendBroadcast(
            Intent(context, HomeWidgetBackgroundReceiver::class.java)
                .setAction(BACKGROUND_ACTION)
                .setData(forwarded),
        )
    }

    private class Tap(
        val subject: Int,
        val date: Int,
        val start: Int,
        val status: String,
        val session: JSONObject,
    )

    /** The tap, or null when it names something the widget is not showing. */
    private fun tapOn(context: Context, uri: Uri): Tap? {
        val subject = uri.getQueryParameter("subject")?.toIntOrNull() ?: return null
        val date = uri.getQueryParameter("date")?.toIntOrNull() ?: return null
        val start = uri.getQueryParameter("start")?.toIntOrNull() ?: return null
        val status = uri.getQueryParameter("status")?.takeIf { it in STATUSES } ?: return null
        val session = sessionFor(context, subject, date, start) ?: return null
        return Tap(subject, date, start, status, session)
    }

    /** When the tap was drawn, or null when it could not be. */
    private fun drawAtOnce(context: Context, tap: Tap): Long? {
        val key = WidgetData.markKey(tap.subject, tap.date, tap.start)
        val shown = WidgetData.pendingMarks(context)[key]
            ?: tap.session.optString("status").takeIf { it.isNotBlank() && it != "null" }
            ?: ""
        // The Today screen's rule, which Dart applies to the same tap: tapping
        // the status a class already has clears it.
        val at = WidgetData.putPendingMark(context, key, if (shown == tap.status) "" else tap.status)

        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, TodayWidgetProvider::class.java))
        if (ids.isEmpty()) return at
        TodayWidgetProvider().onUpdate(context, manager, ids)
        redrawWhenLapsed(context, ids, at)
        return at
    }

    /**
     * Nothing else redraws the widget when an unsaved tap lapses, so without
     * this it would show until the next push or midnight. Not a wakeup: the
     * redraw only matters once the screen is on to see it.
     */
    private fun redrawWhenLapsed(context: Context, ids: IntArray, at: Long) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val redraw = PendingIntent.getBroadcast(
            context,
            LAPSE_CODE,
            Intent(context, TodayWidgetProvider::class.java)
                .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarms.set(AlarmManager.RTC, at + WidgetData.PENDING_FOR_MS + 1000, redraw)
    }

    private fun sessionFor(context: Context, subject: Int, date: Int, start: Int): JSONObject? =
        shownSession(WidgetData.read(context, "today"), subject, date, start)

    internal companion object {
        private const val BACKGROUND_ACTION = "es.antonborri.home_widget.action.BACKGROUND"

        /** `AttendanceStatus` in Dart, by name. */
        val STATUSES = setOf("present", "absent", "cancelled")

        /** One alarm, moved on by each tap: the last tap's lapse is the one that matters. */
        private const val LAPSE_CODE = 7

        /** The class as the widget drew it, or null when the payload has moved on. */
        fun shownSession(today: JSONObject?, subject: Int, date: Int, start: Int): JSONObject? {
            val days = today?.optJSONArray("days") ?: return null
            for (index in 0 until days.length()) {
                val day = days.optJSONObject(index) ?: continue
                if (day.optInt("date") != date) continue
                val classes = day.optJSONArray("classes") ?: return null
                for (row in 0 until classes.length()) {
                    val session = classes.optJSONObject(row) ?: continue
                    if (session.optInt("subjectId") == subject && session.optInt("startMinutes") == start) {
                        return session
                    }
                }
            }
            return null
        }
    }
}
