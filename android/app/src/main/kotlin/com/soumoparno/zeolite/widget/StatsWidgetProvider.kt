package com.soumoparno.zeolite.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import com.soumoparno.zeolite.MainActivity
import com.soumoparno.zeolite.R
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import org.json.JSONArray
import org.json.JSONObject

/**
 * Where you stand overall, and then each subject, weakest first.
 *
 * The two were separate widgets. They answer the same question at two zoom
 * levels and the overall figure is what the subjects add up to, so keeping them
 * apart meant placing both to see either properly.
 *
 * The subjects are a scrolling list: inline items from Android 12, fed by
 * [StatsWidgetService] below that. Rows pushed straight into the layout cannot
 * scroll, so the list had to be cut to what the cell held.
 */
class StatsWidgetProvider : ZeoliteWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val theme = WidgetTheme.of(context)
        val subjects = WidgetData.read(context, "subjects")?.optJSONArray("subjects")
        val standing = WidgetData.read(context, "standing")

        appWidgetIds.forEach { widgetId ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Both layouts, and the launcher shows whichever fits the cell
                // as it stands, landscape included; the rows travel inline.
                appWidgetManager.updateAppWidget(
                    widgetId,
                    RemoteViews(
                        mapOf(
                            SizeF(0f, 0f) to inline(
                                context, theme, standing, subjects,
                                R.layout.widget_stats_narrow, R.layout.widget_stats_row_narrow,
                            ),
                            SizeF(NARROW_CELL_DP, 0f) to inline(
                                context, theme, standing, subjects,
                                R.layout.widget_stats, R.layout.widget_stats_row,
                            ),
                        ),
                    ),
                )
                return@forEach
            }
            val layout =
                if (isNarrowCell(appWidgetManager.getAppWidgetOptions(widgetId))) {
                    R.layout.widget_stats_narrow
                } else {
                    R.layout.widget_stats
                }
            val views = summary(context, theme, standing, subjects?.length() ?: 0, layout).apply {
                setRemoteAdapter(R.id.stats_rows, rowsIntent(context, widgetId))
            }
            appWidgetManager.updateAppWidget(widgetId, views)
            // The adapter is bound once; this is what makes it re-read after a
            // push, and without it the list keeps yesterday's rows.
            appWidgetManager.notifyAppWidgetViewDataChanged(widgetId, R.id.stats_rows)
        }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun inline(
        context: Context,
        theme: WidgetTheme,
        standing: JSONObject?,
        subjects: JSONArray?,
        layout: Int,
        rowLayout: Int,
    ): RemoteViews {
        val count = subjects?.length() ?: 0
        val rows = RemoteViews.RemoteCollectionItems.Builder()
            .setHasStableIds(true)
            .setViewTypeCount(2)
        for (index in 0 until count) {
            rows.addItem(
                index.toLong(),
                statsRow(context, theme, subjects!!.getJSONObject(index), rowLayout),
            )
        }
        return summary(context, theme, standing, count, layout).apply {
            setRemoteAdapter(R.id.stats_rows, rows.build())
        }
    }

    /** Everything but the rows, which come either inline or from the service. */
    private fun summary(
        context: Context,
        theme: WidgetTheme,
        standing: JSONObject?,
        count: Int,
        layout: Int,
    ): RemoteViews {
        val hasData = standing?.optBoolean("hasData") ?: false
        val meetsTarget = standing?.optBoolean("meetsTarget") ?: true
        val next = nextLine(context, standing)

        return RemoteViews(context.packageName, layout).apply {
            setTintedBackground(R.id.stats_root, theme.canvas)
            setTextColor(R.id.stats_verdict, theme.textPrimary)
            setTextColor(R.id.stats_next, theme.textSecondary)
            setTextColor(R.id.stats_empty, theme.textTertiary)
            setTextColor(
                R.id.stats_percent,
                if (!hasData) theme.textTertiary
                else if (meetsTarget) theme.present else theme.warning,
            )

            setTextViewText(
                R.id.stats_percent,
                if (hasData) WidgetData.percentText(standing) else "—",
            )
            setTextViewText(R.id.stats_verdict, standing?.optString("verdict") ?: "")
            setViewVisibility(R.id.stats_next, if (next != null) View.VISIBLE else View.GONE)
            if (next != null) setTextViewText(R.id.stats_next, next)

            val openStats = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse("zeolite://open?tab=stats"),
            )
            setOnClickPendingIntent(R.id.stats_root, openStats)
            // The list swallows taps that land on it, so the rows need the
            // same destination handed to them as a template.
            setPendingIntentTemplate(R.id.stats_rows, openStats)
            setEmptyView(R.id.stats_rows, R.id.stats_empty)
            if (count == 0) {
                setTextViewText(R.id.stats_empty, context.getString(R.string.widget_empty_preview))
            }
        }
    }

    /**
     * The first class Dart listed that has not started, worded for today.
     * Picked here because "next" moves on at every class start and "Tomorrow"
     * at every midnight, both with the app closed; the widget is redrawn at
     * each of those moments.
     */
    private fun nextLine(context: Context, standing: JSONObject?): String? {
        val upcoming = standing?.optJSONArray("upcoming") ?: return null
        val now = System.currentTimeMillis()
        for (index in 0 until upcoming.length()) {
            val next = upcoming.optJSONObject(index) ?: continue
            if (next.optLong("at") <= now) continue
            val label = next.optJSONObject("when")
                ?.optString(WidgetData.todayKey().toString())
                ?.takeIf { it.isNotBlank() } ?: return null
            return context.getString(R.string.widget_next, next.optString("subject"), label)
        }
        return null
    }

    /**
     * Unique per widget id, or Android hands every copy of the widget the
     * factory it built for the first one.
     */
    private fun rowsIntent(context: Context, widgetId: Int): Intent =
        Intent(context, StatsWidgetService::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
        }
}
