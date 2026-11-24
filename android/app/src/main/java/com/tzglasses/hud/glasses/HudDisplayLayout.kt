package com.tzglasses.hud.glasses

import android.graphics.Bitmap
import com.meta.wearable.dat.display.views.Alignment
import com.meta.wearable.dat.display.views.ContentScope
import com.meta.wearable.dat.display.views.CornerRadius
import com.meta.wearable.dat.display.views.Direction
import com.meta.wearable.dat.display.views.FlexBoxBackground
import com.meta.wearable.dat.display.views.ImageSize
import com.meta.wearable.dat.display.views.TextColor
import com.meta.wearable.dat.display.views.TextStyle
import com.tzglasses.hud.core.HudFrame
import com.tzglasses.hud.core.Severity
import kotlin.math.abs

enum class LensMode(val label: String) { PICTURE("Picture"), TEXT("Text") }

/**
 * Builds the Display content sent to the glasses (port of HUDDisplayLayout.swift). Two modes so
 * they can be compared on real glasses:
 *
 *  PICTURE - the HUD drawn as one 600 × 600 image: full colour, exact placement, bigger transfer.
 *  TEXT    - Meta's own components: small transfers, two text colours, approximate placement
 *            (each label is slid sideways with flexible spacers).
 */
object HudDisplayLayout {
  fun ContentScope.picture(image: Bitmap, onTap: () -> Unit) {
    flexBox(direction = Direction.COLUMN, onClick = onTap) {
      image(bitmap = image, sizePreset = ImageSize.FILL, cornerRadius = CornerRadius.NONE)
    }
  }

  fun ContentScope.text(f: HudFrame, onTap: () -> Unit) {
    flexBox(direction = Direction.COLUMN, gap = 10, padding = 16, onClick = onTap) {
      // Top strip
      flexBox(direction = Direction.ROW, crossAlignment = Alignment.CENTER) {
        text(f.headingText, style = TextStyle.META)
        flexBox(flexGrow = 1f) {}
        text(if (f.stale) "NO DATA" else f.gazeText, style = TextStyle.META, color = TextColor.SECONDARY)
        flexBox(flexGrow = 1f) {}
        text(f.speedText, style = TextStyle.META)
      }

      f.message?.let { text(it, style = TextStyle.BODY) }

      // One row per label, slid sideways to where it sits in the view.
      for (item in f.items.take(3)) {
        flexBox(direction = Direction.ROW, crossAlignment = Alignment.CENTER) {
          flexBox(flexGrow = item.x.coerceAtLeast(0.01).toFloat() * 100) {}
          flexBox(direction = Direction.COLUMN, crossAlignment = Alignment.CENTER) {
            text(item.title, style = if (item.severity == Severity.NORMAL) TextStyle.BODY else TextStyle.HEADING)
            text(item.detail, style = TextStyle.META,
                color = if (item.severity == Severity.NORMAL) TextColor.SECONDARY else TextColor.PRIMARY)
          }
          flexBox(flexGrow = (1 - item.x).coerceAtLeast(0.01).toFloat() * 100) {}
        }
      }

      flexBox(flexGrow = 1f) {}

      if (f.edges.isNotEmpty()) {
        flexBox(direction = Direction.ROW, crossAlignment = Alignment.CENTER) {
          for (e in f.edges.filter { it.turnDeg < 0 }) text("‹ ${e.label} ${abs(e.turnDeg)}°", style = TextStyle.META)
          flexBox(flexGrow = 1f) {}
          for (e in f.edges.filter { it.turnDeg > 0 }) text("${e.label} ${e.turnDeg}° ›", style = TextStyle.META)
        }
      }

      val alarm = f.alarmTitle
      if (alarm != null) {
        // No warning icon is confirmed in the Android IconName set, so the banner is text only.
        flexBox(direction = Direction.COLUMN, padding = 12, background = FlexBoxBackground.CARD) {
          text("⚠ $alarm", style = TextStyle.BODY)
          text((f.alarmDetail ?: "") + " · tap to acknowledge", style = TextStyle.META, color = TextColor.SECONDARY)
        }
      } else {
        f.footer?.let { text(it, style = TextStyle.META, color = TextColor.SECONDARY) }
      }
    }
  }
}
