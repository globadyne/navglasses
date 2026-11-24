package com.tzglasses.hud.render

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import com.tzglasses.hud.core.HudFrame
import com.tzglasses.hud.core.ItemKind
import com.tzglasses.hud.core.Severity
import kotlin.math.abs

/**
 * Draws a HudFrame as a 600 × 600 picture for the lens (port of HUDImageRenderer.swift). On the
 * waveguide black is see-through, so everything not drawn shows the real world. Also used for
 * the phone preview.
 */
object HudBitmapRenderer {
  const val SIZE = 600

  private val HUD = Color.rgb(143, 240, 199)
  private val HUD_DIM = Color.argb(153, 143, 240, 199)
  private val AMBER = Color.rgb(255, 194, 102)
  private val RED = Color.rgb(255, 125, 110)
  /** Radar (ARPA) targets, so they read differently from AIS ones. */
  private val ARPA = Color.rgb(255, 179, 92)

  private val mono = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
  private val monoBold = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
  private val condensed = Typeface.create("sans-serif-condensed", Typeface.BOLD)

  private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3f }

  private fun color(s: Severity) = when (s) {
    Severity.NORMAL -> HUD
    Severity.CAUTION -> AMBER
    Severity.DANGER -> RED
  }

  fun render(f: HudFrame): Bitmap {
    val bmp = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    c.drawColor(Color.BLACK)
    draw(f, c)
    return bmp
  }

  private enum class Align { LEFT, CENTER, RIGHT }

  /** Draws text with its top at y (like UIKit's draw(at:)). Centred text is kept inside the lens. */
  private fun text(c: Canvas, s: String, x: Float, y: Float, size: Float, face: Typeface, col: Int,
                   align: Align = Align.LEFT) {
    textPaint.typeface = face
    textPaint.textSize = size
    textPaint.color = col
    val w = textPaint.measureText(s)
    val left = when (align) {
      Align.LEFT -> x
      Align.RIGHT -> x - w
      Align.CENTER -> (x - w / 2).coerceIn(8f, SIZE - 8f - w)
    }
    c.drawText(s, left, y - textPaint.ascent(), textPaint)
  }

  private fun draw(f: HudFrame, c: Canvas) {
    val w = SIZE.toFloat()
    val h = SIZE.toFloat()

    text(c, f.headingText, 24f, 20f, 28f, mono, HUD)
    text(c, f.speedText, w - 24, 20f, 28f, mono, HUD, Align.RIGHT)
    text(c, f.gazeText, w / 2, 58f, 24f, mono, HUD_DIM, Align.CENTER)
    if (f.stale) text(c, "NO DATA", w / 2, 20f, 24f, monoBold, AMBER, Align.CENTER)
    f.message?.let { text(c, it, w / 2, h / 2 - 16, 30f, condensed, HUD, Align.CENTER) }

    // Waypoints on the horizon line; vessels, buoys and marks below, nearer things lower.
    // Labels that would overlap step down a row.
    val horizon = 250f
    val placed = ArrayList<RectF>()
    for (item in f.items.sortedBy { it.x }) {
      val x = (item.x * w).toFloat()
      val col = if (item.severity == Severity.NORMAL && item.source == "ARPA") ARPA else color(item.severity)
      var y = if (item.kind == ItemKind.WAYPOINT) horizon
      else horizon + 40 + (1 - item.rangeNm / 4).coerceIn(0.0, 1.0).toFloat() * 150
      val box = RectF(x - 120, y - 78, x + 120, y + 22)
      while (placed.any { RectF.intersects(it, box) } && box.bottom < h - 110) {
        box.offset(0f, 70f); y += 70
      }
      placed += box

      stroke.color = col
      when (item.kind) {
        ItemKind.WAYPOINT -> {
          val d = 14f
          c.drawPath(Path().apply { moveTo(x, y - d); lineTo(x + d, y); lineTo(x, y + d); lineTo(x - d, y); close() }, stroke)
        }
        ItemKind.ATON, ItemKind.MARK -> c.drawCircle(x, y, 10f, stroke)
        ItemKind.VESSEL -> {
          // Corner brackets around where the ship sits.
          val bw = 34f; val bh = 22f; val k = 12f
          for ((px, py, sx, sy) in listOf(
              floatArrayOf(x - bw, y - bh, 1f, 1f), floatArrayOf(x + bw, y - bh, -1f, 1f),
              floatArrayOf(x - bw, y + bh, 1f, -1f), floatArrayOf(x + bw, y + bh, -1f, -1f))) {
            c.drawPath(Path().apply { moveTo(px + sx * k, py); lineTo(px, py); lineTo(px, py + sy * k) }, stroke)
          }
        }
      }
      text(c, item.title, x, y - 74, 28f, condensed, col, Align.CENTER)
      text(c, item.detail, x, y - 42, 20f, mono, col, Align.CENTER)
    }

    // Edge cues for things out of view, under the top strip.
    var leftY = 96f
    var rightY = 96f
    for (e in f.edges) {
      val col = color(e.severity)
      if (e.turnDeg < 0) {
        text(c, "‹ ${e.label} ${abs(e.turnDeg)}°", 16f, leftY, 20f, mono, col); leftY += 30
      } else {
        text(c, "${e.label} ${e.turnDeg}° ›", w - 16, rightY, 20f, mono, col, Align.RIGHT); rightY += 30
      }
    }

    // Bottom: alarm banner, else route or depth.
    val alarm = f.alarmTitle
    if (alarm != null) {
      val box = RectF(20f, h - 104, w - 20, h - 20)
      stroke.color = RED
      c.drawRect(box, stroke)
      text(c, alarm, w / 2, box.top + 10, 30f, condensed, RED, Align.CENTER)
      text(c, (f.alarmDetail ?: "") + " · TAP TO ACK", w / 2, box.top + 48, 19f, mono, RED, Align.CENTER)
    } else {
      f.footer?.let { text(c, it, 24f, h - 52, 22f, mono, HUD_DIM) }
    }
  }
}
