//
// TZGlassesApp.swift
//
// TZ Glasses: TimeZero navigation and AIS as head-tracked labels on
// Meta Ray-Ban Display glasses.
//

import MWDATCore
import SwiftUI

@main
struct TZGlassesApp: App {
  @State private var model: AppModel

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[TZGlasses] Couldn't configure the Wearables SDK: \(error)")
    }
    _model = State(wrappedValue: AppModel())
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .onAppear { model.start() }
        .onOpenURL { url in
          Task { await model.glasses.handle(url: url) }
        }
    }
  }
}
