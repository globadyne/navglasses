package com.tzglasses.hud.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/*
 * Turns orientation samples (from the glasses, or the phone for testing) into "how far has the
 * head turned left or right since the wearer looked at the bow". Pure maths, a line-for-line port
 * of ios/TZGlasses/HeadMath.swift (and mirrored in ios/tests/test_head_math.py). Keep all three
 * in step.
 *
 * - Meta doesn't document whether the orientation quaternion maps device -> world or the reverse,
 *   so we work it out: the accelerometer at rest points "up" in the device frame; rotated into the
 *   world it should stay put whichever way the head turns. The steadier convention wins.
 * - Head yaw is the twist of the rotation since calibration about that world up axis.
 * - The sign (which way is starboard) is confirmed against the gyroscope.
 */

data class Quat(val w: Double, val x: Double, val y: Double, val z: Double) {
  val conjugate: Quat get() = Quat(w, -x, -y, -z)

  val normalized: Quat
    get() {
      val n = sqrt(w * w + x * x + y * y + z * z)
      return if (n > 0) Quat(w / n, x / n, y / n, z / n) else IDENTITY
    }

  operator fun times(b: Quat) = Quat(
      w * b.w - x * b.x - y * b.y - z * b.z,
      w * b.x + x * b.w + y * b.z - z * b.y,
      w * b.y - x * b.z + y * b.w + z * b.x,
      w * b.z + x * b.y - y * b.x + z * b.w,
  )

  /** Rotate a vector by this (unit) quaternion. */
  fun rotate(v: Vec3): Vec3 {
    val r = this * Quat(0.0, v.x, v.y, v.z) * conjugate
    return Vec3(r.x, r.y, r.z)
  }

  companion object {
    val IDENTITY = Quat(1.0, 0.0, 0.0, 0.0)
  }
}

data class Vec3(val x: Double, val y: Double, val z: Double) {
  val length: Double get() = sqrt(x * x + y * y + z * z)
  val normalized: Vec3 get() = length.let { if (it > 0) Vec3(x / it, y / it, z / it) else ZERO }
  operator fun plus(b: Vec3) = Vec3(x + b.x, y + b.y, z + b.z)
  operator fun times(s: Double) = Vec3(x * s, y * s, z * s)
  fun dot(b: Vec3) = x * b.x + y * b.y + z * b.z

  companion object {
    val ZERO = Vec3(0.0, 0.0, 0.0)
    val UP = Vec3(0.0, 0.0, 1.0)
  }
}

data class HeadSample(
    val timestampNs: Long,
    val orientation: Quat,
    /** Specific force in the device frame (points "up" when still), any units. */
    val accelerometer: Vec3? = null,
    /** Angular rate in the device frame, rad/s. */
    val gyroscope: Vec3? = null,
)

class HeadMath {
  private var upSumA = Vec3.ZERO   // quaternion as device -> world
  private var upSumB = Vec3.ZERO   // quaternion as world -> device
  private var upCount = 0
  var useInverse = false; private set
  var conventionLocked = false; private set
  private var maxTurnSeenDeg = 0.0
  private var firstRaw: Quat? = null

  private var signEvidence = 0.0
  var autoSign = 1.0; private set

  // Stored as received, so they stay valid if the convention guess changes.
  private var referenceRaw: Quat? = null
  private data class Last(val raw: Quat, val t: Long, val twist: Double)
  private var last: Last? = null
  var worldUp = Vec3.UP; private set

  val isCalibrated: Boolean get() = referenceRaw != null

  private fun toWorld(raw: Quat) = if (useInverse) raw.conjugate else raw

  /**
   * Feed a sample. Returns the head turn since calibration in compass sense
   * (positive = turned to starboard / clockwise), or null before calibration.
   */
  fun ingest(s: HeadSample): Double? {
    val raw = s.orientation.normalized
    learnConvention(raw, s.accelerometer)
    val q = toWorld(raw)
    val refRaw = referenceRaw
    if (refRaw == null) {
      last = Last(raw, s.timestampNs, 0.0)
      return null
    }
    val ccw = twistDegrees(toWorld(refRaw), q, worldUp)
    learnSign(q, ccw, s)
    last = Last(raw, s.timestampNs, ccw)
    // Compass bearings grow clockwise; a counter-clockwise twist about "up" is a turn to port.
    return -ccw * autoSign
  }

  /** Make the current orientation "looking at the bow". */
  fun calibrate() {
    referenceRaw = last?.raw
    last = last?.copy(twist = 0.0)
  }

  private fun learnConvention(q: Quat, accel: Vec3?) {
    val p = firstRaw
    if (p != null) {
      val d = min(1.0, abs(p.w * q.w + p.x * q.x + p.y * q.y + p.z * q.z))
      maxTurnSeenDeg = max(maxTurnSeenDeg, 2 * acos(d) * 180 / PI)
    } else {
      firstRaw = q
    }
    if (accel == null || accel.length <= 0.1) return
    val g = accel.normalized
    upSumA += q.rotate(g)
    upSumB += q.conjugate.rotate(g)
    upCount++
    // Wander = how far the average unit "up" vector falls short of 1 (0 = never moved).
    val wanderA = 1 - upSumA.length / upCount
    val wanderB = 1 - upSumB.length / upCount
    if (!conventionLocked) {
      val clearDifference = max(wanderA, wanderB) > 0.003
      if (clearDifference) useInverse = wanderB < wanderA * 0.5
      if (maxTurnSeenDeg > 40 && upCount >= 30 && clearDifference) conventionLocked = true
    }
    val sum = if (useInverse) upSumB else upSumA
    if (sum.length > 0) worldUp = sum.normalized
  }

  private fun learnSign(q: Quat, twist: Double, s: HeadSample) {
    val gyro = s.gyroscope ?: return
    val prev = last ?: return
    if (s.timestampNs <= prev.t) return
    val dt = (s.timestampNs - prev.t) / 1e9
    if (dt <= 0 || dt >= 0.5) return
    val upDevice = q.conjugate.rotate(worldUp)
    val gyroRate = gyro.dot(upDevice) * 180 / PI
    var dTwist = twist - prev.twist
    if (dTwist > 180) dTwist -= 360
    if (dTwist < -180) dTwist += 360
    val twistRate = dTwist / dt
    if (abs(gyroRate) <= 15 || abs(twistRate) <= 15) return
    signEvidence += if (gyroRate * twistRate > 0) 1.0 else -1.0
    if (signEvidence > 20) { autoSign = 1.0; signEvidence = 20.0 }
    if (signEvidence < -20) { autoSign = -1.0; signEvidence = -20.0 }
  }

  companion object {
    /** Angle (degrees, CCW about `up`) of the rotation taking a to b, ignoring tilt. */
    fun twistDegrees(a: Quat, b: Quat, up: Vec3): Double {
      val r = b * a.conjugate
      val p = Vec3(r.x, r.y, r.z).dot(up)
      var angle = 2 * atan2(p, r.w) * 180 / PI
      if (angle > 180) angle -= 360
      if (angle < -180) angle += 360
      return angle
    }
  }
}
