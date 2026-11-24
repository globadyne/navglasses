package com.tzglasses.hud.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.roundToInt

/*
 * Decides what the lens shows. Pure logic, a port of ios/TZGlasses/HUDModel.swift: given the boat
 * data and the true bearing the wearer is looking at, returns a HudFrame that both lens modes draw.
 */

object Geo {
  fun wrap180(deg: Double): Double {
    var a = deg % 360
    if (a > 180) a -= 360
    if (a < -180) a += 360
    return a
  }

  fun wrap360(deg: Double): Double {
    val a = deg % 360
    return if (a < 0) a + 360 else a
  }

  /** Range (nm) and true bearing, flat-earth (fine within ~20 nm). */
  fun rangeBearing(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double): Pair<Double, Double> {
    val dx = (toLon - fromLon) * 60 * cos(fromLat * PI / 180)
    val dy = (toLat - fromLat) * 60
    return hypot(dx, dy) to wrap360(atan2(dx, dy) * 180 / PI)
  }

  fun threeDigits(deg: Double): String = "%03d".fmt(wrap360(deg).roundToInt() % 360)
}

enum class Severity { NORMAL, CAUTION, DANGER }

enum class ItemKind { VESSEL, ATON, MARK, WAYPOINT }

/** One label pinned to something in the lens. */
data class HudItem(
    val kind: ItemKind,
    val title: String,
    val detail: String,
    /** Horizontal position across the lens, 0 = left edge, 1 = right edge. */
    val x: Double,
    val rangeNm: Double,
    val severity: Severity,
    val isNextWaypoint: Boolean = false,
    /** "AIS", "ARPA" (radar) or null. */
    val source: String? = null,
)

/** An arrow at the lens edge for something important that is out of view. */
data class EdgeCue(
    val label: String,
    /** Degrees to turn: negative = to port, positive = to starboard. */
    val turnDeg: Int,
    val severity: Severity,
)

data class HudFrame(
    val headingText: String = "HDG ---",
    val speedText: String = "--.- KN",
    val gazeText: String = "---",
    val items: List<HudItem> = emptyList(),
    val edges: List<EdgeCue> = emptyList(),
    val alarmTitle: String? = null,
    val alarmDetail: String? = null,
    val footer: String? = null,
    val stale: Boolean = false,
    val message: String? = null,
) {
  companion object {
    val WAITING = HudFrame(message = "Waiting for boat data")
  }
}

data class HudSettings(
    val fovDeg: Double = 20.0,
    val maxLabels: Int = 4,
    val cpaCautionNm: Double = 0.5,
    val cpaDangerNm: Double = 0.25,
    val tcpaLimitMin: Double = 20.0,
    val markRangeNm: Double = 5.0,
    val showMarks: Boolean = true,
    /** Target sources to leave out: "AIS", "ARPA". Collision alarms follow the same choice. */
    val hiddenSources: Set<String> = emptySet(),
)

object HudBuilder {
  fun severity(t: Target, s: HudSettings): Severity {
    val cpa = t.cpaNm
    val tcpa = t.tcpaMin
    if (!t.isVessel || cpa == null || tcpa == null || tcpa <= 0 || tcpa > s.tcpaLimitMin) return Severity.NORMAL
    return when {
      cpa < s.cpaDangerNm -> Severity.DANGER
      cpa < s.cpaCautionNm -> Severity.CAUTION
      else -> Severity.NORMAL
    }
  }

  /**
   * @param gaze true bearing the wearer is looking at, or null if head direction is unknown
   * @param acknowledged target keys whose alarm the wearer has dismissed
   */
  fun build(
      snapshot: BoatSnapshot?,
      gaze: Double?,
      s: HudSettings,
      acknowledged: Set<String> = emptySet(),
  ): HudFrame {
    val snap = snapshot ?: return HudFrame.WAITING
    val own = snap.own ?: return HudFrame.WAITING
    val heading = snap.referenceHeading

    val allTargets = (snap.targets ?: emptyList()).filter { sourceKey(it) !in s.hiddenSources }

    val threats = allTargets.filter { it.isVessel }
        .map { it to severity(it, s) }
        .filter { it.second != Severity.NORMAL }
        .sortedBy { it.first.cpaNm ?: 99.0 }

    var alarmTitle: String? = null
    var alarmDetail: String? = null
    val threat = threats.firstOrNull { it.first.key !in acknowledged }?.first
    if (threat?.cpaNm != null && threat.tcpaMin != null) {
      alarmTitle = "CPA %.2f NM IN %d MIN".fmt(threat.cpaNm, threat.tcpaMin.roundToInt())
      var side = ""
      if (threat.bearing != null && heading != null) {
        val rel = Geo.wrap180(threat.bearing - heading).roundToInt()
        side = " · ${abs(rel)}° ${if (rel < 0) "PORT" else "STBD"}"
      }
      alarmDetail = shortName(threat.name) + side
    }

    val route = snap.route
    var footer: String? = null
    if (route?.toWp != null && route.rangeNm != null) {
      footer = "${shortName(route.toWp)} " + "%.1f NM".fmt(route.rangeNm)
      if (route.xteNm != null && route.steer != null && route.xteNm >= 0.01) {
        footer += " · XTE %.2f ".fmt(route.xteNm) + if (route.steer == "L") "STEER L" else "STEER R"
      }
    } else if (own.depthM != null) {
      footer = "DEPTH %.0f M".fmt(own.depthM)
    }

    val base = HudFrame(
        headingText = heading?.let { "HDG ${Geo.threeDigits(it)}°" } ?: "HDG ---",
        speedText = own.sog?.let { "%.1f KN".fmt(it) } ?: "--.- KN",
        alarmTitle = alarmTitle,
        alarmDetail = alarmDetail,
        footer = footer,
        stale = (snap.rxAgeS ?: 0.0) > 5,
    )
    if (gaze == null) return base.copy(message = "Look at the bow and tap to start")

    val half = s.fovDeg / 2
    fun place(bearing: Double?): Double? {
      bearing ?: return null
      val rel = Geo.wrap180(bearing - gaze)
      if (abs(rel) > half) return null
      // Snap to 1/120 of the lens (5 px) so sensor jitter doesn't trigger a resend.
      return Math.round((0.5 + rel / s.fovDeg) * 120) / 120.0
    }

    val candidates = ArrayList<HudItem>()
    for (t in allTargets) {
      val x = place(t.bearing) ?: continue
      val r = t.rangeNm ?: continue
      val sev = severity(t, s)
      if (t.isVessel) {
        val detail = if (sev != Severity.NORMAL && t.cpaNm != null && t.tcpaMin != null) {
          "CPA %.2f · %d MIN".fmt(t.cpaNm, t.tcpaMin.roundToInt())
        } else {
          "%.1f NM".fmt(r) + (t.sog?.let { " · %.0f KN".fmt(it) } ?: "")
        }
        candidates += HudItem(ItemKind.VESSEL, displayName(t), detail, x, r, sev, source = sourceKey(t))
      } else {
        candidates += HudItem(ItemKind.ATON, shortName(t.name), "%.1f NM".fmt(r), x, r, Severity.NORMAL)
      }
    }

    if (s.showMarks) {
      for (m in snap.marks ?: emptyList()) {
        val r = m.rangeNm ?: continue
        if (r > s.markRangeNm) continue
        val x = place(m.bearing) ?: continue
        candidates += HudItem(ItemKind.MARK, m.name?.let { shortName(it) } ?: "MARK", "%.1f NM".fmt(r), x, r,
            Severity.NORMAL)
      }
    }

    if (route?.toWp != null && route.rangeNm != null) {
      place(route.bearing)?.let { x ->
        candidates += HudItem(ItemKind.WAYPOINT, route.toWp.uppercase(), "%.1f NM".fmt(route.rangeNm), x,
            route.rangeNm, Severity.NORMAL, isNextWaypoint = true)
      }
    }

    // Most important first: alarms, then the next waypoint, then nearest.
    candidates.sortWith(
        compareByDescending<HudItem> { it.severity }
            .thenByDescending { it.isNextWaypoint }
            .thenBy { it.rangeNm })

    val edges = ArrayList<EdgeCue>()
    for ((t, sev) in threats) {
      val b = t.bearing ?: continue
      val rel = Geo.wrap180(b - gaze)
      if (abs(rel) > half) edges += EdgeCue(shortName(t.name), rel.roundToInt(), sev)
    }
    if (route?.bearing != null && route.toWp != null) {
      val rel = Geo.wrap180(route.bearing - gaze)
      if (abs(rel) > half) edges += EdgeCue(shortName(route.toWp), rel.roundToInt(), Severity.NORMAL)
    }

    return base.copy(
        gazeText = Geo.threeDigits(gaze) + "°",
        items = candidates.take(s.maxLabels),
        edges = edges.take(3),
    )
  }

  /** "ARPA" for radar-tracked targets, otherwise "AIS". */
  fun sourceKey(t: Target): String = if (t.source == "ARPA") "ARPA" else "AIS"

  fun displayName(t: Target): String {
    if (!t.name.isNullOrEmpty()) return shortName(t.name)
    t.typeLabel?.let { return it.uppercase() }
    return "VESSEL"
  }

  /** The lens has room for about 14 characters. */
  fun shortName(name: String?): String {
    val n = (name ?: "").trim().uppercase()
    if (n.isEmpty()) return "TARGET"
    return if (n.length <= 14) n else n.take(13) + "…"
  }
}

/** String.format with a fixed locale, so decimals are always "6.5" and never "6,5". */
internal fun String.fmt(vararg args: Any?): String = String.format(java.util.Locale.US, this, *args)
