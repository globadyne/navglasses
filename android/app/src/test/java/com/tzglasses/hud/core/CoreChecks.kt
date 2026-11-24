package com.tzglasses.hud.core

import java.util.Random
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/*
 * Checks for the pure-Kotlin core (HeadMath, HudBuilder, BoatSnapshot.parse, DemoFeed).
 * The head-math cases are the same as ios/tests/test_head_math.py, so all three implementations
 * are held to the same simulated head movements.
 *
 * No test framework needed: CoreTest.kt runs these under JUnit in Gradle, and `main` below runs
 * them with plain kotlinc (see android/README.md).
 */

private fun axisAngle(ax: Vec3, deg: Double): Quat {
  val a = deg * PI / 180 / 2
  val n = ax.normalized
  return Quat(cos(a), n.x * sin(a), n.y * sin(a), n.z * sin(a))
}

// The IMU inside the glasses is mounted at some arbitrary angle to the head.
private val MOUNT = axisAngle(Vec3(0.3, 1.0, 0.2), 97.0) * axisAngle(Vec3(1.0, 0.0, 0.0), -90.0)

private fun headPose(compass: Double, pitch: Double = 0.0, roll: Double = 0.0): Quat {
  val yaw = axisAngle(Vec3.UP, -compass)
  return yaw * axisAngle(Vec3(1.0, 0.0, 0.0), pitch) * axisAngle(Vec3(0.0, 1.0, 0.0), roll) * MOUNT
}

private data class Sim(val q: Quat, val accel: Vec3, val gyro: Vec3)

private fun sample(compass: Double, pitch: Double = 0.0, roll: Double = 0.0, rateDps: Double = 0.0,
                   inverse: Boolean = false): Sim {
  val q = headPose(compass, pitch, roll)
  val accel = q.conjugate.rotate(Vec3(0.0, 0.0, 9.81))
  val gyro = q.conjugate.rotate(Vec3(0.0, 0.0, -rateDps * PI / 180))
  return Sim(if (inverse) q.conjugate else q, accel, gyro)
}

private data class P(val c: Double, val p: Double = 0.0, val r: Double = 0.0)

private fun run(path: List<P>, rnd: Random, inverse: Boolean = false, noise: Double = 0.0,
                dropGyro: Boolean = false, flipSign: Boolean = false): Pair<HeadMath, List<Double?>> {
  val m = HeadMath()
  val out = ArrayList<Double?>()
  var t = 0L
  var prev = path[0].c
  path.forEachIndexed { i, pt ->
    val rate = (pt.c - prev) * 30
    prev = pt.c
    val s = sample(pt.c, pt.p + rnd.nextGaussian() * noise, pt.r + rnd.nextGaussian() * noise, rate, inverse)
    val g = if (flipSign) s.gyro * -1.0 else s.gyro
    out += m.ingest(HeadSample(t, s.q, s.accel, if (dropGyro) null else g))
    if (i == 0) m.calibrate()
    t += 33_333_333
  }
  return m to out
}

/** Look at the bow for 3 s, then sweep to 60 deg starboard, 40 port, and settle at 45 starboard. */
private fun sweep(start: Double = 0.0, seconds: Double = 6.0): List<P> {
  val path = ArrayList<P>()
  repeat(90) { path += P(start) }
  for (k in 0 until (30 * seconds).toInt()) {
    val c = if (k < 90) start + 60 * sin(k / 30.0 * 1.2) else start - 40 * sin((k - 90) / 30.0 * 1.0)
    path += P(c, 3 * sin(k / 9.0), 2 * cos(k / 7.0))
  }
  repeat(15) { path += P(start + 45) }
  return path
}

fun runCoreChecks(seed: Long = 1): List<Pair<String, Boolean>> {
  val rnd = Random(seed)
  val res = ArrayList<Pair<String, Boolean>>()
  fun check(name: String, cond: Boolean, detail: Any? = null) {
    res += (name + (detail?.let { "  ($it)" } ?: "")) to cond
  }

  // 1. Pure turns
  run(List(5) { P(0.0) } + P(30.0) + P(-45.0), rnd).second.let {
    check("turn 30 to starboard reads +30", abs(it[5]!! - 30) < 0.01, it[5])
    check("turn 45 to port reads -45", abs(it[6]!! + 45) < 0.01, it[6])
  }
  // 2. Turning while nodding and tilting
  run(List(95) { P(0.0) } + listOf(P(25.0, 15.0, 8.0), P(-60.0, -20.0, -10.0), P(170.0, 10.0, 5.0)), rnd).second.let {
    check("yaw with 15/8 tilt", abs(it[95]!! - 25) < 3, it[95])
    check("yaw with -20/-10 tilt", abs(it[96]!! + 60) < 5, it[96])
    check("looking astern reads ~170", abs(it[97]!! - 170) < 4, it[97])
  }
  // 3. Quaternion convention detected
  run(sweep(), rnd, inverse = true, noise = 1.0).let { (m, out) ->
    check("detects inverse convention", m.useInverse && m.conventionLocked)
    check("inverse: final 45 starboard", abs(out.last()!! - 45) < 4, out.last())
  }
  run(sweep(), rnd, noise = 1.0).let { (m, out) ->
    check("normal convention kept", !m.useInverse)
    check("normal: final 45 starboard", abs(out.last()!! - 45) < 4, out.last())
  }
  // 4. Gyro disagrees: sign learned from gyro
  run(sweep(), rnd, flipSign = true).let { (m, out) ->
    check("sign flipped after head turns", m.autoSign == -1.0)
    check("flipped: final reads -45", abs(out.last()!! + 45) < 4, out.last())
  }
  // 5. No gyro
  run(sweep(), rnd, dropGyro = true).second.let { check("no gyro: final 45", abs(it.last()!! - 45) < 4, it.last()) }
  // 6. Re-centre
  run {
    val m = HeadMath()
    var t = 0L
    for (c in List(10) { 0.0 } + List(5) { 50.0 }) {
      val s = sample(c)
      m.ingest(HeadSample(t, s.q, s.accel, s.gyro))
      t += 33_333_333
      if (t == 33_333_333L) m.calibrate()
    }
    m.calibrate()
    val s = sample(80.0)
    val r = m.ingest(HeadSample(t, s.q, s.accel, s.gyro))!!
    check("re-centre at 50, look at 80 reads +30", abs(r - 30) < 0.01, r)
  }

  // Lens placement and frame building
  val snap = BoatSnapshot(
      own = OwnShip(sog = 6.5, hdg = 100.0),
      targets = listOf(
          Target(name = "AHEAD", kind = "vessel", source = "AIS", rangeNm = 1.0, bearing = 100.0),
          Target(name = "RIGHT", kind = "vessel", source = "ARPA", rangeNm = 2.0, bearing = 105.0),
          Target(name = "BEHIND", kind = "vessel", source = "AIS", rangeNm = 0.5, bearing = 280.0, cpaNm = 0.1,
              tcpaMin = 5.0),
      ),
  )
  val f = HudBuilder.build(snap, 100.0, HudSettings())
  check("dead ahead is centre", f.items.any { it.title == "AHEAD" && it.x == 0.5 })
  check("5 deg right sits at 0.75", f.items.any { it.title == "RIGHT" && it.x == 0.75 })
  check("danger astern gives alarm and edge cue",
      f.alarmTitle == "CPA 0.10 NM IN 5 MIN" && f.edges.firstOrNull()?.turnDeg == 180, "${f.alarmTitle} ${f.edges}")
  val hidden = HudBuilder.build(snap, 100.0, HudSettings(hiddenSources = setOf("ARPA")))
  check("hiding ARPA removes radar targets", hidden.items.none { it.title == "RIGHT" })
  check("no gaze asks to calibrate", HudBuilder.build(snap, null, HudSettings()).message != null)
  check("wraps through north", HudBuilder.build(
      BoatSnapshot(own = OwnShip(), targets = listOf(Target(name = "N", rangeNm = 1.0, bearing = 2.0))),
      358.0, HudSettings()).items.single().x == 0.7)

  // JSON from the bridge
  val parsed = BoatSnapshot.parse(
      """{"time":1.5,"rx_age_s":0.2,"own":{"lat":44.6,"lon":-63.5,"sog":6.5,"hdg":160},
         "route":{"to_wp":"WP4","range_nm":3.2,"waypoints":[{"name":"WP4","lat":44.5,"lon":-63.4}]},
         "targets":[{"mmsi":316001234,"name":"CARGO \"X\"","source":"ARPA","bearing":95.5,"range_nm":1.1,"cpa_nm":null}],
         "marks":[{"name":"Fishé","range_nm":0.4,"bearing":10}]}""")
  check("parses own ship", parsed.own?.hdg == 160.0 && parsed.referenceHeading == 160.0)
  check("parses targets", parsed.targets?.single()?.let { it.mmsi == 316001234L && it.source == "ARPA" && it.name == "CARGO \"X\"" && it.cpaNm == null } == true)
  check("parses route waypoints", parsed.route?.waypoints?.single()?.lat == 44.5)
  check("parses unicode escapes", parsed.marks?.single()?.name == "Fishé")

  // Demo feed produces a crossing situation
  val demo = DemoFeed()
  var closest = 99.0
  repeat(600) { demo.step(1.0).targets?.first()?.rangeNm?.let { closest = minOf(closest, it) } }
  check("demo cargo passes close ahead", closest in 0.1..0.5, "%.2f nm".fmt(closest))
  return res
}

fun main() {
  val res = runCoreChecks()
  res.forEach { (n, ok) -> println((if (ok) "PASS " else "FAIL ") + n) }
  val ok = res.all { it.second }
  println(if (ok) "\nALL PASSED" else "\nSOME FAILED")
  if (!ok) kotlin.system.exitProcess(1)
}
