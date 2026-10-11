package com.soumoparno.zeolite.widget

import android.app.PendingIntent
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
 * Today's classes, each markable without opening the app.
 *
 * From Android 12 the rows are a scrolling list whose items travel inside the
 * update itself ([RemoteViews.RemoteCollectionItems]). The earlier list went
 * through a RemoteViewsService: every update re-attached its adapter, which
 * blinked through a loading view, and a refresh sent while the views were not
 * inflated was dropped, leaving a tapped row on its old status. Inline items
 * have no adapter and no second refresh, so neither can happen.
 *
 * Below 12 there are no inline items, so the rows are slots already in the
 * selected layout, filled by setters. Nothing there adds, removes, or
 * initially hides a row: the launcher paints the inflated layout before it
 * applies the RemoteViews actions, so the XML must already have the same row
 * structure as the final widget. That path cannot scroll, so it shows what
 * fits and counts the rest.
 */
class TodayWidgetProvider : ZeoliteWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val theme = WidgetTheme.of(context)
        val today = WidgetData.today(WidgetData.read(context, "today"))
        val state = today?.optString("state") ?: "stale"
        val classes = today?.optJSONArray("classes")
        val count = if (state == "classes") (classes?.length() ?: 0) else 0
        val pending = WidgetData.pendingMarks(context)

        appWidgetIds.forEach { widgetId ->
            val options = appWidgetManager.getAppWidgetOptions(widgetId)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                appWidgetManager.updateAppWidget(
                    widgetId,
                    // Both row layouts, and the launcher shows whichever fits the
                    // cell as it stands. Choosing here from a reported width read
                    // the portrait figure, wrong on a landscape home screen.
                    RemoteViews(
                        mapOf(
                            SizeF(0f, 0f) to list(
                                context, theme, state, today, classes, count, pending,
                                widgetId, R.layout.widget_today_item_narrow,
                            ),
                            SizeF(NARROW_DP, 0f) to list(
                                context, theme, state, today, classes, count, pending,
                                widgetId, R.layout.widget_today_item,
                            ),
                        ),
                    ),
                )
                return@forEach
            }
            val fits = WidgetScale.rowsThatFit(options, PADDING_DP, ROW_DP)
            val shown = minOf(count, fits, SLOTS.size)

            val views = RemoteViews(context.packageName, layoutFor(shown)).apply {
                setTintedBackground(R.id.today_root, theme.canvas)
                setTextColor(R.id.today_empty, theme.textTertiary)

                setOnClickPendingIntent(R.id.today_root, openToday(context))

                setViewVisibility(R.id.today_rows, if (count > 0) View.VISIBLE else View.GONE)
                setViewVisibility(R.id.today_empty, if (count > 0) View.GONE else View.VISIBLE)
                if (count == 0) {
                    setTextViewText(
                        R.id.today_empty,
                        emptyMessage(state, today?.optString("holiday")),
                    )
                }

                SLOTS.take(shown).forEachIndexed { index, slot ->
                    fill(theme, slot, classes!!.getJSONObject(index), pending) { id, uri, position ->
                        setOnClickPendingIntent(
                            id,
                            mark(context, uri, widgetId * 100 + index * slot.buttons.size + position),
                        )
                    }
                }
                more(context, theme, count - shown)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun list(
        context: Context,
        theme: WidgetTheme,
        state: String,
        today: JSONObject?,
        classes: JSONArray?,
        count: Int,
        pending: Map<String, String>,
        widgetId: Int,
        itemLayout: Int,
    ): RemoteViews {
        val items = RemoteViews.RemoteCollectionItems.Builder()
            .setHasStableIds(true)
            // Both row layouts, so a cell crossing the narrow line does not
            // change the count under a list that is already showing.
            .setViewTypeCount(2)
        for (index in 0 until count) {
            val session = classes!!.getJSONObject(index)
            val row = RemoteViews(context.packageName, itemLayout).apply {
                fill(theme, ITEM, session, pending) { id, uri, _ ->
                    setOnClickFillInIntent(id, Intent().setData(uri))
                }
            }
            items.addItem(itemId(session), row)
        }

        return RemoteViews(context.packageName, R.layout.widget_today_list).apply {
            setTintedBackground(R.id.today_root, theme.canvas)
            setTextColor(R.id.today_empty, theme.textTertiary)
            setOnClickPendingIntent(R.id.today_root, openToday(context))

            // A view inside a list cannot hold its own PendingIntent: the list
            // holds one, and each button fills in the mark it stands for.
            // Mutable, or the fill-in is ignored.
            setPendingIntentTemplate(
                R.id.today_list,
                PendingIntent.getBroadcast(
                    context,
                    widgetId * 100 + TEMPLATE_CODE,
                    Intent(context, WidgetMarkReceiver::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                ),
            )
            setRemoteAdapter(R.id.today_list, items.build())
            setEmptyView(R.id.today_list, R.id.today_empty)
            if (count == 0) {
                setTextViewText(R.id.today_empty, emptyMessage(state, today?.optString("holiday")))
            }
        }
    }

    private fun itemId(session: JSONObject): Long = keyOf(session).hashCode().toLong()

    private fun keyOf(session: JSONObject) = WidgetData.markKey(
        session.optInt("subjectId"),
        session.optInt("date"),
        session.optInt("startMinutes"),
    )

    private fun openToday(context: Context): PendingIntent = HomeWidgetLaunchIntent.getActivity(
        context,
        MainActivity::class.java,
        Uri.parse("zeolite://open?tab=today"),
    )

    /**
     * Fills one row and hands each button's mark to [onMark], which knows
     * whether this row can hold its own PendingIntent or has to fill in the
     * list's.
     */
    private fun RemoteViews.fill(
        theme: WidgetTheme,
        slot: Slot,
        session: JSONObject,
        pending: Map<String, String>,
        onMark: RemoteViews.(id: Int, uri: Uri, position: Int) -> Unit,
    ) {
        // A tap drawn ahead of Dart wins until Dart saves it and pushes.
        val drawn = pending[keyOf(session)]
        val status = if (drawn != null) {
            drawn.takeIf { it.isNotEmpty() }
        } else {
            session.optString("status").takeIf { it.isNotBlank() && it != "null" }
        }
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
            onMark(id, markUri(session, name), position)
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
        setOnClickPendingIntent(R.id.more_label, openToday(context))
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

    private fun markUri(session: JSONObject, status: String): Uri = Uri.Builder()
        .scheme("zeolite")
        .authority("mark")
        .appendQueryParameter("subject", session.optInt("subjectId").toString())
        .appendQueryParameter("date", session.optInt("date").toString())
        .appendQueryParameter("start", session.optInt("startMinutes").toString())
        .appendQueryParameter("status", status)
        .build()

    /**
     * Lands on [WidgetMarkReceiver]. The request code has to be unique per
     * button, or every row is handed the first one's intent.
     */
    private fun mark(context: Context, uri: Uri, requestCode: Int): PendingIntent {
        val intent = Intent(context, WidgetMarkReceiver::class.java).setData(uri)
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun emptyMessage(state: String, holiday: String?): String = when (state) {
        "holiday" -> holiday?.takeIf { it.isNotBlank() && it != "null" } ?: "Holiday"
        "outside" -> "Outside the term"
        "stale" -> "Open Zeolite to see today"
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
        /** A list row's views: every row uses the same ids. */
        val ITEM = Slot(
            R.id.item_card, R.id.item_stripe, R.id.item_subject, R.id.item_meta,
            R.id.item_present, R.id.item_absent, R.id.item_cancelled,
        )

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

        /** Clear of the fixed rows' codes, which stop at 7 rows x 3 buttons. */
        const val TEMPLATE_CODE = 99

        /** Narrower than this, three 40dp buttons leave a subject no room. */
        const val NARROW_DP = 260f

        /** The root's own padding, top and bottom. */
        const val PADDING_DP = 24f

        /** A row: two lines of text beside a 40dp button, plus its margin. */
        const val ROW_DP = 54f
    }
}
