package com.sample.edgedetection.view

import android.content.Context
import android.graphics.*
import android.os.Build
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.widget.Magnifier
import com.sample.edgedetection.processor.*
import kotlin.math.*

/** Shared proportional overlay: dots during alignment, handles only when editing. */
class PaperRectangle @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val density = resources.displayMetrics.density
    private var points: List<ScanPoint>? = null
    private var imageWidth = 3.0
    private var imageHeight = 4.0
    private var moving = -1
    private var magnifier: Magnifier? = null
    var editing = false
        set(value) { field = value; moving = -1; magnifier?.dismiss(); invalidate() }
    var magnifierSource: View? = null

    fun setImageSize(width: Int, height: Int) { imageWidth = width.toDouble(); imageHeight = height.toDouble(); invalidate() }
    fun setPoints(value: List<ScanPoint>?) { points = value?.toList(); invalidate() }
    fun getPoints(): List<ScanPoint> = points?.toList() ?: ScanGeometry.fullImage

    private fun imageRect(): RectF {
        val scale = min(width / imageWidth, height / imageHeight)
        val w = (imageWidth * scale).toFloat(); val h = (imageHeight * scale).toFloat()
        return RectF((width - w) / 2, (height - h) / 2, (width + w) / 2, (height + h) / 2)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val corners = points ?: return
        val rect = imageRect()
        val screen = corners.map { PointF(rect.left + it.x.toFloat() * rect.width(), rect.top + it.y.toFloat() * rect.height()) }
        if (editing) {
            val path = Path().apply { moveTo(screen[0].x, screen[0].y); screen.drop(1).forEach { lineTo(it.x, it.y) }; close() }
            paint.style = Paint.Style.STROKE; paint.color = Color.WHITE; paint.strokeWidth = 1.5f * density
            canvas.drawPath(path, paint)
        }
        screen.forEach {
            paint.style = Paint.Style.FILL; paint.color = Color.WHITE
            canvas.drawCircle(it.x, it.y, (if (editing) 9f else 4f) * density, paint)
            paint.style = Paint.Style.STROKE; paint.color = Color.DKGRAY; paint.strokeWidth = density
            canvas.drawCircle(it.x, it.y, (if (editing) 9f else 4f) * density, paint)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!editing) return false
        val rect = imageRect()
        if (rect.width() <= 0 || rect.height() <= 0) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val corners = getPoints()
                moving = corners.indices.minByOrNull { hypot(rect.left + corners[it].x * rect.width() - event.x,
                    rect.top + corners[it].y * rect.height() - event.y) } ?: -1
                if (moving < 0 || hypot(rect.left + corners[moving].x * rect.width() - event.x,
                        rect.top + corners[moving].y * rect.height() - event.y) > 36 * density) { moving = -1; return false }
                parent.requestDisallowInterceptTouchEvent(true)
                if (Build.VERSION.SDK_INT >= 28) magnifier = magnifierSource?.let { Magnifier(it) }
            }
            MotionEvent.ACTION_MOVE -> {
                if (moving < 0) return false
                val next = getPoints().toMutableList()
                next[moving] = ScanPoint(((event.x - rect.left) / rect.width()).toDouble().coerceIn(0.0, 1.0),
                    ((event.y - rect.top) / rect.height()).toDouble().coerceIn(0.0, 1.0))
                if (ScanGeometry.isValid(next)) { points = next; invalidate() }
                if (Build.VERSION.SDK_INT >= 28) magnifier?.show(event.x.coerceIn(rect.left, rect.right), event.y.coerceIn(rect.top, rect.bottom))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                moving = -1; if (Build.VERSION.SDK_INT >= 28) magnifier?.dismiss()
                magnifier = null; parent.requestDisallowInterceptTouchEvent(false); performClick()
            }
        }
        return true
    }

    override fun performClick(): Boolean { super.performClick(); return true }
    override fun onDetachedFromWindow() { if (Build.VERSION.SDK_INT >= 28) magnifier?.dismiss(); super.onDetachedFromWindow() }
}
