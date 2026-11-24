//
// DemoFeed.swift
//
// Built-in sample traffic so the app can be tried with no bridge and no boat.
// Same scenario as the bridge's nmea_sim.py and the web demo: outbound from
// Halifax Harbour with a cargo ship set to pass 0.3 nm ahead in about 7 minutes.
//

import Foundation

struct DemoFeed {
  private struct Mover {
    var name: String; var type: String; var lat: Double; var lon: Double; var sog: Double; var cog: Double; var mmsi: Int
    /// "AIS", "ARPA" (radar-tracked) or "ONLINE" (internet AIS), and for online AIS how old it is.
    var source = "AIS"; var ageS: Double? = nil
  }

  private var ownLat = 44.6205
  private var ownLon = -63.5560
  private let ownSog = 6.5
  private var ownHdg = 160.0
  private var t = 0.0
  private var movers: [Mover] = []
  private var buoys: [(String, Double, Double)] = []
  /// TimeZero route being navigated: (name, lat, lon), and the index of the waypoint steered to.
  private var route: [(String, Double, Double)] = []
  private var nextWp = 1
  /// Saved and recorded tracks, as the bridge serves them at /userdata.json.
  private(set) var userData = UserData()
  private struct DemoMark { var name: String; var icon: String; var lat: Double; var lon: Double }
  private var marks: [DemoMark] = []

  init() { reset() }

  private static func move(_ lat: Double, _ lon: Double, sog: Double, cog: Double, seconds: Double) -> (Double, Double) {
    let d = sog * seconds / 3600
    return (lat + d * cos(cog * .pi / 180) / 60,
            lon + d * sin(cog * .pi / 180) / (60 * cos(lat * .pi / 180)))
  }

  private static func offset(_ lat: Double, _ lon: Double, bearing: Double, nm: Double) -> (Double, Double) {
    move(lat, lon, sog: nm * 3600, cog: bearing, seconds: 1)
  }

  mutating func reset() {
    t = 0
    ownLat = 44.6205; ownLon = -63.5560; ownHdg = 160
    let place = { (b: Double, nm: Double) in Self.offset(44.6205, -63.5560, bearing: b, nm: nm) }
    // Cargo ship timed to cross ahead.
    let tCross = 7.0 * 60
    let ownLater = Self.move(ownLat, ownLon, sog: ownSog, cog: 160, seconds: tCross)
    let cpaPoint = Self.offset(ownLater.0, ownLater.1, bearing: 160, nm: 0.3)
    let cargoStart = Self.move(cpaPoint.0, cpaPoint.1, sog: 12, cog: 95, seconds: tCross)
    let heron = place(200, 1.4), ferry = place(250, 1.8), sprite = place(40, 2.8)
    let arpa7 = place(132, 1.1), arpa12 = place(186, 0.8), provider = place(168, 5.5)
    movers = [
      Mover(name: "ATLANTIC SAMPLE", type: "Cargo", lat: cargoStart.0, lon: cargoStart.1, sog: 12, cog: 275, mmsi: 316001234),
      Mover(name: "BLUE HERON", type: "Sailing", lat: heron.0, lon: heron.1, sog: 4.5, cog: 340, mmsi: 316005678),
      Mover(name: "HARBOUR FERRY", type: "Passenger", lat: ferry.0, lon: ferry.1, sog: 9, cog: 60, mmsi: 316009012),
      Mover(name: "ARPA 07", type: "Fishing", lat: arpa7.0, lon: arpa7.1, sog: 3.5, cog: 105, mmsi: 0, source: "ARPA"),
      Mover(name: "ARPA 12", type: "Fishing", lat: arpa12.0, lon: arpa12.1, sog: 0.5, cog: 90, mmsi: 0, source: "ARPA"),
      Mover(name: "SEA SPRITE", type: "Pleasure", lat: sprite.0, lon: sprite.1, sog: 0.2, cog: 0, mmsi: 316003456,
            source: "ONLINE", ageS: 120),
      Mover(name: "OCEAN PROVIDER", type: "Cargo", lat: provider.0, lon: provider.1, sog: 11, cog: 45, mmsi: 316007890,
            source: "ONLINE", ageS: 240),
    ]
    let red = place(155, 1.2), green = place(170, 2.3)
    buoys = [("RED BUOY", red.0, red.1), ("GREEN BUOY", green.0, green.1)]
    // Harbour run, as in hud-demo.html: WP3 just astern of the start, out through the harbour mouth.
    let wp3 = place(340, 0.25), wp4 = place(158, 4.0)
    let wp5 = Self.offset(wp4.0, wp4.1, bearing: 172, nm: 2.4)
    let wp6 = Self.offset(wp5.0, wp5.1, bearing: 228, nm: 3.0)
    route = [("WP3", wp3.0, wp3.1), ("WP4 HARBOUR MOUTH", wp4.0, wp4.1),
             ("WP5 OUTER MARK", wp5.0, wp5.1), ("WP6 SAMBRO", wp6.0, wp6.1)]
    nextWp = 1
    // Own track: the way out of the inner harbour, as the bridge would have recorded it.
    let now = Date().timeIntervalSince1970
    let trail = (1...60).reversed().map { i -> TrackPoint in
      let p = place(338 + 10 * sin(Double(i) / 9), Double(i) * 0.03)
      return TrackPoint(lat: p.0, lon: p.1, t: now - Double(i) * 30)
    }
    // A saved track from an earlier trip ("Saturday sail" in the bridge's sample GPX).
    let sail: [(Double, Double)] = [(44.6262, -63.5668), (44.6180, -63.5580), (44.6100, -63.5500), (44.6010, -63.5420),
                                    (44.5930, -63.5380), (44.5850, -63.5400), (44.5780, -63.5470)]
    var saved: [TrackPoint] = []
    for i in 0..<(sail.count - 1) {
      for k in 0..<12 {
        let f = Double(k) / 12, w = 0.00025 * sin(Double(i * 12 + k) / 2.3)
        saved.append(TrackPoint(lat: sail[i].0 + (sail[i + 1].0 - sail[i].0) * f + w,
                                lon: sail[i].1 + (sail[i + 1].1 - sail[i].1) * f - w))
      }
    }
    userData = UserData(version: now, tracks: [SavedTrack(name: "Saturday sail", points: saved)], ownTrack: trail)
    // TimeZero marks, as in hud-demo.html.
    let pots = place(149, 0.55), shoal = place(176, 1.45), anchorage = place(305, 0.7)
    marks = [
      DemoMark(name: "Fishing spot", icon: "fish", lat: 44.6010, lon: -63.5415),
      DemoMark(name: "Lobster pots", icon: "pots", lat: pots.0, lon: pots.1),
      DemoMark(name: "Shoal 2.1 m", icon: "danger", lat: shoal.0, lon: shoal.1),
      DemoMark(name: "Anchorage", icon: "anchor", lat: anchorage.0, lon: anchorage.1),
    ]
  }

  /// What the bridge sends while TimeZero navigates the route (RMB plus the route's waypoints).
  /// Arriving within 0.1 nm moves on to the next waypoint; after the last, navigation stops.
  private mutating func routeInfo() -> RouteInfo {
    let wps = route.map { w -> Waypoint in
      let (r, b) = Geo.rangeBearing(fromLat: ownLat, fromLon: ownLon, toLat: w.1, toLon: w.2)
      return Waypoint(name: w.0, lat: w.1, lon: w.2, rangeNm: r, bearing: b)
    }
    if nextWp < wps.count, let r = wps[nextWp].rangeNm, r < 0.1 { nextWp += 1 }
    guard nextWp < wps.count, nextWp >= 1 else {
      return RouteInfo(routeName: "HARBOUR RUN", waypoints: wps)   // not navigating
    }
    // Cross-track error on the active leg: + = right of track, so steer left.
    func local(_ w: Waypoint) -> (Double, Double) {
      (((w.lon ?? 0) - ownLon) * 60 * cos(ownLat * .pi / 180), ((w.lat ?? 0) - ownLat) * 60)
    }
    let a = local(wps[nextWp - 1]), b = local(wps[nextWp])
    let ux = b.0 - a.0, uy = b.1 - a.1, len = max(hypot(ux, uy), 1e-9)
    let xte = -a.0 * (uy / len) + a.1 * (ux / len)
    let to = wps[nextWp]
    return RouteInfo(toWp: to.name, fromWp: wps[nextWp - 1].name, rangeNm: to.rangeNm, bearing: to.bearing,
                     xteNm: abs(xte), steer: xte > 0 ? "L" : "R", routeName: "HARBOUR RUN",
                     nextIndex: nextWp, waypoints: wps)
  }

  mutating func step(seconds dt: Double) -> BoatSnapshot {
    t += dt
    if t > 18 * 60 { reset() }
    ownHdg = 160 + 4 * sin(t / 25)
    (ownLat, ownLon) = Self.move(ownLat, ownLon, sog: ownSog, cog: ownHdg, seconds: dt)
    for i in movers.indices {
      (movers[i].lat, movers[i].lon) = Self.move(movers[i].lat, movers[i].lon, sog: movers[i].sog, cog: movers[i].cog, seconds: dt)
    }

    var snap = BoatSnapshot()
    snap.rxAgeS = 0
    snap.own = OwnShip(lat: ownLat, lon: ownLon, sog: ownSog, cog: ownHdg, hdg: ownHdg,
                       depthM: 22 + 3 * sin(t / 40), aws: 14, awa: 35)

    let ownVx = ownSog * sin(ownHdg * .pi / 180), ownVy = ownSog * cos(ownHdg * .pi / 180)
    var targets: [Target] = movers.map { m in
      let (r, b) = Geo.rangeBearing(fromLat: ownLat, fromLon: ownLon, toLat: m.lat, toLon: m.lon)
      // CPA / TCPA with relative motion, same as the bridge.
      let dx = r * sin(b * .pi / 180), dy = r * cos(b * .pi / 180)
      let vx = m.sog * sin(m.cog * .pi / 180) - ownVx, vy = m.sog * cos(m.cog * .pi / 180) - ownVy
      let v2 = vx * vx + vy * vy
      let th = v2 < 1e-9 ? 0 : max(0, -(dx * vx + dy * vy) / v2)
      return Target(mmsi: m.mmsi == 0 ? nil : m.mmsi, name: m.name, kind: "vessel",
                    typeLabel: m.source == "ARPA" ? nil : m.type, source: m.source, ageS: m.ageS, lat: m.lat, lon: m.lon,
                    sog: m.sog, cog: m.cog, rangeNm: r, bearing: b,
                    cpaNm: hypot(dx + vx * th, dy + vy * th), tcpaMin: th * 60)
    }
    for (name, lat, lon) in buoys {
      let (r, b) = Geo.rangeBearing(fromLat: ownLat, fromLon: ownLon, toLat: lat, toLon: lon)
      targets.append(Target(name: name, kind: "aton", lat: lat, lon: lon, rangeNm: r, bearing: b))
    }
    snap.targets = targets

    snap.route = routeInfo()
    snap.marks = marks.map { m in
      let (r, b) = Geo.rangeBearing(fromLat: ownLat, fromLon: ownLon, toLat: m.lat, toLon: m.lon)
      return Mark(name: m.name, icon: LooseString(stringLiteral: m.icon), lat: m.lat, lon: m.lon, rangeNm: r, bearing: b)
    }
    return snap
  }
}
