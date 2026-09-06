package com.soumoparno.zeolite.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import com.soumoparno.zeolite.MainActivity
import com.soumoparno.zeolite.R
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/**
 * The week as the app draws it — a picture rendered by Flutter rather than a
 * grid rebuilt here, so the two can never end up looking like different
 * products. Taps land on a day, which is as fine as an image allows.
 */
class WeekWidgetProvider : ZeoliteWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val theme = WidgetTheme.of(context)
        val week = WidgetData.read(context, "week")
        val monday = week?.optInt("monday") ?: 0
        val unmarked = week?.optJSONArray("unmarked")
        val image = WidgetData.raw(context, "weekImage")
            ?.let { BitmapFactory.decodeFile(it) }

        appWidgetIds.forEach { widgetId ->
            val options = appWidgetManager.getAppWidgetOptions(widgetId)
            val scale = WidgetScale.of(options, rows = 4, headerDp = 0f)

            // Dart cannot ask how big this widget is, so the box is written
            // here and read on the next render. The grid is then drawn at the
            // size it will be shown at rather than a guessed aspect, which is
            // what stops it being letterboxed inside itself.
            recordCell(context, options)

            val views = RemoteViews(context.packageName, R.layout.widget_week).apply {
                setScaledTextSize(R.id.week_placeholder, 13f, scale)

                setTintedBackground(R.id.week_root, theme.canvas)
                setTextColor(R.id.week_placeholder, theme.textTertiary)
                // On the root now the header has gone. The day columns sit
                // above it and keep their own taps.
                setOnClickPendingIntent(
                    R.id.week_root,
                    HomeWidgetLaunchIntent.getActivity(
                        context,
                        MainActivity::class.java,
                        Uri.parse("zeolite://open?tab=timetable"),
                    ),
                )

                // Absent until the app has been opened once since the widget
                // was placed: the render needs a view to draw into.
                setViewVisibility(R.id.week_image, if (image != null) View.VISIBLE else View.GONE)
                setViewVisibility(
                    R.id.week_placeholder,
                    if (image != null) View.GONE else View.VISIBLE,
                )
                if (image != null) setImageViewBitmap(R.id.week_image, image)

                DAY_COLUMNS.forEachIndexed { index, columnId ->
                    val pending = unmarked?.optInt(index, 0) ?: 0
                    setOnClickPendingIntent(
                        columnId,
                        HomeWidgetLaunchIntent.getActivity(
                            context,
                            MainActivity::class.java,
                            Uri.parse(
                                "zeolite://open?tab=timetable" +
                                    "&day=${monday + index}&pending=$pending",
                            ),
                        ),
                    )
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun recordCell(context: Context, options: android.os.Bundle?) {
        val width = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0) ?: 0
        val height = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0) ?: 0
        if (width <= 0 || height <= 0) return
        WidgetData.write(context, "weekCell", "${width}x$height")
    }

    private companion object {
        val DAY_COLUMNS = listOf(
            R.id.week_day_0, R.id.week_day_1, R.id.week_day_2, R.id.week_day_3,
            R.id.week_day_4, R.id.week_day_5, R.id.week_day_6,
        )
    }
}
