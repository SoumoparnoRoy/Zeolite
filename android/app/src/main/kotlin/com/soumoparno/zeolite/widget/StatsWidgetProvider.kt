package com.soumoparno.zeolite.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import com.soumoparno.zeolite.MainActivity
import com.soumoparno.zeolite.R
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/**
 * Where you stand overall, and then each subject, weakest first.
 *
 * The two were separate widgets. They answer the same question at two zoom
 * levels and the overall figure is what the subjects add up to, so keeping them
 * apart meant placing both to see either properly.
 *
 * The subjects are a scrolling collection, fed by [StatsWidgetService]. Rows
 * pushed straight into the layout cannot scroll, so the list had to be cut to
 * what the cell held.
 */
class StatsWidgetProvider : ZeoliteWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val theme = WidgetTheme.of(context)
        val payload = WidgetData.read(context, "subjects")
        val standing = WidgetData.read(context, "standing")
        val count = payload?.optJSONArray("subjects")?.length() ?: 0

        val hasData = standing?.optBoolean("hasData") ?: false
        val meetsTarget = standing?.optBoolean("meetsTarget") ?: true
        val next = standing?.optJSONObject("next")

        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.widget_stats).apply {
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
                    if (hasData) "${standing?.optInt("percent")}%" else "—",
                )
                setTextViewText(R.id.stats_verdict, standing?.optString("verdict") ?: "")
                setViewVisibility(R.id.stats_next, if (next != null) View.VISIBLE else View.GONE)
                if (next != null) {
                    setTextViewText(
                        R.id.stats_next,
                        "Next: ${next.optString("subject")} · ${next.optString("when")}",
                    )
                }

                val openStats = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("zeolite://open?tab=stats"),
                )
                setOnClickPendingIntent(R.id.stats_root, openStats)
                // The list swallows taps that land on it, so the rows need the
                // same destination handed to them as a template.
                setPendingIntentTemplate(R.id.stats_rows, openStats)

                setRemoteAdapter(R.id.stats_rows, rowsIntent(context, widgetId))
                setEmptyView(R.id.stats_rows, R.id.stats_empty)
                if (count == 0) setTextViewText(R.id.stats_empty, "No data yet")
            }
            appWidgetManager.updateAppWidget(widgetId, views)
            // The adapter is bound once; this is what makes it re-read after a
            // push, and without it the list keeps yesterday's rows.
            appWidgetManager.notifyAppWidgetViewDataChanged(widgetId, R.id.stats_rows)
        }
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
