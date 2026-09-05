package com.soumoparno.zeolite.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import com.soumoparno.zeolite.MainActivity
import com.soumoparno.zeolite.R
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import org.json.JSONObject

/**
 * Where you stand overall, and then each subject, weakest first.
 *
 * The two were separate widgets. They answer the same question at two zoom
 * levels and the overall figure is what the subjects add up to, so keeping them
 * apart meant placing both to see either properly.
 *
 * Rows are built into the RemoteViews for the same reason the Today widget's
 * are — see [TodayWidgetProvider].
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
        val subjects = payload?.optJSONArray("subjects")
        val count = subjects?.length() ?: 0

        val hasData = standing?.optBoolean("hasData") ?: false
        val meetsTarget = standing?.optBoolean("meetsTarget") ?: true
        val next = standing?.optJSONObject("next")

        appWidgetIds.forEach { widgetId ->
            val options = appWidgetManager.getAppWidgetOptions(widgetId)
            val shown = minOf(count, MAX_ROWS)
            // The summary counts as a row: it takes a row's worth of height,
            // and leaving it out of the sum set type the cell could not hold.
            val rows = maxOf(shown, 1) + 1
            val scale = WidgetScale.of(options, rows, headerDp = HEADER_DP)
            val figure = WidgetScale.headline(options, headerDp = HEADER_DP)

            val views = RemoteViews(context.packageName, R.layout.widget_stats).apply {
                setScaledTextSize(R.id.stats_title, 15f, scale)
                setScaledTextSize(R.id.stats_target, 12f, scale)
                setScaledTextSize(R.id.stats_percent, 28f, figure)
                setScaledTextSize(R.id.stats_verdict, 14f, scale)
                setScaledTextSize(R.id.stats_next, 11f, scale)
                setScaledTextSize(R.id.stats_empty, 13f, scale)
                setScaledPadding(context, R.id.stats_root, 12f, 12f, 12f, 12f, scale)

                setInt(R.id.stats_root, "setBackgroundColor", theme.canvas)
                setTextColor(R.id.stats_title, theme.textPrimary)
                setTextColor(R.id.stats_target, theme.textSecondary)
                setTextColor(R.id.stats_verdict, theme.textPrimary)
                setTextColor(R.id.stats_next, theme.textSecondary)
                setTextColor(R.id.stats_empty, theme.textTertiary)
                setTextColor(
                    R.id.stats_percent,
                    if (!hasData) theme.textTertiary
                    else if (meetsTarget) theme.present else theme.warning,
                )

                setTextViewText(R.id.stats_target, "Target ${payload?.optInt("target") ?: 75}%")
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

                setOnClickPendingIntent(
                    R.id.stats_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )

                setViewVisibility(R.id.stats_rows, if (count > 0) View.VISIBLE else View.GONE)
                setViewVisibility(R.id.stats_empty, if (count > 0) View.GONE else View.VISIBLE)
                if (count == 0) setTextViewText(R.id.stats_empty, "No data yet")

                removeAllViews(R.id.stats_rows)
                for (index in 0 until shown) {
                    addView(
                        R.id.stats_rows,
                        row(context, theme, subjects!!.getJSONObject(index), scale),
                    )
                }
                if (count > shown) {
                    addView(R.id.stats_rows, moreRow(context, theme, count - shown, scale))
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun row(
        context: Context,
        theme: WidgetTheme,
        subject: JSONObject,
        scale: Float,
    ): RemoteViews {
        val hasData = subject.optBoolean("hasData")
        val tint = health(theme, subject.optString("health"))

        return RemoteViews(context.packageName, R.layout.widget_stats_row).apply {
            setScaledTextSize(R.id.stat_name, 13f, scale)
            setScaledTextSize(R.id.stat_counts, 10f, scale)
            setScaledTextSize(R.id.stat_headline, 10f, scale)
            setScaledTextSize(R.id.stat_percent, 16f, scale)
            setScaledPadding(context, R.id.stat_text, 10f, 2f, 8f, 2f, scale)

            setInt(R.id.stat_stripe, "setBackgroundColor", subject.optInt("colour", theme.accent))
            setTextColor(R.id.stat_name, theme.textPrimary)
            setTextColor(R.id.stat_counts, theme.textTertiary)
            setTextColor(R.id.stat_percent, if (hasData) tint else theme.textTertiary)

            setTextViewText(R.id.stat_name, subject.optString("name"))
            setTextViewText(R.id.stat_counts, subject.optString("counts"))
            setTextViewText(
                R.id.stat_percent,
                if (hasData) "${subject.optInt("percent")}%" else "—",
            )

            // Calm by default: the colour is spent only on the subjects that
            // need attention, so a healthy column reads as one quiet grey.
            setViewVisibility(R.id.stat_headline, if (hasData) View.VISIBLE else View.GONE)
            if (hasData) {
                setTextViewText(R.id.stat_headline, subject.optString("headline"))
                setTextColor(
                    R.id.stat_headline,
                    if (subject.optBoolean("meetsTarget")) theme.textTertiary else tint,
                )
            }
        }
    }

    private fun moreRow(
        context: Context,
        theme: WidgetTheme,
        hidden: Int,
        scale: Float,
    ): RemoteViews =
        RemoteViews(context.packageName, R.layout.widget_today_more).apply {
            setScaledTextSize(R.id.more_label, 11f, scale)
            setTextColor(R.id.more_label, theme.textTertiary)
            setTextViewText(
                R.id.more_label,
                if (hidden == 1) "1 more subject" else "$hidden more subjects",
            )
        }

    private fun health(theme: WidgetTheme, name: String): Int = when (name) {
        "safe" -> theme.present
        "tight" -> theme.warning
        "atRisk", "lost" -> theme.absent
        else -> theme.textTertiary
    }

    private companion object {
        const val HEADER_DP = 38f

        /** What fits before the rows start being squeezed. */
        const val MAX_ROWS = 4
    }
}
