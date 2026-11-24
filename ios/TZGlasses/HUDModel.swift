//
// HUDModel.swift
//
// Decides what the lens shows. Pure logic, no UIKit or SDK types, so it is easy
// to test: given the boat data and the true bearing the wearer is looking at,
// it returns a HUDFrame that both renderers (image and text) draw from.
//

import Foundation

enum Geo {
  /// Wrap an angle to -180...180.
  static func wrap180(_ deg: Double) -> Double {
    var a = deg.truncatingRemainder(dividingBy: 360)
    if a > 180 { a -= 360 }
    if a < -180 { a += 360 }
    return a
  }

  /// Wrap an angle to 0..<360.
  static func wrap360(_ deg: Double) -> Double {
    let a = deg.truncatingRemainder(dividingBy: 360)
    return a < 0 ? a + 360 : a
  }

  /// Range (nm) and true bearing from one position to another, flat-earth (fine within ~20 nm).
  static func rangeBearing(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> (Double, Double) {
    let dx = (toLon - fromLon) * 60 * cos(fromLat * .pi / 180)
    let dy = (toLat - fromLat) * 60
    return (hypot(dx, dy), wrap360(atan2(dx, dy) * 180 / .pi))
  }

  static func threeDigits(_ deg: Double) -> String {
    String(format: "%03d", Int(wrap360(deg).rounded()) % 360)
  }
}

enum Severity: Int, Comparable, Sendable {
  case normal = 0, caution = 1, danger = 2
  static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

enum ItemKind: Sendable { case vessel, aton, mark, waypoint }

/// One label pinned to something in the lens.
struct HUDItem: Equatable, Sendable {
  var kind: ItemKind
  var title: String
  var detail: String
  /// Horizontal position across the lens, 0 = left edge, 1 = right edge.
  var x: Double
  var rangeNm: Double
  var severity: Severity
  /// Waypoints sit on the horizon; vessels sit lower the closer they are.
  var isNextWaypoint: Bool = false
  /// Where a vessel came from: "AIS", "ARPA" (radar) or nil.
  var source: String? = nil
}

/// An arrow at the edge of the lens for something important that is out of view.
struct EdgeCue: Equatable, Sendable {
  var label: String
  /// Degrees to turn: negative = to port (left), positive = to starboard (right).
  var turnDeg: Int
  var severity: Severity
}

struct HUDFrame: Equatable, Sendable {
  var headingText: String = "HDG ---"
  var speedText: String = "--.- KN"
  var gazeText: String = "---"
  var items: [HUDItem] = []
  var edges: [EdgeCue] = []
  var alarmTitle: String?
  var alarmDetail: String?
  var footer: String?
  var stale: Bool = false
  var message: String?

  static let waiting = HUDFrame(message: "Waiting for boat data")
}

struct HUDSettings: Equatable, Sendable {
  var fovDeg: Double = 20
  var maxLabels: Int = 4
  var cpaCautionNm: Double = 0.5
  var cpaDangerNm: Double = 0.25
  var tcpaLimitMin: Double = 20
  var markRangeNm: Double = 5
  var showMarks: Bool = true
  /// Target sources to leave out: "AIS", "ARPA". Collision alarms follow the same choice.
  var hiddenSources: Set<String> = []
}

enum HUDBuilder {
  static func severity(of t: Target, _ s: HUDSettings) -> Severity {
    guard t.isVessel, let cpa = t.cpaNm, let tcpa = t.tcpaMin, tcpa > 0, tcpa <= s.tcpaLimitMin else {
      return .normal
    }
    if cpa < s.cpaDangerNm { return .danger }
    if cpa < s.cpaCautionNm { return .caution }
    return .normal
  }

  /// - Parameters:
  ///   - gaze: true bearing the wearer is looking at, or nil if head direction is unknown
  ///   - acknowledged: target keys whose alarm the wearer has dismissed
  static func build(
    snapshot: BoatSnapshot?,
    gaze: Double?,
    settings s: HUDSettings,
    acknowledged: Set<String> = []
  ) -> HUDFrame {
    guard let snap = snapshot, let own = snap.own else { return .waiting }
    var f = HUDFrame()
    f.stale = (snap.rxAgeS ?? 0) > 5
    if let h = snap.referenceHeading { f.headingText = "HDG \(Geo.threeDigits(h))°" }
    if let sog = own.sog { f.speedText = String(format: "%.1f KN", sog) }

    // Targets from sources the user has switched off are ignored entirely.
    let allTargets = (snap.targets ?? []).filter { !s.hiddenSources.contains(sourceKey($0)) }

    // Alarm: closest-CPA vessel that is not acknowledged.
    let vessels = allTargets.filter { $0.isVessel }
    let threats = vessels
      .map { ($0, severity(of: $0, s)) }
      .filter { $0.1 != .normal }
      .sorted { ($0.0.cpaNm ?? 99) < ($1.0.cpaNm ?? 99) }
    if let threat = threats.first(where: { !acknowledged.contains($0.0.key) }),
       let cpa = threat.0.cpaNm, let tcpa = threat.0.tcpaMin {
      let t = threat.0
      f.alarmTitle = String(format: "CPA %.2f NM IN %d MIN", cpa, Int(tcpa.rounded()))
      var side = ""
      if let b = t.bearing, let h = snap.referenceHeading {
        let rel = Int(Geo.wrap180(b - h).rounded())
        side = " · \(abs(rel))° \(rel < 0 ? "PORT" : "STBD")"
      }
      f.alarmDetail = "\(shortName(t.name))\(side)"
    }

    if let route = snap.route, let wp = route.toWp, let r = route.rangeNm {
      var footer = "\(shortName(wp)) " + String(format: "%.1f NM", r)
      if let x = route.xteNm, let steer = route.steer, x >= 0.01 {
        footer += String(format: " · XTE %.2f ", x) + (steer == "L" ? "STEER L" : "STEER R")
      }
      f.footer = footer
    } else if let d = own.depthM {
      f.footer = String(format: "DEPTH %.0f M", d)
    }

    guard let gaze else {
      f.message = "Look at the bow and tap to start"
      return f
    }
    f.gazeText = Geo.threeDigits(gaze) + "°"

    var candidates: [HUDItem] = []
    let half = s.fovDeg / 2
    func place(_ bearing: Double?) -> Double? {
      guard let b = bearing else { return nil }
      let rel = Geo.wrap180(b - gaze)
      guard abs(rel) <= half else { return nil }
      // Snap to 1/120 of the lens (5 px) so sensor jitter doesn't trigger a resend.
      return ((0.5 + rel / s.fovDeg) * 120).rounded() / 120
    }

    for t in allTargets {
      guard let x = place(t.bearing), let r = t.rangeNm else { continue }
      let sev = severity(of: t, s)
      if t.isVessel {
        let detail: String
        if sev != .normal, let cpa = t.cpaNm, let tcpa = t.tcpaMin {
          detail = String(format: "CPA %.2f · %d MIN", cpa, Int(tcpa.rounded()))
        } else {
          let sog = t.sog.map { String(format: " · %.0f KN", $0) } ?? ""
          detail = String(format: "%.1f NM", r) + sog
        }
        candidates.append(HUDItem(kind: .vessel, title: displayName(t), detail: detail, x: x, rangeNm: r,
                                  severity: sev, source: sourceKey(t)))
      } else {
        candidates.append(HUDItem(kind: .aton, title: shortName(t.name), detail: String(format: "%.1f NM", r),
                                  x: x, rangeNm: r, severity: .normal))
      }
    }

    if s.showMarks {
      for m in snap.marks ?? [] {
        guard let r = m.rangeNm, r <= s.markRangeNm, let x = place(m.bearing) else { continue }
        candidates.append(HUDItem(kind: .mark, title: m.name.map { shortName($0) } ?? "MARK",
                                  detail: String(format: "%.1f NM", r), x: x, rangeNm: r, severity: .normal))
      }
    }

    // Next waypoint: from the live route, else the route's waypoint list.
    if let route = snap.route, let wpName = route.toWp, let x = place(route.bearing), let r = route.rangeNm {
      candidates.append(HUDItem(kind: .waypoint, title: wpName.uppercased(), detail: String(format: "%.1f NM", r),
                                x: x, rangeNm: r, severity: .normal, isNextWaypoint: true))
    }

    // Most important first: alarms, then the next waypoint, then nearest.
    candidates.sort {
      if $0.severity != $1.severity { return $0.severity > $1.severity }
      if $0.isNextWaypoint != $1.isNextWaypoint { return $0.isNextWaypoint }
      return $0.rangeNm < $1.rangeNm
    }
    f.items = Array(candidates.prefix(s.maxLabels))

    // Edge cues for alarms and the next waypoint when they are out of view.
    for (t, sev) in threats {
      guard let b = t.bearing else { continue }
      let rel = Geo.wrap180(b - gaze)
      if abs(rel) > half { f.edges.append(EdgeCue(label: shortName(t.name), turnDeg: Int(rel.rounded()), severity: sev)) }
    }
    if let route = snap.route, let b = route.bearing, let wp = route.toWp {
      let rel = Geo.wrap180(b - gaze)
      if abs(rel) > half { f.edges.append(EdgeCue(label: shortName(wp), turnDeg: Int(rel.rounded()), severity: .normal)) }
    }
    f.edges = Array(f.edges.prefix(3))
    return f
  }

  /// "ARPA" for radar-tracked targets, otherwise "AIS" (AIS messages, AIS via TTM, or unknown TTM).
  static func sourceKey(_ t: Target) -> String { t.source == "ARPA" ? "ARPA" : "AIS" }

  static func displayName(_ t: Target) -> String {
    if let n = t.name, !n.isEmpty { return shortName(n) }
    if let type = t.typeLabel { return type.uppercased() }
    return "VESSEL"
  }

  /// Names are often long ("ATLANTIC SAMPLE II"); the lens has room for about 14 characters.
  static func shortName(_ name: String?) -> String {
    let n = (name ?? "").trimmingCharacters(in: .whitespaces).uppercased()
    if n.isEmpty { return "TARGET" }
    return n.count <= 14 ? n : String(n.prefix(13)) + "…"
  }
}
