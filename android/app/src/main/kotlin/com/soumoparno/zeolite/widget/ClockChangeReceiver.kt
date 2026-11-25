package com.soumoparno.zeolite.widget

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import es.antonborri.home_widget.HomeWidgetScheduler
import java.time.LocalDate
import java.time.ZoneId
import org.json.JSONObject

/**
 * Moves the widgets to the right day when the clock or time zone is set by
 * hand with the app closed.
 *
 * The midnight redraws are alarms at fixed instants, worked out in the zone
 * the app last ran in. After a zone change none of them is due, and after the
 * date goes back the ones in between were already spent, so the widgets kept
 * the old day until the app was opened. This redraws them now and re-arms
 * the midnights in the current zone from the days the app already pushed.
 * Nothing is recomputed: a jump past the pushed week shows the widgets'
 * "open the app" message, as a week unopened does.
 */
class ClockChangeReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in ACTIONS) return
        val today = WidgetData.read(context, "today")
        val standing = WidgetData.read(context, "standing")
        val now = System.currentTimeMillis()
        val zone = ZoneId.systemDefault()
        for (provider in PROVIDERS) {
            val times = redrawTimes(today, if (provider == STATS) standing else null, now, zone)
            // An empty list would cancel the schedule the app set; keep it.
            if (times.isNotEmpty()) {
                HomeWidgetScheduler.schedule(context, provider.name, times)
            }
            redraw(context, provider)
        }
    }

    private fun redraw(context: Context, provider: Class<*>) {
        val ids = AppWidgetManager.getInstance(context)
            .getAppWidgetIds(ComponentName(context, provider))
        if (ids.isEmpty()) return
        context.sendBroadcast(
            Intent(context, provider)
                .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids),
        )
    }

    internal companion object {
        /** TIME_SET is `Intent.ACTION_TIME_CHANGED`'s value. */
        val ACTIONS = setOf(Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED)

        private val STATS = StatsWidgetProvider::class.java
        private val PROVIDERS = listOf(
            TodayWidgetProvider::class.java,
            WeekWidgetProvider::class.java,
            STATS,
        )

        /**
         * When to redraw from [now] on, as Dart's `_scheduleRedraws` sets it: the
         * start of each pushed day in [zone], the midnight after the last one so
         * the widget can say it has nothing for that day, and for the Stats
         * widget each class start in [standing], when its "Next" line moves on.
         */
        fun redrawTimes(today: JSONObject?, standing: JSONObject?, now: Long, zone: ZoneId): List<Long> {
            val dates = mutableListOf<LocalDate>()
            val days = today?.optJSONArray("days")
            for (index in 0 until (days?.length() ?: 0)) {
                dateOf(days?.optJSONObject(index)?.optInt("date") ?: 0)?.let(dates::add)
            }
            val midnights = (dates + listOfNotNull(dates.maxOrNull()?.plusDays(1)))
                .map { it.atStartOfDay(zone).toInstant().toEpochMilli() }
            val upcoming = standing?.optJSONArray("upcoming")
            val starts = (0 until (upcoming?.length() ?: 0))
                .mapNotNull { upcoming?.optJSONObject(it)?.optLong("at")?.takeIf { at -> at > 0 } }
            return (midnights + starts).filter { it > now }.distinct().sorted()
        }

        /** Dart's yyyymmdd day key, or null for one that is not a date. */
        private fun dateOf(key: Int): LocalDate? =
            runCatching { LocalDate.of(key / 10000, key / 100 % 100, key % 100) }.getOrNull()
    }
}
