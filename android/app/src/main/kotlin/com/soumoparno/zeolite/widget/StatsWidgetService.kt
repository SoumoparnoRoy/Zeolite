package com.soumoparno.zeolite.widget

import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.soumoparno.zeolite.R
import org.json.JSONObject

/**
 * Feeds the stats widget's list.
 *
 * A collection rather than rows pushed into a LinearLayout: pushed rows cannot
 * scroll, so the list had to be cut to whatever the cell held and the rest
 * summarised as "N more subjects" — which is the one thing a subject in trouble
 * must not be.
 */
class StatsWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        StatsRowFactory(applicationContext)
}

class StatsRowFactory(private val context: Context) :
    RemoteViewsService.RemoteViewsFactory {

    private var subjects: List<JSONObject> = emptyList()
    private var theme: WidgetTheme = WidgetTheme.of(context)

    override fun onCreate() = reload()

    /** Called by the launcher after every push, so this is where the data lands. */
    override fun onDataSetChanged() = reload()

    private fun reload() {
        theme = WidgetTheme.of(context)
        val array = WidgetData.read(context, "subjects")?.optJSONArray("subjects")
        subjects = (0 until (array?.length() ?: 0)).map { array!!.getJSONObject(it) }
    }

    override fun onDestroy() {
        subjects = emptyList()
    }

    override fun getCount(): Int = subjects.size

    override fun getViewAt(position: Int): RemoteViews {
        val subject = subjects[position]
        val hasData = subject.optBoolean("hasData")
        val tint = health(theme, subject.optString("health"))

        return RemoteViews(context.packageName, R.layout.widget_stats_row).apply {
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

            // A row in a collection cannot carry its own intent, so it fills in
            // the list's template instead. Empty: every row wants the same
            // screen, and the template already names it.
            setOnClickFillInIntent(R.id.stat_row, Intent())
        }
    }

    /** Blank rather than Android's own "Loading…" — see [TodayRowFactory]. */
    override fun getLoadingView(): RemoteViews =
        RemoteViews(context.packageName, R.layout.widget_stats_row).apply {
            setInt(R.id.stat_stripe, "setBackgroundColor", theme.canvas)
            setTextViewText(R.id.stat_name, "")
            setTextViewText(R.id.stat_counts, "")
            setTextViewText(R.id.stat_percent, "")
            setViewVisibility(R.id.stat_headline, View.GONE)
        }

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = true

    private fun health(theme: WidgetTheme, name: String): Int = when (name) {
        "safe" -> theme.present
        "tight" -> theme.warning
        "atRisk", "lost" -> theme.absent
        else -> theme.textTertiary
    }
}
