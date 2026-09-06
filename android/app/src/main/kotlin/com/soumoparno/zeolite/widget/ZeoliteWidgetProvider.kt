package com.soumoparno.zeolite.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.res.ColorStateList
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider
import kotlin.math.min

/**
 * A widget that redraws when it is resized. Android reports a resize here and
 * never through onUpdate, so without this one keeps the size it was first drawn
 * at.
 */
abstract class ZeoliteWidgetProvider : HomeWidgetProvider() {

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        onUpdate(context, appWidgetManager, intArrayOf(appWidgetId))
    }
}

/**
 * How much bigger than the drawn-for size a widget should render. A widget is
 * given a cell, not a screen, so the type follows the cell and how many rows
 * share it rather than a breakpoint.
 */
object WidgetScale {

    /** The smallest cell offered, which the layouts are drawn against. */
    private const val BASE_WIDTH_DP = 250f
    private const val BASE_ROW_DP = 40f

    private const val MAX = 2.1f

    /** What a cell shows before Android has said how big it is. */
    private const val DEFAULT_ROWS = 4

    /**
     * How many rows of [rowDp] the cell has room for, once [reservedDp] is
     * spent. The Today widget builds its rows in, so it has to know when to
     * stop rather than letting the last one be clipped.
     */
    fun rowsThatFit(options: Bundle?, reservedDp: Float = 0f, rowDp: Float = BASE_ROW_DP): Int {
        val heightDp = options
            ?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
            ?.takeIf { it > 0 }?.toFloat() ?: return DEFAULT_ROWS
        return ((heightDp - reservedDp) / rowDp).toInt().coerceAtLeast(1)
    }

    /** The narrower dimension wins, or a short wide cell sets type it cannot fit. */
    fun of(options: Bundle?, rows: Int, headerDp: Float = 34f): Float =
        min(vertical(options, rows, headerDp), horizontal(options)).coerceIn(1f, MAX)

    private fun vertical(options: Bundle?, rows: Int, headerDp: Float): Float {
        // Portrait is minWidth by maxHeight; the app is portrait-locked, so the
        // landscape pair is not worth reading.
        val heightDp = options
            ?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
            ?.takeIf { it > 0 }?.toFloat() ?: (BASE_ROW_DP * rows + headerDp)
        return (heightDp - headerDp) / maxOf(rows, 1) / BASE_ROW_DP
    }

    private fun horizontal(options: Bundle?): Float {
        val widthDp = options
            ?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
            ?.takeIf { it > 0 }?.toFloat() ?: BASE_WIDTH_DP
        return widthDp / BASE_WIDTH_DP
    }
}

fun RemoteViews.setScaledTextSize(viewId: Int, sp: Float, scale: Float) {
    setTextViewTextSize(viewId, TypedValue.COMPLEX_UNIT_SP, sp * scale)
}

/**
 * Colours a rounded background without flattening it.
 *
 * These colours are pushed from Dart rather than read from the system, so they
 * cannot sit in the drawable; and setting a background colour the plain way
 * replaces the drawable and squares the corners again. Tinting keeps both, but
 * only from S — below that the corners stay square rather than the colour
 * going wrong.
 */
fun RemoteViews.setTintedBackground(viewId: Int, color: Int) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        setColorStateList(viewId, "setBackgroundTintList", ColorStateList.valueOf(color))
    } else {
        setInt(viewId, "setBackgroundColor", color)
    }
}
