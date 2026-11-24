//
// HUDDisplayLayout.swift
//
// Builds the Display content sent to the glasses. Kept in its own file that
// imports MWDATDisplay but not SwiftUI, because both define Text, Image and
// Button (Meta's guidance).
//
// Two modes, switchable in Settings, so they can be compared on real glasses:
//
//   .picture - the HUD drawn as one 600 x 600 image: full colour, exact placement,
//              but a larger Bluetooth transfer per update.
//   .text    - Meta's own components (rows, text, icons). Small transfers, so it
//              can update faster, but only two text colours and approximate
//              placement: each label is pushed sideways with flexible spacers.
//

import MWDATDisplay
import UIKit

enum LensMode: String, CaseIterable, Identifiable, Sendable {
  case picture, text
  var id: String { rawValue }
  var label: String { self == .picture ? "Picture" : "Text" }
}

enum HUDDisplayLayout {
  static func picture(_ image: UIImage, onTap: @escaping @Sendable () -> Void) -> FlexBox {
    FlexBox(direction: .column) {
      Image(image: image, sizePreset: .fill, cornerRadius: .none)
    }
    .onTap(onTap)
  }

  static func text(_ f: HUDFrame, onTap: @escaping @Sendable () -> Void) -> FlexBox {
    FlexBox(direction: .column, spacing: 10) {
      // Top strip
      FlexBox(direction: .row, crossAlignment: .center) {
        Text(f.headingText, style: .meta)
        FlexBox {}.flexGrow(1)
        Text(f.stale ? "NO DATA" : f.gazeText, style: .meta, color: .secondary)
        FlexBox {}.flexGrow(1)
        Text(f.speedText, style: .meta)
      }

      if let message = f.message {
        Text(message, style: .body)
      }

      // One row per label, slid sideways to where it sits in the view.
      for item in f.items.prefix(3) {
        FlexBox(direction: .row, crossAlignment: .center) {
          FlexBox {}.flexGrow(Float(max(0.01, item.x)) * 100)
          FlexBox(direction: .column, crossAlignment: .center) {
            Text(item.title, style: item.severity == .normal ? .body : .heading)
            Text(item.detail, style: .meta, color: item.severity == .normal ? .secondary : .primary)
          }
          FlexBox {}.flexGrow(Float(max(0.01, 1 - item.x)) * 100)
        }
      }

      // Marks fill any rows left (no icons or lines here, so one line of text each).
      for m in f.marks.prefix(max(0, 4 - min(3, f.items.count))) {
        FlexBox(direction: .row, crossAlignment: .center) {
          FlexBox {}.flexGrow(Float(max(0.01, m.x)) * 100)
          Text("\(m.title) \(m.detail)", style: .meta, color: .secondary)
          FlexBox {}.flexGrow(Float(max(0.01, 1 - m.x)) * 100)
        }
      }

      FlexBox {}.flexGrow(1)

      // Things out of view.
      if !f.edges.isEmpty {
        FlexBox(direction: .row, crossAlignment: .center) {
          for e in f.edges.filter({ $0.turnDeg < 0 }) {
            Text("‹ \(e.label) \(abs(e.turnDeg))°", style: .meta)
          }
          FlexBox {}.flexGrow(1)
          for e in f.edges.filter({ $0.turnDeg > 0 }) {
            Text("\(e.label) \(e.turnDeg)° ›", style: .meta)
          }
        }
      }

      // Alarm, else route or depth.
      if let alarm = f.alarmTitle {
        FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
          Icon(name: .exclamationTriangle, style: .filled)
          FlexBox(direction: .column) {
            Text(alarm, style: .body)
            Text((f.alarmDetail ?? "") + " · tap to acknowledge", style: .meta, color: .secondary)
          }
        }
        .padding(12)
        .background(.card)
      } else if let footer = f.footer {
        Text(footer, style: .meta, color: .secondary)
      }
    }
    .padding(16)
    .onTap(onTap)
  }
}
