//
// HUDImageRenderer.swift
//
// Draws a HUDFrame as a 600 x 600 picture for the lens (Ray-Ban Display is
// 600 x 600). On the waveguide, black is see-through, so everything not drawn
// shows the real world. Also used for the preview on the phone.
//

import UIKit

enum HUDImageRenderer {
  static let size = CGSize(width: 600, height: 600)

  private static let hud = UIColor(red: 0.56, green: 0.94, blue: 0.78, alpha: 1)
  private static let hudDim = UIColor(red: 0.56, green: 0.94, blue: 0.78, alpha: 0.6)
  private static let amber = UIColor(red: 1.0, green: 0.76, blue: 0.40, alpha: 1)
  private static let red = UIColor(red: 1.0, green: 0.49, blue: 0.43, alpha: 1)

  private static func color(_ s: Severity) -> UIColor {
    switch s {
    case .normal: hud
    case .caution: amber
    case .danger: red
    }
  }

  private static func font(_ size: CGFloat, _ weight: UIFont.Weight = .medium) -> UIFont {
    UIFont.monospacedSystemFont(ofSize: size, weight: weight)
  }

  private static func labelFont(_ size: CGFloat) -> UIFont {
    UIFont.systemFont(ofSize: size, weight: .semibold).withCondensed()
  }

  /// - Parameter scale: 1 for the glasses (600 px); the phone preview can use the screen scale.
  static func render(_ f: HUDFrame, scale: CGFloat = 1) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      let c = ctx.cgContext
      UIColor.black.setFill()
      c.fill(CGRect(origin: .zero, size: size))
      draw(f, in: c)
    }
  }

  private static func text(_ s: String, at p: CGPoint, font: UIFont, color: UIColor, align: NSTextAlignment = .left) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let ns = s as NSString
    let w = ns.size(withAttributes: attrs).width
    var origin = p
    if align == .center {
      // Keep centred labels fully inside the lens when their target is near the edge.
      origin.x = min(max(p.x - w / 2, 8), size.width - 8 - w)
    }
    if align == .right { origin.x -= w }
    ns.draw(at: origin, withAttributes: attrs)
  }

  private static func draw(_ f: HUDFrame, in c: CGContext) {
    let W = size.width, H = size.height

    // Top strip: boat heading, gaze bearing, speed.
    text(f.headingText, at: CGPoint(x: 24, y: 20), font: font(28), color: hud)
    text(f.speedText, at: CGPoint(x: W - 24, y: 20), font: font(28), color: hud, align: .right)
    text(f.gazeText, at: CGPoint(x: W / 2, y: 58), font: font(24, .regular), color: hudDim, align: .center)
    if f.stale {
      text("NO DATA", at: CGPoint(x: W / 2, y: 20), font: font(24, .bold), color: amber, align: .center)
    }

    if let msg = f.message {
      text(msg, at: CGPoint(x: W / 2, y: H / 2 - 16), font: labelFont(30), color: hud, align: .center)
    }

    // Labels. Waypoints sit on the horizon line; vessels, buoys and marks below it,
    // nearer things lower. Labels that would overlap step down a row.
    let horizon: CGFloat = 250
    var placed: [CGRect] = []
    for item in f.items.sorted(by: { $0.x < $1.x }) {
      let x = CGFloat(item.x) * W
      let col = color(item.severity)
      var y: CGFloat
      switch item.kind {
      case .waypoint: y = horizon
      default: y = horizon + 40 + CGFloat(max(0, min(1, 1 - item.rangeNm / 4))) * 150
      }
      var box = CGRect(x: x - 120, y: y - 78, width: 240, height: 100)
      while placed.contains(where: { $0.intersects(box) }) && box.maxY < H - 110 {
        box.origin.y += 70; y += 70
      }
      placed.append(box)

      c.setStrokeColor(col.cgColor)
      c.setLineWidth(3)
      switch item.kind {
      case .waypoint:
        let d: CGFloat = 14
        c.move(to: CGPoint(x: x, y: y - d)); c.addLine(to: CGPoint(x: x + d, y: y))
        c.addLine(to: CGPoint(x: x, y: y + d)); c.addLine(to: CGPoint(x: x - d, y: y)); c.closePath()
        c.strokePath()
      case .aton, .mark:
        c.strokeEllipse(in: CGRect(x: x - 10, y: y - 10, width: 20, height: 20))
      case .vessel:
        // Corner brackets around where the ship sits.
        let bw: CGFloat = 34, bh: CGFloat = 22, k: CGFloat = 12
        for (px, py, sx, sy) in [(x - bw, y - bh, 1.0, 1.0), (x + bw, y - bh, -1.0, 1.0),
                                 (x - bw, y + bh, 1.0, -1.0), (x + bw, y + bh, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
          c.move(to: CGPoint(x: px + sx * k, y: py)); c.addLine(to: CGPoint(x: px, y: py))
          c.addLine(to: CGPoint(x: px, y: py + sy * k))
        }
        c.strokePath()
      }
      text(item.title, at: CGPoint(x: x, y: y - 74), font: labelFont(28), color: col, align: .center)
      text(item.detail, at: CGPoint(x: x, y: y - 42), font: font(20, .regular), color: col, align: .center)
    }

    // Edge cues for things out of view: under the top strip, clear of the labels below.
    var leftY: CGFloat = 96, rightY: CGFloat = 96
    for e in f.edges {
      let col = color(e.severity)
      if e.turnDeg < 0 {
        text("‹ \(e.label) \(abs(e.turnDeg))°", at: CGPoint(x: 16, y: leftY), font: font(20), color: col)
        leftY += 30
      } else {
        text("\(e.label) \(e.turnDeg)° ›", at: CGPoint(x: W - 16, y: rightY), font: font(20), color: col, align: .right)
        rightY += 30
      }
    }

    // Bottom: alarm banner, else route or depth.
    if let title = f.alarmTitle {
      let box = CGRect(x: 20, y: H - 104, width: W - 40, height: 84)
      c.setStrokeColor(red.cgColor)
      c.setLineWidth(3)
      c.stroke(box)
      text(title, at: CGPoint(x: W / 2, y: box.minY + 10), font: labelFont(30), color: red, align: .center)
      text((f.alarmDetail ?? "") + " · TAP TO ACK", at: CGPoint(x: W / 2, y: box.minY + 48),
           font: font(19, .regular), color: red, align: .center)
    } else if let footer = f.footer {
      text(footer, at: CGPoint(x: 24, y: H - 52), font: font(22, .regular), color: hudDim)
    }
  }
}

private extension UIFont {
  func withCondensed() -> UIFont {
    guard let d = fontDescriptor.withSymbolicTraits([fontDescriptor.symbolicTraits, .traitCondensed]) else { return self }
    return UIFont(descriptor: d, size: pointSize)
  }
}
