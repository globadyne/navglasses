//
// HeadMath.swift
//
// Turns orientation samples (from the glasses, or the phone for testing) into
// "how far has the head turned left or right since the wearer looked at the bow".
//
// Pure maths, no SDK or UIKit types, mirrored in tests/test_head_math.py.
//
// Approach
// - Orientation arrives as a quaternion. Meta doesn't document whether it maps
//   device -> world or world -> device, so we work it out: the accelerometer at
//   rest points "up" in the device frame; rotated into the world it should stay
//   the same direction whichever way the head turns. The convention that keeps
//   it steadiest wins.
// - Head yaw is the "twist" of the rotation since calibration about that world
//   up axis. That isolates turning left and right from nodding and tilting.
// - The sign (which way is starboard) is confirmed against the gyroscope, and
//   can be reversed by hand in Settings.
//

import Foundation

struct Quat: Equatable, Sendable {
  var w: Double, x: Double, y: Double, z: Double

  static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

  var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

  var normalized: Quat {
    let n = (w * w + x * x + y * y + z * z).squareRoot()
    return n > 0 ? Quat(w: w / n, x: x / n, y: y / n, z: z / n) : .identity
  }

  static func * (a: Quat, b: Quat) -> Quat {
    Quat(
      w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
      x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
      y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
      z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
    )
  }

  /// Rotate a vector by this (unit) quaternion.
  func rotate(_ v: Vec3) -> Vec3 {
    let p = Quat(w: 0, x: v.x, y: v.y, z: v.z)
    let r = self * p * conjugate
    return Vec3(x: r.x, y: r.y, z: r.z)
  }
}

struct Vec3: Equatable, Sendable {
  var x: Double, y: Double, z: Double
  static let zero = Vec3(x: 0, y: 0, z: 0)
  static let up = Vec3(x: 0, y: 0, z: 1)
  var length: Double { (x * x + y * y + z * z).squareRoot() }
  var normalized: Vec3 { let l = length; return l > 0 ? Vec3(x: x / l, y: y / l, z: z / l) : .zero }
  static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
  static func * (a: Vec3, s: Double) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
  func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
}

struct HeadSample: Sendable {
  var timestampNs: Int64
  var orientation: Quat
  /// Specific force in the device frame (points "up" when still), any units.
  var accelerometer: Vec3?
  /// Angular rate in the device frame, rad/s.
  var gyroscope: Vec3?
}

struct HeadMath: Sendable {
  // Convention detection: running sums of the world "up" vector under each convention.
  private var upSumA = Vec3.zero   // treat quaternion as device -> world
  private var upSumB = Vec3.zero   // treat quaternion as world -> device
  private var upCount = 0
  private(set) var useInverse = false
  private(set) var conventionLocked = false
  // Furthest the head has turned from where it started. The convention can only be
  // told apart once the head really moves (sensor jitter mustn't count).
  private var maxTurnSeenDeg = 0.0
  private var firstRaw: Quat?

  // Sign check: does a positive twist match the gyroscope's rotation about up?
  private var signEvidence = 0.0
  private(set) var autoSign = 1.0

  // Stored as received, so they stay valid if the convention guess changes.
  private var referenceRaw: Quat?
  private var last: (raw: Quat, t: Int64, twist: Double)?
  private(set) var worldUp = Vec3.up

  var isCalibrated: Bool { referenceRaw != nil }

  private func toWorld(_ raw: Quat) -> Quat { useInverse ? raw.conjugate : raw }

  /// Feed a sample. Returns the head turn since calibration in compass sense
  /// (positive = turned to starboard / clockwise), or nil before calibration.
  mutating func ingest(_ s: HeadSample) -> Double? {
    let raw = s.orientation.normalized
    learnConvention(raw, s.accelerometer)
    let q = toWorld(raw)

    guard let refRaw = referenceRaw else {
      last = (raw, s.timestampNs, 0)
      return nil
    }
    let ccw = Self.twistDegrees(from: toWorld(refRaw), to: q, about: worldUp)
    learnSign(q: q, twist: ccw, sample: s)
    last = (raw, s.timestampNs, ccw)
    // Compass bearings grow clockwise; a counter-clockwise twist about "up" is a turn to port.
    return -ccw * autoSign
  }

  /// Make the current orientation "looking at the bow".
  mutating func calibrate() {
    referenceRaw = last?.raw
    if let l = last { last = (l.raw, l.t, 0) }
  }

  mutating func reset() { self = HeadMath() }

  /// Angle (degrees, counter-clockwise about `up`) of the rotation that takes `a` to `b`,
  /// ignoring any tilt. Both quaternions map device -> world.
  static func twistDegrees(from a: Quat, to b: Quat, about up: Vec3) -> Double {
    let r = b * a.conjugate            // rotation in the world frame
    let p = Vec3(x: r.x, y: r.y, z: r.z).dot(up)
    var angle = 2 * atan2(p, r.w) * 180 / .pi
    if angle > 180 { angle -= 360 }
    if angle < -180 { angle += 360 }
    return angle
  }

  private mutating func learnConvention(_ q: Quat, _ accel: Vec3?) {
    if let p = firstRaw {
      let d = min(1, abs(p.w * q.w + p.x * q.x + p.y * q.y + p.z * q.z))
      maxTurnSeenDeg = max(maxTurnSeenDeg, 2 * acos(d) * 180 / .pi)
    } else {
      firstRaw = q
    }
    guard let a = accel, a.length > 0.1 else { return }
    let g = a.normalized
    let upA = q.rotate(g)
    let upB = q.conjugate.rotate(g)
    upSumA = upSumA + upA
    upSumB = upSumB + upB
    upCount += 1
    // Wander = how far the average unit "up" vector falls short of 1 (0 = never moved).
    // The right convention only wanders by sensor noise; the wrong one swings with the head.
    let wanderA = 1 - upSumA.length / Double(upCount)
    let wanderB = 1 - upSumB.length / Double(upCount)
    if !conventionLocked {
      let clearDifference = max(wanderA, wanderB) > 0.003
      if clearDifference { useInverse = wanderB < wanderA * 0.5 }
      // Decide once the head has turned well away from where it started.
      if maxTurnSeenDeg > 40 && upCount >= 30 && clearDifference { conventionLocked = true }
    }
    let sum = useInverse ? upSumB : upSumA
    if sum.length > 0 { worldUp = sum.normalized }
  }

  private mutating func learnSign(q: Quat, twist: Double, sample s: HeadSample) {
    guard let gyro = s.gyroscope, let prev = last, s.timestampNs > prev.t else { return }
    let dt = Double(s.timestampNs - prev.t) / 1e9
    guard dt > 0, dt < 0.5 else { return }
    // Gyro rate about the up axis, expressed in the device frame.
    let upDevice = q.conjugate.rotate(worldUp)
    let gyroRate = gyro.dot(upDevice) * 180 / .pi           // deg/s, counter-clockwise positive
    var dTwist = twist - prev.twist
    if dTwist > 180 { dTwist -= 360 }
    if dTwist < -180 { dTwist += 360 }
    let twistRate = dTwist / dt
    guard abs(gyroRate) > 15, abs(twistRate) > 15 else { return }  // only clear head turns
    signEvidence += gyroRate * twistRate > 0 ? 1 : -1
    if signEvidence > 20 { autoSign = 1; signEvidence = 20 }
    if signEvidence < -20 { autoSign = -1; signEvidence = -20 }
  }
}
