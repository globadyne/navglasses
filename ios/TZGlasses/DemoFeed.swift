//
// DemoFeed.swift
//
// Built-in sample traffic so the app can be tried with no bridge and no boat.
// Same scenario as the bridge's nmea_sim.py and the web demo: outbound from
// Halifax Harbour with a cargo ship set to pass 0.3 nm ahead in about 7 minutes.
//

import Foundation

struct DemoFeed {
  private struct Mover { var name: String; var type: String; var lat: Double; var lon: Double; var sog: Double; var cog: Double; var mmsi: Int }

  private var ownLat = 44.6205
  private var ownLon = -63.5560
  private let ownSog = 6.5
  private var ownHdg = 160.0
  private var t = 0.0
  private var movers: [Mover] = []
  private var buoys: [(String, Double, Double)] = []
  private var waypoint: (String, Double, Double) = ("WP4 HARBOUR MOUTH", 0, 0)

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
    movers = [
      Mover(name: "ATLANTIC SAMPLE", type: "Cargo", lat: cargoStart.0, lon: cargoStart.1, sog: 12, cog: 275, mmsi: 316001234),
      Mover(name: "BLUE HERON", type: "Sailing", lat: heron.0, lon: heron.1, sog: 4.5, cog: 340, mmsi: 316005678),
      Mover(name: "HARBOUR FERRY", type: "Passenger", lat: ferry.0, lon: ferry.1, sog: 9, cog: 60, mmsi: 316009012),
      Mover(name: "SEA SPRITE", type: "Pleasure", lat: sprite.0, lon: sprite.1, sog: 0.2, cog: 0, mmsi: 316003456),
    ]
    let red = place(155, 1.2), green = place(170, 2.3)
    buoys = [("RED BUOY", red.0, red.1), ("GREEN BUOY", green.0, green.1)]
    let wp = place(158, 4.0)
    waypoint = ("WP4 HARBOUR MOUTH", wp.0, wp.1)
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
      return Target(mmsi: m.mmsi, name: m.name, kind: "vessel", typeLabel: m.type, lat: m.lat, lon: m.lon,
                    sog: m.sog, cog: m.cog, rangeNm: r, bearing: b,
                    cpaNm: hypot(dx + vx * th, dy + vy * th), tcpaMin: th * 60)
    }
    for (name, lat, lon) in buoys {
      let (r, b) = Geo.rangeBearing(fromLat: ownLat, fromLon: ownLon, toLat: lat, toLon: lon)
      targets.append(Target(name: name, kind: "aton", lat: lat, lon: lon, rangeNm: r, bearing: b))
    }
    snap.targets = targets

    let (wr, wb) = Geo.rangeBearing(fromLat: ownLat, fromLon: ownLon, toLat: waypoint.1, toLon: waypoint.2)
    snap.route = RouteInfo(toWp: waypoint.0, rangeNm: wr, bearing: wb, xteNm: abs(0.05 * sin(t / 25)),
                           steer: sin(t / 25) > 0 ? "L" : "R")
    let (mr, mb) = Geo.rangeBearing(fromLat: ownLat, fromLon: ownLon, toLat: 44.6010, toLon: -63.5415)
    snap.marks = [Mark(name: "Fishing spot", lat: 44.6010, lon: -63.5415, rangeNm: mr, bearing: mb)]
    return snap
  }
}
