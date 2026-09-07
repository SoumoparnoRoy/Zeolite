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
 * Every row is a slot already in the selected layout, filled by setters.
 * Nothing here adds, removes, or initially hides a row: the launcher paints
 * the inflated layout before it applies the RemoteViews actions, so the XML
 * must already have the same row structure as the final widget.
 *
 * A collection would scroll, but it also rebinds on updates and has previously
 * left a tapped row showing stale status. It cannot prevent the launcher from
 * re-inflating the widget when the process starts, so reliable marking takes
 * precedence here.
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
            val fits = WidgetScale.rowsThatFit(options, PADDING_DP, ROW_DP)
            val shown = minOf(count, fits, SLOTS.size)

            val views = RemoteViews(context.packageName, layoutFor(shown)).apply {
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

                SLOTS.take(shown).forEachIndexed { index, slot ->
                    fill(context, theme, slot, classes!!.getJSONObject(index), widgetId, index)
                }
                more(context, theme, count - shown)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun RemoteViews.fill(
        context: Context,
        theme: WidgetTheme,
        slot: Slot,
        session: JSONObject,
        widgetId: Int,
        index: Int,
    ) {
        val status = session.optString("status")
            .takeIf { it.isNotBlank() && it != "null" }
        val room = session.optString("room").takeIf { it.isNotBlank() && it != "null" }

        setInt(slot.stripe, "setBackgroundColor", session.optInt("color", theme.accent))
        setTextColor(slot.subject, theme.textPrimary)
        setTextColor(slot.meta, theme.textSecondary)

        setTextViewText(slot.subject, session.optString("subject"))
        setTextViewText(
            slot.meta,
            listOfNotNull(
                session.optString("time").takeIf { it.isNotBlank() },
                room,
            ).joinToString("  ·  "),
        )

        // The same three the class card offers, in the same order, so a status
        // set here can be corrected or cleared here too.
        slot.buttons.forEachIndexed { position, (id, name) ->
            paint(id, status == name, colourFor(theme, name), theme)
            setOnClickPendingIntent(
                id,
                mark(context, session, name, widgetId, index * slot.buttons.size + position),
            )
        }
    }

    private fun RemoteViews.more(context: Context, theme: WidgetTheme, hidden: Int) {
        setViewVisibility(R.id.more_label, if (hidden > 0) View.VISIBLE else View.GONE)
        if (hidden <= 0) return
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

    /**
     * Filled to the status colour when set, quiet when not. Quiet is [surface]
     * rather than [surfaceHigh] because the rows are transparent: the button
     * has only the canvas behind it, and in the light palette surfaceHigh is
     * near enough to it that the square disappears.
     */
    private fun RemoteViews.paint(id: Int, on: Boolean, colour: Int, theme: WidgetTheme) {
        setTintedBackground(id, if (on) theme.dim(colour, 46) else theme.surface)
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

    private fun layoutFor(rows: Int): Int = when (rows) {
        0 -> R.layout.widget_today_0
        1 -> R.layout.widget_today_1
        2 -> R.layout.widget_today_2
        3 -> R.layout.widget_today_3
        4 -> R.layout.widget_today
        5 -> R.layout.widget_today_5
        6 -> R.layout.widget_today_6
        else -> R.layout.widget_today_7
    }

    private class Slot(
        val card: Int,
        val stripe: Int,
        val subject: Int,
        val meta: Int,
        present: Int,
        absent: Int,
        cancelled: Int,
    ) {
        val buttons = listOf(
            present to "present",
            absent to "absent",
            cancelled to "cancelled",
        )
    }

    private companion object {
        val SLOTS = listOf(
            Slot(
                R.id.row0_card, R.id.row0_stripe, R.id.row0_subject, R.id.row0_meta,
                R.id.row0_present, R.id.row0_absent, R.id.row0_cancelled,
            ),
            Slot(
                R.id.row1_card, R.id.row1_stripe, R.id.row1_subject, R.id.row1_meta,
                R.id.row1_present, R.id.row1_absent, R.id.row1_cancelled,
            ),
            Slot(
                R.id.row2_card, R.id.row2_stripe, R.id.row2_subject, R.id.row2_meta,
                R.id.row2_present, R.id.row2_absent, R.id.row2_cancelled,
            ),
            Slot(
                R.id.row3_card, R.id.row3_stripe, R.id.row3_subject, R.id.row3_meta,
                R.id.row3_present, R.id.row3_absent, R.id.row3_cancelled,
            ),
            Slot(
                R.id.row4_card, R.id.row4_stripe, R.id.row4_subject, R.id.row4_meta,
                R.id.row4_present, R.id.row4_absent, R.id.row4_cancelled,
            ),
            Slot(
                R.id.row5_card, R.id.row5_stripe, R.id.row5_subject, R.id.row5_meta,
                R.id.row5_present, R.id.row5_absent, R.id.row5_cancelled,
            ),
            Slot(
                R.id.row6_card, R.id.row6_stripe, R.id.row6_subject, R.id.row6_meta,
                R.id.row6_present, R.id.row6_absent, R.id.row6_cancelled,
            ),
        )

        const val BACKGROUND_ACTION = "es.antonborri.home_widget.action.BACKGROUND"

        /** The root's own padding, top and bottom. */
        const val PADDING_DP = 24f

        /** A row: two lines of text beside a 40dp button, plus its margin. */
        const val ROW_DP = 54f
    }
}
