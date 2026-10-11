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
        // A head start only: nothing that goes wrong drawing it may stop the
        // tap reaching Dart.
        val drawnAt = runCatching { drawAtOnce(context, uri) }.getOrNull()
        val forwarded = if (drawnAt == null) {
            uri
        } else {
            uri.buildUpon().appendQueryParameter("drawn", drawnAt.toString()).build()
        }
        context.sendBroadcast(
            Intent(context, HomeWidgetBackgroundReceiver::class.java)
                .setAction(BACKGROUND_ACTION)
                .setData(forwarded),
        )
    }

    /** When the tap was drawn, or null when it could not be. */
    private fun drawAtOnce(context: Context, uri: Uri): Long? {
        val subject = uri.getQueryParameter("subject")?.toIntOrNull() ?: return null
        val date = uri.getQueryParameter("date")?.toIntOrNull() ?: return null
        val start = uri.getQueryParameter("start")?.toIntOrNull() ?: return null
        val status = uri.getQueryParameter("status")?.takeIf { it.isNotBlank() } ?: return null
        val session = sessionFor(context, subject, date, start) ?: return null

        val key = WidgetData.markKey(subject, date, start)
        val shown = WidgetData.pendingMarks(context)[key]
            ?: session.optString("status").takeIf { it.isNotBlank() && it != "null" }
            ?: ""
        // The Today screen's rule, which Dart applies to the same tap: tapping
        // the status a class already has clears it.
        val at = WidgetData.putPendingMark(context, key, if (shown == status) "" else status)

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

    /** The class as the widget drew it, or null when the payload has moved on. */
    private fun sessionFor(context: Context, subject: Int, date: Int, start: Int): JSONObject? {
        val days = WidgetData.read(context, "today")?.optJSONArray("days") ?: return null
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

    private companion object {
        const val BACKGROUND_ACTION = "es.antonborri.home_widget.action.BACKGROUND"

        /** One alarm, moved on by each tap: the last tap's lapse is the one that matters. */
        const val LAPSE_CODE = 7
    }
}
