package com.tzglasses.hud.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.sin

/**
 * Built-in sample traffic so the app can be tried with no bridge and no boat. Same scenario as
 * DemoFeed.swift, nmea_sim.py and the web demo: outbound from Halifax Harbour with a cargo ship
 * set to pass 0.3 nm ahead in about 7 minutes.
 */
class DemoFeed {
  private data class Mover(val name: String, val type: String, var lat: Double, var lon: Double,
                           val sog: Double, val cog: Double, val mmsi: Long)

  private var ownLat = 44.6205
  private var ownLon = -63.5560
  private val ownSog = 6.5
  private var ownHdg = 160.0
  private var t = 0.0
  private var movers = listOf<Mover>()
  private var buoys = listOf<Triple<String, Double, Double>>()
  private var waypoint = Triple("WP4 HARBOUR MOUTH", 0.0, 0.0)

  init { reset() }

  fun reset() {
    t = 0.0
    ownLat = 44.6205; ownLon = -63.5560; ownHdg = 160.0
    fun place(b: Double, nm: Double) = offset(44.6205, -63.5560, b, nm)
    val tCross = 7.0 * 60
    val ownLater = move(ownLat, ownLon, ownSog, 160.0, tCross)
    val cpaPoint = offset(ownLater.first, ownLater.second, 160.0, 0.3)
    val cargoStart = move(cpaPoint.first, cpaPoint.second, 12.0, 95.0, tCross)
    val heron = place(200.0, 1.4)
    val ferry = place(250.0, 1.8)
    val sprite = place(40.0, 2.8)
    movers = listOf(
        Mover("ATLANTIC SAMPLE", "Cargo", cargoStart.first, cargoStart.second, 12.0, 275.0, 316001234),
        Mover("BLUE HERON", "Sailing", heron.first, heron.second, 4.5, 340.0, 316005678),
        Mover("HARBOUR FERRY", "Passenger", ferry.first, ferry.second, 9.0, 60.0, 316009012),
        Mover("SEA SPRITE", "Pleasure", sprite.first, sprite.second, 0.2, 0.0, 316003456),
    )
    val red = place(155.0, 1.2)
    val green = place(170.0, 2.3)
    buoys = listOf(Triple("RED BUOY", red.first, red.second), Triple("GREEN BUOY", green.first, green.second))
    val wp = place(158.0, 4.0)
    waypoint = Triple("WP4 HARBOUR MOUTH", wp.first, wp.second)
  }

  fun step(dt: Double): BoatSnapshot {
    t += dt
    if (t > 18 * 60) reset()
    ownHdg = 160 + 4 * sin(t / 25)
    move(ownLat, ownLon, ownSog, ownHdg, dt).let { ownLat = it.first; ownLon = it.second }
    for (m in movers) move(m.lat, m.lon, m.sog, m.cog, dt).let { m.lat = it.first; m.lon = it.second }

    val ownVx = ownSog * sin(ownHdg * PI / 180)
    val ownVy = ownSog * cos(ownHdg * PI / 180)
    val targets = movers.map { m ->
      val (r, b) = Geo.rangeBearing(ownLat, ownLon, m.lat, m.lon)
      val dx = r * sin(b * PI / 180)
      val dy = r * cos(b * PI / 180)
      val vx = m.sog * sin(m.cog * PI / 180) - ownVx
      val vy = m.sog * cos(m.cog * PI / 180) - ownVy
      val v2 = vx * vx + vy * vy
      val th = if (v2 < 1e-9) 0.0 else max(0.0, -(dx * vx + dy * vy) / v2)
      Target(mmsi = m.mmsi, name = m.name, kind = "vessel", typeLabel = m.type, source = "AIS", lat = m.lat,
          lon = m.lon, sog = m.sog, cog = m.cog, rangeNm = r, bearing = b,
          cpaNm = hypot(dx + vx * th, dy + vy * th), tcpaMin = th * 60)
    } + buoys.map { (name, lat, lon) ->
      val (r, b) = Geo.rangeBearing(ownLat, ownLon, lat, lon)
      Target(name = name, kind = "aton", lat = lat, lon = lon, rangeNm = r, bearing = b)
    }

    val (wr, wb) = Geo.rangeBearing(ownLat, ownLon, waypoint.second, waypoint.third)
    val (mr, mb) = Geo.rangeBearing(ownLat, ownLon, 44.6010, -63.5415)
    return BoatSnapshot(
        rxAgeS = 0.0,
        own = OwnShip(lat = ownLat, lon = ownLon, sog = ownSog, cog = ownHdg, hdg = ownHdg,
            depthM = 22 + 3 * sin(t / 40), aws = 14.0, awa = 35.0),
        targets = targets,
        route = RouteInfo(toWp = waypoint.first, rangeNm = wr, bearing = wb, xteNm = abs(0.05 * sin(t / 25)),
            steer = if (sin(t / 25) > 0) "L" else "R"),
        marks = listOf(Mark(name = "Fishing spot", lat = 44.6010, lon = -63.5415, rangeNm = mr, bearing = mb)),
    )
  }

  private companion object {
    fun move(lat: Double, lon: Double, sog: Double, cog: Double, seconds: Double): Pair<Double, Double> {
      val d = sog * seconds / 3600
      return (lat + d * cos(cog * PI / 180) / 60) to (lon + d * sin(cog * PI / 180) / (60 * cos(lat * PI / 180)))
    }

    fun offset(lat: Double, lon: Double, bearing: Double, nm: Double) = move(lat, lon, nm * 3600, bearing, 1.0)
  }
}
