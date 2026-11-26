//
// SettingsView.swift
//

import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var address = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle("Use demo data", isOn: $model.useDemoData)
          if !model.useDemoData {
            TextField("Nav PC address, e.g. 192.168.1.20", text: $address)
              .keyboardType(.numbersAndPunctuation)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onSubmit { model.bridgeAddress = address }
            Button("Connect") { model.bridgeAddress = address }
            Text(model.bridge.status.text).font(.footnote).foregroundStyle(.secondary)
          }
        } header: {
          Text("Boat data")
        } footer: {
          Text("The address the TZ Bridge prints when it starts. The phone must be on the boat's WiFi.")
        }

        Section {
          Picker("Lens mode", selection: $model.lensMode) {
            ForEach(LensMode.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          VStack(alignment: .leading) {
            Text("Max updates per second: \(model.maxUpdatesPerSecond, specifier: "%.0f")")
            Slider(value: $model.maxUpdatesPerSecond, in: 1...15, step: 1)
          }
          Toggle("Simulated glasses", isOn: Binding(
            get: { model.glasses.simulated },
            set: { model.glasses.useSimulatedGlasses($0) }
          ))
        } header: {
          Text("Glasses")
        } footer: {
          Text("Picture sends the HUD as an image (colour, exact positions). Text uses Meta's layout components, which send less data and may update faster. Try both on the glasses and compare the update rate on the main screen.")
        }

        Section {
          Picker("Lens look", selection: $model.hud.lensLook) {
            ForEach(LensLook.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          if model.hud.lensLook != .day {
            Toggle("Switch at sunset", isOn: $model.hud.lookAtSunset)
          }
        } header: {
          Text("Night")
        } footer: {
          Text("Night dims everything except marks, which glow, and alarms, which stay bright, so gear stands out without dazzling you. Night red does the same in red, to keep your night vision. With Switch at sunset on, the lens stays on Day while the sun is up (worked out from the boat's position) and goes to your night look after dark. Picture lens mode only.")
        }

        Section {
          Toggle("Reverse left and right", isOn: Binding(
            get: { model.head.reverseDirection },
            set: { model.head.reverseDirection = $0; model.saveHeadSettings() }
          ))
          VStack(alignment: .leading) {
            Text("Display width: \(model.hud.fovDeg, specifier: "%.0f")°")
            Slider(value: $model.hud.fovDeg, in: 12...40, step: 1)
          }
        } header: {
          Text("Head tracking")
        } footer: {
          Text("Turn on Reverse if labels move the wrong way when you turn your head. Adjust Display width until a label stays on its ship as you turn: too wide and labels move faster than the ship, too narrow and they lag behind.")
        }

        Section {
          Toggle("Fixed heading when there's no compass", isOn: $model.useFixedHeading)
          if model.useFixedHeading {
            VStack(alignment: .leading) {
              Text("Bow points \(Int(model.fixedHeadingDeg.rounded()) % 360)° true")
              Slider(value: $model.fixedHeadingDeg, in: 0...359, step: 1)
            }
            Stepper("Fine tune", value: $model.fixedHeadingDeg, in: 0...359, step: 1)
          }
        } header: {
          Text("Boat heading")
        } footer: {
          Text("For a boat with no heading sensor, tied up or stopped, so neither heading nor course comes from TimeZero. Set which way the bow points (read it off the chart). It's only used while the boat sends neither, and the lens shows SET next to the heading. Once the boat moves, its course takes over.")
        }

        Section {
          Stepper("Eye height \(model.hud.eyeHeightM, specifier: "%.1f") m",
                  value: $model.hud.eyeHeightM, in: 1...10, step: 0.5)
          VStack(alignment: .leading) {
            Text("Horizon: \(model.hud.horizonDeg, specifier: "%+.1f")°")
            Slider(value: $model.hud.horizonDeg, in: -6...6, step: 0.5)
          }
        } header: {
          Text("On the water")
        } footer: {
          Text("Eye height above the water where you stand (usually 2–6 m). Labels sit on the water: far ones near the horizon, near ones lower. Move Horizon until a far ship's marker sits on the real horizon; + moves labels down.")
        }

        Section {
          sourceRow("AIS", key: "AIS")
          sourceRow("ARPA (radar)", key: "ARPA")
          sourceRow("Online AIS", key: "ONLINE")
          Button("Reset colours") { model.hud.sourceColors = HUDSettings.defaultSourceColors }
        } header: {
          Text("Targets")
        } footer: {
          Text("ARPA targets are boats tracked by your radar, including ones without AIS. Online AIS comes over the internet (TimeZero 5) and can be minutes old: it always shows its age and never raises a collision alarm. Hidden targets don't raise alarms either. Colours apply in Picture mode; alarms always show amber or red.")
        }

        Section("Collision alarms") {
          Stepper("Caution under \(model.hud.cpaCautionNm, specifier: "%.2f") nm",
                  value: $model.hud.cpaCautionNm, in: 0.1...3, step: 0.05)
          Stepper("Danger under \(model.hud.cpaDangerNm, specifier: "%.2f") nm",
                  value: $model.hud.cpaDangerNm, in: 0.05...2, step: 0.05)
        }

        Section {
          Toggle("Show route", isOn: $model.hud.showRoute)
          Toggle("Animate rainbow road", isOn: $model.hud.animateRoute)
            .disabled(!model.hud.showRoute)
        } header: {
          Text("Route")
        } footer: {
          Text("The route TimeZero is navigating lies on the water as a rainbow road; legs already sailed turn grey, and a route that isn't active shows as a dashed line. Picture mode only. Animating sends a new picture several times a second: turn it off if the glasses lag.")
        }

        Section {
          Toggle("Show tracks", isOn: $model.hud.showTracks)
          Stepper("Within \(model.hud.trackRangeNm, specifier: "%.0f") nm",
                  value: $model.hud.trackRangeNm, in: 1...20, step: 1)
            .disabled(!model.hud.showTracks)
        } header: {
          Text("Tracks")
        } footer: {
          Text("Where this boat has been (amber) and saved tracks exported from TimeZero as GPX (blue, dotted), lying on the water. Picture mode only.")
        }

        Section("TimeZero marks") {
          Toggle("Show marks", isOn: $model.hud.showMarks)
          Stepper("Within \(model.hud.markRangeNm, specifier: "%.0f") nm",
                  value: $model.hud.markRangeNm, in: 1...20, step: 1)
        }

        Section {
          Toggle("Danger mark alarm", isOn: $model.hud.dangerMarkAlarm)
          Stepper("Warn within \(model.hud.dangerMarkNm, specifier: "%.2f") nm",
                  value: $model.hud.dangerMarkNm, in: 0.1...2, step: 0.05)
            .disabled(!model.hud.dangerMarkAlarm)
          Stepper("Passing closer than \(model.hud.dangerPassNm, specifier: "%.2f") nm",
                  value: $model.hud.dangerPassNm, in: 0.02...0.5, step: 0.02)
            .disabled(!model.hud.dangerMarkAlarm)
        } header: {
          Text("Danger marks")
        } footer: {
          Text("Sounds the alarm when the boat is heading for a danger mark: TimeZero's skull symbol, or a mark named like \"shoal\", \"rock\", \"wreck\" or \"danger\". It goes off when the mark is within the first distance and your course over ground passes closer than the second. The mark turns red; tap the glasses to silence it for 2 minutes.")
        }
      }
      .navigationTitle("Settings")
      .toolbar { Button("Done") { dismiss() } }
      .onAppear { address = model.bridgeAddress }
    }
  }

  /// Show/hide switch and label colour for one target source.
  private func sourceRow(_ title: String, key: String) -> some View {
    HStack {
      ColorPicker("", selection: Binding(
        get: { Color(HUDImageRenderer.color(hex: model.hud.sourceColors[key] ?? "") ?? .white) },
        set: { model.hud.sourceColors[key] = Self.hex(UIColor($0)) }
      ), supportsOpacity: false)
      .labelsHidden()
      sourceToggle(title, key: key)
    }
  }

  private static func hex(_ c: UIColor) -> String {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getRed(&r, green: &g, blue: &b, alpha: &a)
    func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
  }

  private func sourceToggle(_ title: String, key: String) -> some View {
    Toggle(title, isOn: Binding(
      get: { !model.hud.hiddenSources.contains(key) },
      set: { show in
        if show { model.hud.hiddenSources.remove(key) } else { model.hud.hiddenSources.insert(key) }
      }
    ))
  }
}
