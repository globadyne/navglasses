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
          sourceToggle("AIS", key: "AIS")
          sourceToggle("ARPA (radar)", key: "ARPA")
        } header: {
          Text("Targets")
        } footer: {
          Text("ARPA targets are boats tracked by your radar, including ones without AIS. They show in orange; AIS targets in green. Hidden targets don't raise collision alarms.")
        }

        Section("Collision alarms") {
          Stepper("Caution under \(model.hud.cpaCautionNm, specifier: "%.2f") nm",
                  value: $model.hud.cpaCautionNm, in: 0.1...3, step: 0.05)
          Stepper("Danger under \(model.hud.cpaDangerNm, specifier: "%.2f") nm",
                  value: $model.hud.cpaDangerNm, in: 0.05...2, step: 0.05)
        }

        Section("TimeZero marks") {
          Toggle("Show marks", isOn: $model.hud.showMarks)
          Stepper("Within \(model.hud.markRangeNm, specifier: "%.0f") nm",
                  value: $model.hud.markRangeNm, in: 1...20, step: 1)
        }
      }
      .navigationTitle("Settings")
      .toolbar { Button("Done") { dismiss() } }
      .onAppear { address = model.bridgeAddress }
    }
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
