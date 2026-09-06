package com.soumoparno.zeolite.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import com.soumoparno.zeolite.MainActivity
import com.soumoparno.zeolite.R
import es.antonborri.home_widget.HomeWidgetBackgroundReceiver
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import org.json.JSONObject

/**
 * Today's classes, each markable without opening the app.
 *
 * The rows are built into the RemoteViews rather than served by a
 * RemoteViewsService. A collection re-attaches its adapter on every update and
 * the launcher paints its loading view while it does, which blinks the list on
 * every mark — tried twice, reverted twice. The price is a fixed number of
 * rows.
 */
class TodayWidgetProvider : ZeoliteWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val theme = WidgetTheme.of(context)
        val today = WidgetData.read(context, "today")
        val state = today?.optString("state") ?: "empty"
        val classes = today?.optJSONArray("classes")
        val count = if (state == "classes") (classes?.length() ?: 0) else 0

        appWidgetIds.forEach { widgetId ->
            val options = appWidgetManager.getAppWidgetOptions(widgetId)
            val shown = minOf(count, WidgetScale.rowsThatFit(options, PADDING_DP, ROW_DP))

            val views = RemoteViews(context.packageName, R.layout.widget_today).apply {
                setTintedBackground(R.id.today_root, theme.canvas)
                setTextColor(R.id.today_empty, theme.textTertiary)

                setOnClickPendingIntent(
                    R.id.today_root,
                    HomeWidgetLaunchIntent.getActivity(
                        context,
                        MainActivity::class.java,
                        Uri.parse("zeolite://open?tab=today"),
                    ),
                )

                setViewVisibility(R.id.today_rows, if (count > 0) View.VISIBLE else View.GONE)
                setViewVisibility(R.id.today_empty, if (count > 0) View.GONE else View.VISIBLE)
                if (count == 0) {
                    setTextViewText(
                        R.id.today_empty,
                        emptyMessage(state, today?.optString("holiday")),
                    )
                }

                removeAllViews(R.id.today_rows)
                for (index in 0 until shown) {
                    addView(
                        R.id.today_rows,
                        row(context, theme, classes!!.getJSONObject(index), widgetId, index),
                    )
                }
                if (count > shown) {
                    addView(R.id.today_rows, moreRow(context, theme, count - shown))
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun row(
        context: Context,
        theme: WidgetTheme,
        session: JSONObject,
        widgetId: Int,
        index: Int,
    ): RemoteViews {
        val status = session.optString("status")
            .takeIf { it.isNotBlank() && it != "null" }
        val room = session.optString("room").takeIf { it.isNotBlank() && it != "null" }

        return RemoteViews(context.packageName, R.layout.widget_today_row).apply {
            setInt(R.id.row_card, "setBackgroundColor", theme.surface)
            setInt(R.id.row_stripe, "setBackgroundColor", session.optInt("color", theme.accent))
            setTextColor(R.id.row_subject, theme.textPrimary)
            setTextColor(R.id.row_meta, theme.textSecondary)

            setTextViewText(R.id.row_subject, session.optString("subject"))
            setTextViewText(
                R.id.row_meta,
                listOfNotNull(
                    session.optString("time").takeIf { it.isNotBlank() },
                    room,
                ).joinToString("  ·  "),
            )

            // The same three the class card offers, in the same order, so a
            // status set here can be corrected or cleared here too.
            STATUSES.forEachIndexed { slot, (id, name) ->
                paint(id, status == name, colourFor(theme, name), theme)
                setOnClickPendingIntent(
                    id,
                    mark(context, session, name, widgetId, index * STATUSES.size + slot),
                )
            }
        }
    }

    private fun moreRow(context: Context, theme: WidgetTheme, hidden: Int): RemoteViews =
        RemoteViews(context.packageName, R.layout.widget_today_more).apply {
            setTextColor(R.id.more_label, theme.textTertiary)
            setTextViewText(
                R.id.more_label,
                if (hidden == 1) "1 more class" else "$hidden more classes",
            )
            setOnClickPendingIntent(
                R.id.more_label,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("zeolite://open?tab=today"),
                ),
            )
        }

    /** Filled to the status colour when set, quiet when not. */
    private fun RemoteViews.paint(id: Int, on: Boolean, colour: Int, theme: WidgetTheme) {
        setTintedBackground(id, if (on) theme.dim(colour, 46) else theme.surfaceHigh)
        setTextColor(id, if (on) colour else theme.textSecondary)
    }

    private fun colourFor(theme: WidgetTheme, status: String): Int = when (status) {
        "present" -> theme.present
        "absent" -> theme.absent
        else -> theme.cancelled
    }

    /**
     * Wakes the background isolate. The request code has to be unique per
     * button, or every row is handed the first one's intent.
     */
    private fun mark(
        context: Context,
        session: JSONObject,
        status: String,
        widgetId: Int,
        slot: Int,
    ): PendingIntent {
        val uri = Uri.Builder()
            .scheme("zeolite")
            .authority("mark")
            .appendQueryParameter("subject", session.optInt("subjectId").toString())
            .appendQueryParameter("date", session.optInt("date").toString())
            .appendQueryParameter("start", session.optInt("startMinutes").toString())
            .appendQueryParameter("status", status)
            .build()

        val intent = Intent(context, HomeWidgetBackgroundReceiver::class.java).apply {
            action = BACKGROUND_ACTION
            data = uri
        }
        return PendingIntent.getBroadcast(
            context,
            widgetId * 100 + slot,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun emptyMessage(state: String, holiday: String?): String = when (state) {
        "holiday" -> holiday?.takeIf { it.isNotBlank() && it != "null" } ?: "Holiday"
        "outside" -> "Outside the term"
        else -> "Nothing on today"
    }

    private companion object {
        val STATUSES = listOf(
            R.id.row_present to "present",
            R.id.row_absent to "absent",
            R.id.row_cancelled to "cancelled",
        )

        const val BACKGROUND_ACTION = "es.antonborri.home_widget.action.BACKGROUND"

        /** The root's own padding, top and bottom. */
        const val PADDING_DP = 24f

        /** A row: two lines of text beside a 40dp button, plus its margin. */
        const val ROW_DP = 54f
    }
}
