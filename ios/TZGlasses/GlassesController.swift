//
// GlassesController.swift
//
// Everything that talks to the Ray-Ban Display through Meta's Wearables Device
// Access Toolkit (SDK 1.1.0):
//   - registration with the Meta AI app
//   - the device session
//   - Display: sending lens content
//   - Motion (experimental): head orientation at 30 Hz
//   - Inputs (experimental): Neural Band / touchpad gestures
//   - simulated glasses (MockDeviceKit) for testing at a desk
//
// Follows the lifecycle in Meta's DisplayAccess sample: create session, wait for
// .started, then add capabilities; wait for DisplayState.started before sending.
//

import Foundation
import MWDATCore
import MWDATDisplay
import MWDATInputs
import MWDATMockDevice
import MWDATMotion
import Observation
import UIKit

/// What the wearer did with a gesture.
enum GlassesGesture: Sendable {
  case recenter, nudgeLeft, nudgeRight, acknowledge
}

@Observable
@MainActor
final class GlassesController {
  enum Phase: Equatable {
    case idle, connecting, connected
    case failed(String)
  }

  private(set) var registration: RegistrationState = .unavailable
  private(set) var phase: Phase = .idle
  private(set) var motionStatus = "Not started"
  private(set) var inputsStatus = "Not started"
  private(set) var deviceName: String?
  private(set) var requiresGlassesAppUpdate = false
  private(set) var simulated = false
  /// The simulated glasses' own rendering of what we sent (only with simulated glasses).
  private(set) var simulatedPreview: UIView?

  // Send performance, shown in the app so Picture and Text modes can be compared.
  private(set) var lastSendMs: Double = 0
  private(set) var updatesPerSecond: Double = 0
  private(set) var lastSendError: String?

  var isConnected: Bool { phase == .connected }
  var isRegistered: Bool { registration == .registered }

  @ObservationIgnored var onHeadSample: ((HeadSample) -> Void)?
  @ObservationIgnored var onGesture: ((GlassesGesture) -> Void)?

  @ObservationIgnored private let wearables: any WearablesInterface
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var display: Display?
  @ObservationIgnored private var motion: Motion?
  @ObservationIgnored private var inputs: Inputs?
  @ObservationIgnored private var displayReady = false
  @ObservationIgnored private var sending = false
  @ObservationIgnored private var tokens: [any AnyListenerToken] = []
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var mockGlasses: (any MockGlasses)?
  @ObservationIgnored private var sendTimes: [Date] = []

  init(wearables: any WearablesInterface = Wearables.shared) {
    self.wearables = wearables
    registrationTask = Task { [weak self] in
      guard let stream = self?.wearables.registrationStateStream() else { return }
      for await state in stream {
        guard let self else { return }
        self.registration = state
        if state == .available || state == .unavailable { self.disconnect() }
      }
    }
  }

  // MARK: Registration

  func register() async {
    do {
      try await wearables.startRegistration()
    } catch {
      phase = .failed("Couldn't start registration: \(error.localizedDescription)")
    }
  }

  /// Route Meta AI's callback URL to the SDK.
  func handle(url: URL) async {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else { return }
    do {
      _ = try await wearables.handleUrl(url)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  func openGlassesAppUpdate() async {
    try? await wearables.openDATGlassesAppUpdate()
  }

  // MARK: Simulated glasses

  /// Pairs a simulated Ray-Ban Display so the whole app can be tested without hardware.
  func useSimulatedGlasses(_ on: Bool) {
    disconnect()
    if on {
      MockDeviceKit.shared.enable()
      do {
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
        glasses.powerOn()
        glasses.don()
        mockGlasses = glasses
        simulatedPreview = glasses.services.display.createPreviewView()
        simulated = true
      } catch {
        phase = .failed("Couldn't create simulated glasses: \(error.localizedDescription)")
      }
    } else {
      mockGlasses = nil
      simulatedPreview = nil
      simulated = false
      MockDeviceKit.shared.disable()
    }
  }

  // MARK: Connect

  func connect() async {
    guard session == nil else { return }
    phase = .connecting
    requiresGlassesAppUpdate = false
    do {
      let selector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
      let session = try wearables.createSession(deviceSelector: selector)
      self.session = session

      let states = session.stateStream()
      tasks.append(Task { [weak self] in
        for await state in states {
          guard let self else { return }
          switch state {
          case .started:
            self.attachCapabilities(to: session)
          case .stopped:
            self.teardown()
            return
          case .idle, .starting, .paused, .stopping:
            break
          }
        }
      })
      let errors = session.errorStream()
      tasks.append(Task { [weak self] in
        for await error in errors {
          guard let self else { return }
          if error == .datAppOnTheGlassesUpdateRequired { self.requiresGlassesAppUpdate = true }
          self.phase = .failed(error.localizedDescription)
        }
      })

      try session.start()

      // Don't wait forever if the glasses are off or out of range.
      tasks.append(Task { [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard let self, self.phase == .connecting else { return }
        self.disconnect()
        self.phase = .failed("Glasses didn't respond. Check they're on, worn and connected in Meta AI.")
      })
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      teardown()
      requiresGlassesAppUpdate = true
      phase = .failed("The glasses need an update in the Meta AI app.")
    } catch DeviceSessionError.notRegistered {
      teardown()
      phase = .failed("Register with Meta AI first.")
    } catch {
      teardown()
      phase = .failed("Couldn't connect: \(error.localizedDescription)")
    }
  }

  func disconnect() {
    display?.stop()
    motion?.stop()
    session?.stop()
    teardown()
  }

  private func teardown() {
    tasks.forEach { $0.cancel() }
    tasks.removeAll()
    tokens.removeAll()
    display = nil
    motion = nil
    inputs = nil
    session = nil
    displayReady = false
    sending = false
    deviceName = nil
    motionStatus = "Not started"
    inputsStatus = "Not started"
    if case .failed = phase {} else { phase = .idle }
  }

  private func attachCapabilities(to session: DeviceSession) {
    deviceName = session.device?.nameOrId()

    // Display
    if display == nil {
      do {
        let d = try session.addDisplay()
        display = d
        tokens.append(d.statePublisher.listen { [weak self] state in
          Task { @MainActor in self?.displayStateChanged(state) }
        })
        d.start()
      } catch {
        phase = .failed("Couldn't open the display: \(error.localizedDescription)")
        return
      }
    }

    // Motion (experimental): head orientation.
    if motion == nil {
      do {
        if let m = try session.addMotion(configuration: MotionConfiguration(samplingRate: .hz30)) {
          motion = m
          tokens.append(m.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.motionStatus = "\(state)".capitalized }
          })
          tokens.append(m.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.motionStatus = error.description }
          })
          let samples = m.samples
          tasks.append(Task { [weak self] in
            // One motion feed can carry both the glasses and the Neural Band: two bodies moving
            // independently. Only the head counts. Unlabelled (.unknown) samples are used only
            // while no glasses-labelled sample has arrived, since some firmware leaves the source unset.
            var lastGlassesSample = Date.distantPast
            for await s in samples {
              switch s.source {
              case .neuralBand: continue
              case .glasses: lastGlassesSample = Date()
              case .unknown: if Date().timeIntervalSince(lastGlassesSample) < 2 { continue }
              }
              guard let self, let q = s.orientation else { continue }
              let sample = HeadSample(
                timestampNs: s.timestampNs,
                orientation: Quat(w: Double(q.w), x: Double(q.x), y: Double(q.y), z: Double(q.z)),
                accelerometer: s.accelerometer.map { Vec3(x: Double($0.x), y: Double($0.y), z: Double($0.z)) },
                gyroscope: s.gyroscope.map { Vec3(x: Double($0.x), y: Double($0.y), z: Double($0.z)) }
              )
              self.onHeadSample?(sample)
            }
          })
          m.start()
        } else {
          motionStatus = "Not available on these glasses"
        }
      } catch {
        motionStatus = "Not enabled for this app (\(error.localizedDescription))"
      }
    }

    // Inputs (experimental): gestures.
    if inputs == nil {
      do {
        if let i = try session.addInputs(configuration: InputsConfiguration(consumeBack: false)) {
          inputs = i
          inputsStatus = "Active"
          let events = i.events
          tasks.append(Task { [weak self] in
            for await event in events {
              guard let self else { return }
              switch event {
              case .select, .button:
                self.onGesture?(.recenter)
              case .nav(let direction, _, _):
                switch direction {
                case .left: self.onGesture?(.nudgeLeft)
                case .right: self.onGesture?(.nudgeRight)
                case .up, .down: self.onGesture?(.acknowledge)
                }
              case .back, .capture, .drag:
                break
              @unknown default:
                break
              }
            }
          })
          tokens.append(i.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.inputsStatus = error.description }
          })
        } else {
          inputsStatus = "Not available"
        }
      } catch {
        inputsStatus = "Not enabled for this app"
      }
    }
  }

  private func displayStateChanged(_ state: DisplayState) {
    switch state {
    case .started:
      displayReady = true
      phase = .connected
    case .starting:
      break
    case .stopping, .stopped:
      displayReady = false
      if phase == .connected { phase = .idle }
    }
  }

  // MARK: Sending

  /// True if a new frame can be sent now (connected and the previous send finished).
  var canSend: Bool { displayReady && !sending && display != nil }

  func send(frame: HUDFrame, mode: LensMode, image: UIImage?) async {
    guard canSend, let display else { return }
    sending = true
    defer { sending = false }
    let tap: @Sendable () -> Void = { [weak self] in
      Task { @MainActor in self?.onGesture?(.recenter) }
    }
    let started = Date()
    do {
      switch mode {
      case .picture:
        let img = image ?? HUDImageRenderer.render(frame)
        try await display.send(HUDDisplayLayout.picture(img, onTap: tap))
      case .text:
        try await display.send(HUDDisplayLayout.text(frame, onTap: tap))
      }
      lastSendError = nil
      let ms = Date().timeIntervalSince(started) * 1000
      lastSendMs = lastSendMs == 0 ? ms : lastSendMs * 0.8 + ms * 0.2
      let now = Date()
      sendTimes.append(now)
      sendTimes.removeAll { now.timeIntervalSince($0) > 3 }
      updatesPerSecond = Double(sendTimes.count) / 3
    } catch {
      lastSendError = (error as? DisplayError)?.description ?? error.localizedDescription
    }
  }
}
