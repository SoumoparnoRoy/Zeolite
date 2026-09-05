package com.soumoparno.zeolite.widget

import android.appwidget.AppWidgetManager
import android.content.Context
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
    private const val BASE_ROW_DP = 46f

    private const val MAX = 2.1f

    private const val MAX_HEADLINE = 3.2f

    /** The narrower dimension wins, or a short wide cell sets type it cannot fit. */
    fun of(options: Bundle?, rows: Int, headerDp: Float = 34f): Float =
        min(vertical(options, rows, headerDp), horizontal(options)).coerceIn(1f, MAX)

    /**
     * For a figure short enough to follow the height alone, where the sentence
     * beside it is what the width has to hold. Still bounded by the width, or a
     * tall narrow cell sets a number wider than the widget.
     */
    fun headline(options: Bundle?, headerDp: Float = 34f): Float =
        min(vertical(options, 1, headerDp), horizontal(options) * 2f)
            .coerceIn(1f, MAX_HEADLINE)

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

fun RemoteViews.setScaledPadding(
    context: Context,
    viewId: Int,
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    scale: Float,
) {
    fun px(dp: Float) = (dp * scale * context.resources.displayMetrics.density).toInt()
    setViewPadding(viewId, px(left), px(top), px(right), px(bottom))
}
