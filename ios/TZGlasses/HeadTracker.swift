//
// HeadTracker.swift
//
// Works out the true bearing the wearer is looking at.
//
//   gaze = boat heading when calibrated + head turn since calibration + fine tune
//
// Using the heading at calibration (not the live heading) is deliberate: the
// glasses' orientation is measured against the world, so when the boat turns
// under a still head, the head's world direction does not change and labels
// stay on their targets.
//
// Sources:
//   .glasses - Motion samples from the Ray-Ban Display (the real thing)
//   .phone   - the iPhone's own motion sensors; hold the phone up like a
//              viewfinder to test at your desk
//   .manual  - a slider on the phone, no sensors
//

import CoreMotion
import Foundation
import Observation

enum HeadSource: String, CaseIterable, Identifiable, Sendable {
  case glasses, phone, manual
  var id: String { rawValue }
  var label: String {
    switch self {
    case .glasses: "Glasses"
    case .phone: "Phone"
    case .manual: "Slider"
    }
  }
}

@Observable
@MainActor
final class HeadTracker {
  var source: HeadSource = .glasses {
    didSet { if source != oldValue { sourceChanged() } }
  }
  /// Slider value for .manual, degrees from the bow (negative = port).
  var manualTurnDeg: Double = 0
  /// Small correction the wearer can add by swiping (degrees, positive = starboard).
  var fineTuneDeg: Double = 0
  var reverseDirection = false

  private(set) var headTurnDeg: Double?
  private(set) var status = "Waiting for motion data"
  private(set) var samplesPerSecond: Double = 0
  private(set) var lastSampleAt: Date?

  @ObservationIgnored private var math = HeadMath()
  @ObservationIgnored private var headingAtCalibration: Double?
  @ObservationIgnored private var pendingCalibration = true
  @ObservationIgnored private let phoneMotion = CMMotionManager()
  @ObservationIgnored private var rateCount = 0
  @ObservationIgnored private var rateWindowStart = Date()

  /// Called with the boat's current heading whenever it is known.
  @ObservationIgnored var currentBoatHeading: () -> Double? = { nil }

  init() {}

  /// True bearing the wearer is looking at, or nil if not known yet.
  func gaze(boatHeading: Double?) -> Double? {
    switch source {
    case .manual:
      guard let h = boatHeading else { return nil }
      return Geo.wrap360(h + manualTurnDeg + fineTuneDeg)
    case .glasses, .phone:
      guard let turn = headTurnDeg else { return nil }
      if headingAtCalibration == nil, let h = boatHeading {
        // Calibrated before the boat's heading arrived: assume the boat hasn't turned since.
        headingAtCalibration = h
      }
      let base = headingAtCalibration ?? boatHeading ?? 0
      let signed = reverseDirection ? -turn : turn
      return Geo.wrap360(base + signed + fineTuneDeg)
    }
  }

  /// Head turn relative to the bow right now (for the phone UI), degrees.
  func turnFromBow(boatHeading: Double?) -> Double? {
    guard let g = gaze(boatHeading: boatHeading), let h = boatHeading else {
      return source == .manual ? manualTurnDeg : headTurnDeg
    }
    return Geo.wrap180(g - h)
  }

  /// "I'm looking at the bow now."
  func recenter() {
    fineTuneDeg = 0
    if source == .manual {
      manualTurnDeg = 0
      return
    }
    headingAtCalibration = currentBoatHeading()
    math.calibrate()
    pendingCalibration = !math.isCalibrated
    headTurnDeg = math.isCalibrated ? 0 : nil
    status = math.isCalibrated ? "Tracking" : "Waiting for motion data"
  }

  func nudge(_ deg: Double) { fineTuneDeg += deg }

  /// Feed a sample from the glasses (via GlassesController).
  func ingestGlasses(_ sample: HeadSample) {
    guard source == .glasses else { return }
    ingest(sample)
  }

  private func ingest(_ sample: HeadSample) {
    let turn = math.ingest(sample)
    if pendingCalibration {
      // First samples: assume the wearer is facing the bow until they recenter.
      recenter()
    } else {
      headTurnDeg = turn
    }
    countRate()
  }

  private func countRate() {
    lastSampleAt = Date()
    rateCount += 1
    let elapsed = Date().timeIntervalSince(rateWindowStart)
    if elapsed >= 1 {
      samplesPerSecond = Double(rateCount) / elapsed
      rateCount = 0
      rateWindowStart = Date()
    }
  }

  private func sourceChanged() {
    phoneMotion.stopDeviceMotionUpdates()
    math.reset()
    headTurnDeg = nil
    pendingCalibration = true
    fineTuneDeg = 0
    samplesPerSecond = 0
    switch source {
    case .manual:
      status = "Using the slider"
    case .glasses:
      status = "Waiting for motion data from the glasses"
    case .phone:
      startPhoneMotion()
    }
  }

  private func startPhoneMotion() {
    guard phoneMotion.isDeviceMotionAvailable else {
      status = "This phone has no motion sensors"
      return
    }
    status = "Using the phone's motion sensors"
    phoneMotion.deviceMotionUpdateInterval = 1.0 / 30
    phoneMotion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
      guard let self, let m = motion else { return }
      let q = m.attitude.quaternion
      // CoreMotion gravity points down; flip it to match an accelerometer at rest (points up).
      let sample = HeadSample(
        timestampNs: Int64(m.timestamp * 1e9),
        orientation: Quat(w: q.w, x: q.x, y: q.y, z: q.z),
        accelerometer: Vec3(x: -m.gravity.x, y: -m.gravity.y, z: -m.gravity.z),
        gyroscope: Vec3(x: m.rotationRate.x, y: m.rotationRate.y, z: m.rotationRate.z)
      )
      MainActor.assumeIsolated { self.ingest(sample) }
    }
  }

  /// Call once at launch to start whichever source is selected.
  func start() { sourceChanged() }
}
