//
// ContentView.swift
//
// The phone screen: what the lens shows, connection status, and head controls.
// Imports SwiftUI only (not MWDATDisplay) so Text/Image/Button are SwiftUI's.
//

import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel
  @State private var showSettings = false

  private var glasses: GlassesController { model.glasses }
  private var head: HeadTracker { model.head }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          lensPreview
          statusCard
          glassesControls
          headControls
          if model.frame.alarmTitle != nil {
            Button(role: .destructive) { model.acknowledgeAlarm() } label: {
              Label("Acknowledge alarm", systemImage: "bell.slash")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
          }
          performance
        }
        .padding()
      }
      .navigationTitle("TZ Glasses")
      .toolbar {
        Button { showSettings = true } label: { Image(systemName: "gearshape") }
          .accessibilityLabel("Settings")
      }
      .sheet(isPresented: $showSettings) { SettingsView(model: model) }
    }
    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
  }

  // MARK: Lens

  private var lensPreview: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Lens view").font(.headline)
      Group {
        if let img = model.preview {
          Image(uiImage: img).resizable().interpolation(.medium)
        } else {
          Color.black
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.3)))
      Text("Black is see-through on the glasses.")
        .font(.footnote).foregroundStyle(.secondary)

      if glasses.simulated, let view = glasses.simulatedPreview {
        Text("Simulated glasses (what was actually sent)").font(.subheadline).padding(.top, 8)
        SimulatedGlassesView(view: view)
          .aspectRatio(1, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  // MARK: Status

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      StatusRow(title: "Glasses", value: glassesText, state: glasses.isConnected ? .good : glassesFailed ? .bad : .waiting)
      StatusRow(title: "Head tracking", value: headText, state: head.headTurnDeg != nil || head.source == .manual ? .good : .waiting)
      StatusRow(title: "Boat data", value: boatText, state: boatState)
    }
    .padding()
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
  }

  private var glassesFailed: Bool {
    if case .failed = glasses.phase { return true }
    return false
  }

  private var glassesText: String {
    switch glasses.phase {
    case .idle: glasses.isRegistered ? "Registered, not connected" : "Not registered with Meta AI"
    case .connecting: "Connecting…"
    case .connected: (glasses.deviceName ?? "Connected") + (glasses.simulated ? " (simulated)" : "")
    case .failed(let reason): reason
    }
  }

  private var headText: String {
    if head.source == .manual { return "Slider" }
    guard head.headTurnDeg != nil else { return head.status }
    let turn = Int((head.turnFromBow(boatHeading: model.snapshot?.referenceHeading) ?? 0).rounded())
    let where_ = turn == 0 ? "at the bow" : "\(abs(turn))° to \(turn < 0 ? "port" : "starboard")"
    return "\(head.source.label): looking \(where_)"
  }

  private var boatText: String {
    if model.useDemoData { return "Demo data (Halifax Harbour)" }
    return model.bridge.status.text
  }

  private var boatState: StatusRow.State {
    if model.useDemoData { return .good }
    switch model.bridge.status {
    case .live: return .good
    case .connecting, .noData: return .waiting
    case .off, .failed: return .bad
    }
  }

  // MARK: Glasses

  private var glassesControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Glasses").font(.headline)
      HStack {
        if !glasses.isRegistered {
          Button("Register with Meta AI") { Task { await glasses.register() } }
            .buttonStyle(.borderedProminent)
        } else if glasses.isConnected || glasses.phase == .connecting {
          Button("Disconnect") { glasses.disconnect() }
            .buttonStyle(.bordered)
        } else {
          Button("Connect glasses") { Task { await glasses.connect() } }
            .buttonStyle(.borderedProminent)
        }
        if glasses.requiresGlassesAppUpdate {
          Button("Update glasses app") { Task { await glasses.openGlassesAppUpdate() } }
            .buttonStyle(.bordered)
        }
      }
    }
  }

  // MARK: Head

  private var headControls: some View {
    // `model.head` is a `let` reference to an @Observable class, so bind through @Bindable.
    @Bindable var head = model.head
    return VStack(alignment: .leading, spacing: 12) {
      Text("Head direction").font(.headline)
      Picker("Source", selection: $head.source) {
        ForEach(HeadSource.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .onChange(of: head.source) { model.saveHeadSettings() }

      if head.source == .manual {
        Slider(value: $head.manualTurnDeg, in: -180...180, step: 1)
        Text(manualText).font(.subheadline).foregroundStyle(.secondary)
      } else if head.source == .phone {
        Text("Hold the phone upright and point it like you're looking. Tap Re-center while pointing at the bow.")
          .font(.footnote).foregroundStyle(.secondary)
      }

      HStack {
        Button { model.head.nudge(-2) } label: { Image(systemName: "chevron.left") }
          .buttonStyle(.bordered).accessibilityLabel("Fine tune 2 degrees to port")
        Button { model.head.recenter() } label: {
          Label("Re-center on bow", systemImage: "scope").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        Button { model.head.nudge(2) } label: { Image(systemName: "chevron.right") }
          .buttonStyle(.bordered).accessibilityLabel("Fine tune 2 degrees to starboard")
      }
      if head.fineTuneDeg != 0 {
        Text("Fine tune \(Int(head.fineTuneDeg))°").font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  private var manualText: String {
    let t = Int(head.manualTurnDeg)
    return t == 0 ? "Looking at the bow" : "Looking \(abs(t))° to \(t < 0 ? "port" : "starboard")"
  }

  // MARK: Performance

  private var performance: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Glasses link").font(.headline)
      Group {
        Text("Lens mode: \(model.lensMode.label)")
        Text(String(format: "%.0f ms per update · %.1f updates/s", glasses.lastSendMs, glasses.updatesPerSecond))
        Text("Motion: \(glasses.motionStatus) · \(Int(head.samplesPerSecond)) samples/s")
        Text("Gestures: \(glasses.inputsStatus)")
        if let err = glasses.lastSendError { Text("Last error: \(err)").foregroundStyle(.red) }
      }
      .font(.footnote.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }
}

struct StatusRow: View {
  enum State { case good, waiting, bad }
  let title: String
  let value: String
  let state: State

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Circle()
        .fill(state == .good ? Color.green : state == .waiting ? Color.orange : Color.red)
        .frame(width: 10, height: 10)
      Text(title).font(.subheadline.weight(.semibold))
      Spacer()
      Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
  }
}

/// Hosts the simulated glasses' UIKit preview view.
struct SimulatedGlassesView: UIViewRepresentable {
  let view: UIView
  func makeUIView(context: Context) -> UIView { view }
  func updateUIView(_ uiView: UIView, context: Context) {}
}
