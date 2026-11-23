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
    var s = HUDSettings()
    if let v = d.object(forKey: "fovDeg") as? Double { s.fovDeg = v }
    if let v = d.object(forKey: "cpaCautionNm") as? Double { s.cpaCautionNm = v }
    if let v = d.object(forKey: "cpaDangerNm") as? Double { s.cpaDangerNm = v }
    if let v = d.object(forKey: "markRangeNm") as? Double { s.markRangeNm = v }
    if let v = d.object(forKey: "showMarks") as? Bool { s.showMarks = v }
    hud = s
    head.reverseDirection = d.bool(forKey: "reverseDirection")
    if let src = HeadSource(rawValue: d.string(forKey: "headSource") ?? "") { head.source = src }

    head.currentBoatHeading = { [weak self] in self?.bridge.snapshot?.referenceHeading }
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
    defaults.set(hud.fovDeg, forKey: "fovDeg")
    defaults.set(hud.cpaCautionNm, forKey: "cpaCautionNm")
    defaults.set(hud.cpaDangerNm, forKey: "cpaDangerNm")
    defaults.set(hud.markRangeNm, forKey: "markRangeNm")
    defaults.set(hud.showMarks, forKey: "showMarks")
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
    guard let snap = bridge.snapshot else { return }
    let now = Date()
    for t in snap.targets ?? [] where HUDBuilder.severity(of: t, hud) != .normal {
      ackExpiry[t.key] = now.addingTimeInterval(120)
    }
    refreshAcknowledged()
  }

  private func refreshAcknowledged() {
    let now = Date()
    ackExpiry = ackExpiry.filter { $0.value > now }
    acknowledged = Set(ackExpiry.keys)
  }

  // MARK: Loop

  private func tick() async {
    refreshAcknowledged()
    let snap = bridge.snapshot
    let gaze = head.gaze(boatHeading: snap?.referenceHeading)
    let f = HUDBuilder.build(snapshot: snap, gaze: gaze, settings: hud, acknowledged: acknowledged)
    frame = f

    let now = Date()
    if now.timeIntervalSince(lastPreviewAt) > 0.1 {
      preview = HUDImageRenderer.render(f, scale: 1)
      lastPreviewAt = now
    }

    // Send to the glasses: changed (or 2 s heartbeat), within the rate limit, one at a time.
    let minInterval = 1.0 / max(0.5, maxUpdatesPerSecond)
    guard glasses.canSend, now.timeIntervalSince(lastSentAt) >= minInterval else { return }
    guard f != lastSentFrame || now.timeIntervalSince(lastSentAt) > 2 else { return }
    lastSentFrame = f
    lastSentAt = now
    let image = lensMode == .picture ? (preview ?? HUDImageRenderer.render(f)) : nil
    let mode = lensMode
    Task { await self.glasses.send(frame: f, mode: mode, image: image) }
  }
}
