//
// AppModel.swift
//
// Runs the loop: boat data + head direction -> HUDFrame -> phone preview and glasses.
// Sends to the glasses only when the picture changes, never overlapping sends, and
// no faster than the rate set in Settings.
//

import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AppModel {
  let bridge: BridgeClient
  let head: HeadTracker
  let glasses: GlassesController

  // Settings (saved between launches)
  var bridgeAddress: String { didSet { save(); if !useDemoData { bridge.connect(to: bridgeAddress) } } }
  var useDemoData: Bool { didSet { save(); applyDataSource() } }
  var lensMode: LensMode { didSet { save() } }
  var maxUpdatesPerSecond: Double { didSet { save() } }
  var hud: HUDSettings { didSet { save() } }
  /// For a boat with no compass that isn't moving (no heading, no course): the way the bow
  /// points, typed in. Only used while the boat sends neither.
  var useFixedHeading: Bool { didSet { save() } }
  var fixedHeadingDeg: Double { didSet { save() } }

  /// The boat data, with the fixed heading filled in when the boat sends no heading or course.
  var snapshot: BoatSnapshot? {
    guard var s = bridge.snapshot else { return nil }
    if fixedHeadingActive { s.own?.hdg = fixedHeadingDeg }
    return s
  }
  /// True while the fixed heading stands in for a missing one.
  var fixedHeadingActive: Bool {
    useFixedHeading && bridge.snapshot?.own != nil && bridge.snapshot?.referenceHeading == nil
  }

  private(set) var frame: HUDFrame = .waiting
  private(set) var preview: UIImage?
  private(set) var acknowledged: Set<String> = []

  @ObservationIgnored private var demo = DemoFeed()
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var demoLoop: Task<Void, Never>?
  @ObservationIgnored private var lastSentFrame: HUDFrame?
  @ObservationIgnored private var lastSentAt = Date.distantPast
  @ObservationIgnored private var lastPreviewAt = Date.distantPast
  @ObservationIgnored private var ackExpiry: [String: Date] = [:]
  @ObservationIgnored private let defaults = UserDefaults.standard
  /// This boat's track: the bridge's recording (or the demo's), extended as the boat moves.
  @ObservationIgnored private var ownTrack: [TrackPoint] = []
  @ObservationIgnored private var ownTrackSeed = ""

  /// Call after `Wearables.configure()`.
  init() {
    bridge = BridgeClient()
    head = HeadTracker()
    glasses = GlassesController()
    let d = UserDefaults.standard
    bridgeAddress = d.string(forKey: "bridgeAddress") ?? ""
    useDemoData = d.object(forKey: "useDemoData") as? Bool ?? true
    lensMode = LensMode(rawValue: d.string(forKey: "lensMode") ?? "") ?? .picture
    maxUpdatesPerSecond = d.object(forKey: "maxUpdatesPerSecond") as? Double ?? 4
    useFixedHeading = d.bool(forKey: "useFixedHeading")
    fixedHeadingDeg = d.object(forKey: "fixedHeadingDeg") as? Double ?? 0
    var s = HUDSettings()
    if let v = d.object(forKey: "fovDeg") as? Double { s.fovDeg = v }
    if let v = d.object(forKey: "cpaCautionNm") as? Double { s.cpaCautionNm = v }
    if let v = d.object(forKey: "cpaDangerNm") as? Double { s.cpaDangerNm = v }
    if let v = d.object(forKey: "markRangeNm") as? Double { s.markRangeNm = v }
    if let v = d.object(forKey: "showMarks") as? Bool { s.showMarks = v }
    if let v = d.object(forKey: "dangerMarkAlarm") as? Bool { s.dangerMarkAlarm = v }
    if let v = d.object(forKey: "dangerMarkNm") as? Double { s.dangerMarkNm = v }
    if let v = d.object(forKey: "dangerPassNm") as? Double { s.dangerPassNm = v }
    if let v = d.object(forKey: "eyeHeightM") as? Double { s.eyeHeightM = v }
    if let v = d.object(forKey: "horizonDeg") as? Double { s.horizonDeg = v }
    if let v = d.object(forKey: "showRoute") as? Bool { s.showRoute = v }
    if let v = d.object(forKey: "animateRoute") as? Bool { s.animateRoute = v }
    if let v = d.object(forKey: "showTracks") as? Bool { s.showTracks = v }
    if let v = d.object(forKey: "trackRangeNm") as? Double { s.trackRangeNm = v }
    if let v = d.stringArray(forKey: "hiddenSources") { s.hiddenSources = Set(v) }
    if let v = d.dictionary(forKey: "sourceColors") as? [String: String] { s.sourceColors.merge(v) { $1 } }
    hud = s
    head.reverseDirection = d.bool(forKey: "reverseDirection")
    if let src = HeadSource(rawValue: d.string(forKey: "headSource") ?? "") { head.source = src }

    head.currentBoatHeading = { [weak self] in self?.snapshot?.referenceHeading }
    glasses.onHeadSample = { [weak self] sample in self?.head.ingestGlasses(sample) }
    glasses.onGesture = { [weak self] g in self?.handle(g) }
  }

  func start() {
    guard loop == nil else { return }
    head.start()
    applyDataSource()
    loop?.cancel()
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.tick()
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  func saveHeadSettings() {
    defaults.set(head.reverseDirection, forKey: "reverseDirection")
    defaults.set(head.source.rawValue, forKey: "headSource")
  }

  private func save() {
    defaults.set(bridgeAddress, forKey: "bridgeAddress")
    defaults.set(useDemoData, forKey: "useDemoData")
    defaults.set(lensMode.rawValue, forKey: "lensMode")
    defaults.set(maxUpdatesPerSecond, forKey: "maxUpdatesPerSecond")
    defaults.set(useFixedHeading, forKey: "useFixedHeading")
    defaults.set(fixedHeadingDeg, forKey: "fixedHeadingDeg")
    defaults.set(hud.fovDeg, forKey: "fovDeg")
    defaults.set(hud.cpaCautionNm, forKey: "cpaCautionNm")
    defaults.set(hud.cpaDangerNm, forKey: "cpaDangerNm")
    defaults.set(hud.markRangeNm, forKey: "markRangeNm")
    defaults.set(hud.showMarks, forKey: "showMarks")
    defaults.set(hud.dangerMarkAlarm, forKey: "dangerMarkAlarm")
    defaults.set(hud.dangerMarkNm, forKey: "dangerMarkNm")
    defaults.set(hud.dangerPassNm, forKey: "dangerPassNm")
    defaults.set(hud.eyeHeightM, forKey: "eyeHeightM")
    defaults.set(hud.horizonDeg, forKey: "horizonDeg")
    defaults.set(hud.showRoute, forKey: "showRoute")
    defaults.set(hud.animateRoute, forKey: "animateRoute")
    defaults.set(hud.showTracks, forKey: "showTracks")
    defaults.set(hud.trackRangeNm, forKey: "trackRangeNm")
    defaults.set(Array(hud.hiddenSources), forKey: "hiddenSources")
    defaults.set(hud.sourceColors, forKey: "sourceColors")
  }

  private func applyDataSource() {
    demoLoop?.cancel()
    demoLoop = nil
    if useDemoData {
      bridge.disconnect()
      demo.reset()
      demoLoop = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          // Run the demo at 10x so things happen while you watch.
          self.bridge.inject(self.demo.step(seconds: 5))
          try? await Task.sleep(for: .milliseconds(500))
        }
      }
    } else {
      bridge.connect(to: bridgeAddress)
    }
  }

  // MARK: Gestures

  func handle(_ g: GlassesGesture) {
    switch g {
    case .recenter:
      // A tap while an alarm is showing acknowledges it; otherwise it re-centres.
      if frame.alarmTitle != nil { acknowledgeAlarm() } else { head.recenter() }
    case .acknowledge: acknowledgeAlarm()
    case .nudgeLeft: head.nudge(-2)
    case .nudgeRight: head.nudge(2)
    }
  }

  /// Silences the current alarm for 2 minutes (it comes back if the situation persists).
  func acknowledgeAlarm() {
    guard let snap = snapshot else { return }
    let now = Date()
    for t in snap.targets ?? [] where HUDBuilder.severity(of: t, hud) != .normal {
      ackExpiry[t.key] = now.addingTimeInterval(120)
    }
    for m in HUDBuilder.markThreats(snap, hud) {
      ackExpiry[m.mark.key] = now.addingTimeInterval(120)
    }
    refreshAcknowledged()
  }

  private func refreshAcknowledged() {
    let now = Date()
    ackExpiry = ackExpiry.filter { $0.value > now }
    acknowledged = Set(ackExpiry.keys)
  }

  // MARK: Own track

  /// Starts from the bridge's recorded track (it keeps recording while the app is closed)
  /// and adds a point every 10 m or so between fetches.
  private func recordOwnTrack(_ snap: BoatSnapshot?, _ userData: UserData?) {
    let now = Date().timeIntervalSince1970
    if let seed = userData?.ownTrack, !seed.isEmpty {
      let key = "\(userData?.version ?? 0)-\(seed.count)-\(seed.last?.t ?? 0)"
      if key != ownTrackSeed {
        let seedEnd = seed.last?.t ?? now
        ownTrack = seed + ownTrack.filter { ($0.t ?? 0) > seedEnd }
        ownTrackSeed = key
      }
    }
    guard let lat = snap?.own?.lat, let lon = snap?.own?.lon else { return }
    if let last = ownTrack.last {
      let d = LensProjector.local(lat: lat, lon: lon, fromLat: last.lat, fromLon: last.lon)
      let nm = hypot(d.x, d.y)
      if nm > 1 { ownTrack = []; ownTrackSeed = "" }   // jumped (demo restart, new position fix)
      else if nm < 0.005 { return }
    }
    ownTrack.append(TrackPoint(lat: lat, lon: lon, t: now))
    if ownTrack.count > 3000 { ownTrack = stride(from: 0, to: ownTrack.count, by: 2).map { ownTrack[$0] } }
  }

  // MARK: Loop

  private func tick() async {
    refreshAcknowledged()
    let snap = snapshot
    let gaze = head.gaze(boatHeading: snap?.referenceHeading)
    let userData = useDemoData ? demo.userData : bridge.userData
    recordOwnTrack(snap, userData)
    var f = HUDBuilder.build(snapshot: snap, gaze: gaze, settings: hud, acknowledged: acknowledged,
                             time: ProcessInfo.processInfo.systemUptime,
                             tracks: TrackInput(own: ownTrack, saved: userData?.tracks ?? []))
    if fixedHeadingActive, f.message == nil { f.headingText += " SET" }   // not from a compass
    frame = f

    let now = Date()
    if now.timeIntervalSince(lastPreviewAt) > 0.1 {
      preview = HUDImageRenderer.render(f, sourceColors: hud.sourceColors, scale: 1)
      lastPreviewAt = now
    }

    // Send to the glasses: changed (or 2 s heartbeat), within the rate limit, one at a time.
    let minInterval = 1.0 / max(0.5, maxUpdatesPerSecond)
    guard glasses.canSend, now.timeIntervalSince(lastSentAt) >= minInterval else { return }
    guard f != lastSentFrame || now.timeIntervalSince(lastSentAt) > 2 else { return }
    lastSentFrame = f
    lastSentAt = now
    let image = lensMode == .picture ? (preview ?? HUDImageRenderer.render(f, sourceColors: hud.sourceColors)) : nil
    let mode = lensMode
    Task { await self.glasses.send(frame: f, mode: mode, image: image) }
  }
}
