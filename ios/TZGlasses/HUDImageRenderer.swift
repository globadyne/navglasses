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
  /// "#rrggbb" -> colour; nil if it doesn't parse.
  static func color(hex: String) -> UIColor? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
  }
  /// TimeZero marks: violet, so they read apart from targets.
  private static let markColor = UIColor(red: 0.77, green: 0.61, blue: 1.0, alpha: 1)

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
  static func render(_ f: HUDFrame, sourceColors: [String: String] = HUDSettings.defaultSourceColors,
                     scale: CGFloat = 1) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      let c = ctx.cgContext
      UIColor.black.setFill()
      c.fill(CGRect(origin: .zero, size: size))
      draw(f, sourceColors: sourceColors, in: c)
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

  private static func textWidth(_ s: String, _ font: UIFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
  }

  /// Mark icons, same shapes as `markIcon` in hud-demo.html. `p` is where the mark sits on the water.
  private static func drawMarkIcon(_ icon: MarkIcon, at p: CGPoint, color: UIColor, in c: CGContext) {
    let x = p.x, y = p.y
    c.setStrokeColor(color.cgColor)
    c.setFillColor(color.cgColor)
    c.setLineWidth(2.5)
    switch icon {
    case .fish:
      c.strokeEllipse(in: CGRect(x: x - 13, y: y - 6, width: 22, height: 12))
      c.move(to: CGPoint(x: x + 8, y: y)); c.addLine(to: CGPoint(x: x + 16, y: y - 6))
      c.addLine(to: CGPoint(x: x + 16, y: y + 6)); c.closePath(); c.strokePath()
    case .pots:
      c.strokeEllipse(in: CGRect(x: x - 6, y: y - 4, width: 12, height: 12))
      c.move(to: CGPoint(x: x, y: y - 4)); c.addLine(to: CGPoint(x: x, y: y - 18)); c.strokePath()
      c.move(to: CGPoint(x: x, y: y - 18)); c.addLine(to: CGPoint(x: x + 10, y: y - 14))
      c.addLine(to: CGPoint(x: x, y: y - 10)); c.closePath(); c.fillPath()
    case .danger:
      c.strokeEllipse(in: CGRect(x: x - 11, y: y - 11, width: 22, height: 22))
      c.move(to: CGPoint(x: x - 6, y: y - 6)); c.addLine(to: CGPoint(x: x + 6, y: y + 6))
      c.move(to: CGPoint(x: x + 6, y: y - 6)); c.addLine(to: CGPoint(x: x - 6, y: y + 6)); c.strokePath()
    case .anchor:
      c.strokeEllipse(in: CGRect(x: x - 3.5, y: y - 14.5, width: 7, height: 7))
      c.move(to: CGPoint(x: x, y: y - 7)); c.addLine(to: CGPoint(x: x, y: y + 10))
      c.move(to: CGPoint(x: x - 7, y: y - 3)); c.addLine(to: CGPoint(x: x + 7, y: y - 3))
      c.move(to: CGPoint(x: x - 10, y: y + 2))
      c.addQuadCurve(to: CGPoint(x: x, y: y + 11), control: CGPoint(x: x - 9, y: y + 11))
      c.addQuadCurve(to: CGPoint(x: x + 10, y: y + 2), control: CGPoint(x: x + 9, y: y + 11))
      c.strokePath()
    case .generic:
      c.strokeEllipse(in: CGRect(x: x - 8, y: y - 8, width: 16, height: 16))
    }
  }

  /// HSL colour (as CSS `hsla`), so the rainbow matches hud-demo.html.
  private static func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double) -> UIColor {
    let v = l + s * min(l, 1 - l)
    let sv = v == 0 ? 0 : 2 * (1 - l / v)
    var hue = h.truncatingRemainder(dividingBy: 360) / 360
    if hue < 0 { hue += 1 }
    return UIColor(hue: hue, saturation: sv, brightness: v, alpha: a)
  }

  private static func cg(_ p: LensPoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }

  /// The route lying on the water: rainbow road ahead on an active route, dashed lines
  /// for the sailed part or a route that isn't being navigated, small waypoint diamonds.
  private static func drawRoute(_ r: HUDRoute, in c: CGContext) {
    func quad(_ pts: [LensPoint], _ fill: UIColor) {
      c.setFillColor(fill.cgColor)
      c.move(to: cg(pts[0])); pts.dropFirst().forEach { c.addLine(to: cg($0)) }; c.closePath(); c.fillPath()
    }
    // Dashed lines along the middle, joined so the dash pattern runs on unbroken.
    for style in [RouteSegmentStyle.passed, .planned] {
      var last: LensPoint?
      for seg in r.segments where seg.style == style {
        let a = LensPoint(x: (seg.al.x + seg.ar.x) / 2, y: (seg.al.y + seg.ar.y) / 2)
        let b = LensPoint(x: (seg.bl.x + seg.br.x) / 2, y: (seg.bl.y + seg.br.y) / 2)
        if last != a { c.move(to: cg(a)) }
        c.addLine(to: cg(b))
        last = b
      }
      let col = style == .passed ? UIColor(red: 0.55, green: 0.59, blue: 0.63, alpha: 0.45)
                                 : UIColor(red: 0.88, green: 0.92, blue: 0.96, alpha: 0.6)
      c.setStrokeColor(col.cgColor); c.setLineWidth(2.5); c.setLineDash(phase: 0, lengths: [12, 9])
      c.strokePath()
      c.setLineDash(phase: 0, lengths: [])
    }
    // Rainbow road: hue runs along the route and flows towards the boat over time.
    for seg in r.segments where seg.style == .rainbow {
      let hue = seg.alongNm / 0.12 * 360 - r.clock * 240
      if let g = seg.glow { quad(g, hsl(hue, 1, 0.6, 0.12)) }
      let fill = hsl(hue, 1, 0.62 + 0.08 * sin(r.clock * 6 + seg.alongNm * 40), 0.9)
      // Far away the road lies almost flat on the horizon, a pixel or two thick. Keep it
      // a visible coloured band there instead of just its edges.
      let thick = max(abs(seg.al.y - seg.ar.y), abs(seg.bl.y - seg.br.y),
                      hypot(seg.al.x - seg.ar.x, seg.al.y - seg.ar.y) * 0.3)
      if thick < 5 {
        c.setStrokeColor(fill.cgColor); c.setLineWidth(5); c.setLineCap(.round)
        c.move(to: CGPoint(x: (seg.al.x + seg.ar.x) / 2, y: (seg.al.y + seg.ar.y) / 2))
        c.addLine(to: CGPoint(x: (seg.bl.x + seg.br.x) / 2, y: (seg.bl.y + seg.br.y) / 2))
        c.strokePath(); c.setLineCap(.butt)
        continue
      }
      quad([seg.al, seg.bl, seg.br, seg.ar], fill)
      c.setStrokeColor(UIColor(white: 1, alpha: 0.55).cgColor); c.setLineWidth(1.5)
      c.move(to: cg(seg.al)); c.addLine(to: cg(seg.bl))
      c.move(to: cg(seg.ar)); c.addLine(to: cg(seg.br))
      c.strokePath()
    }
    // Waypoints other than the next one.
    for w in r.waypoints {
      let col = !r.active ? UIColor(red: 0.88, green: 0.92, blue: 0.96, alpha: 0.8)
        : w.passed ? UIColor(red: 0.55, green: 0.59, blue: 0.63, alpha: 0.6) : UIColor.white
      let x = w.at.x, y = w.at.y, d = 8.0
      c.setStrokeColor(col.cgColor); c.setLineWidth(2)
      c.move(to: CGPoint(x: x, y: y - d)); c.addLine(to: CGPoint(x: x + d, y: y))
      c.addLine(to: CGPoint(x: x, y: y + d)); c.addLine(to: CGPoint(x: x - d, y: y)); c.closePath()
      c.strokePath()
      if !w.label.isEmpty {
        text(w.label, at: CGPoint(x: x, y: y - 30), font: font(17), color: col, align: .center)
      }
    }
  }

  private static func draw(_ f: HUDFrame, sourceColors: [String: String], in c: CGContext) {
    let W = size.width, H = size.height

    // Ground layer first, so labels draw over it: tracks, then the route.
    for t in f.tracks {
      for run in t.runs {
        c.move(to: cg(run[0])); run.dropFirst().forEach { c.addLine(to: cg($0)) }
      }
      c.setLineCap(.round); c.setLineJoin(.round)
      switch t.style {
      case .own:
        c.setStrokeColor(UIColor(red: 1.0, green: 0.80, blue: 0.35, alpha: 1).cgColor)
        c.setLineWidth(3.5)
      case .saved:
        c.setStrokeColor(UIColor(red: 0.43, green: 0.77, blue: 1.0, alpha: 1).cgColor)
        c.setLineWidth(2.5); c.setLineDash(phase: 0, lengths: [3, 7])
      }
      c.strokePath()
      c.setLineDash(phase: 0, lengths: []); c.setLineCap(.butt); c.setLineJoin(.miter)
    }
    if let route = f.route { drawRoute(route, in: c) }

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

    // Labels. The marker sits where the thing is on the water (below the horizon by
    // its dip angle); the text sits above it. Nearest are placed first; labels that
    // would overlap step up, with a leader line down to their marker.
    var placed: [CGRect] = []
    // Keep the edge cues' rows clear (they're drawn later, from y = 96, 30 px apart).
    let leftCues = f.edges.filter { $0.turnDeg < 0 }.count, rightCues = f.edges.count - leftCues
    if leftCues > 0 { placed.append(CGRect(x: 0, y: 92, width: W / 2, height: CGFloat(leftCues) * 30 + 4)) }
    if rightCues > 0 { placed.append(CGRect(x: W / 2, y: 92, width: W / 2, height: CGFloat(rightCues) * 30 + 4)) }
    let lowest = f.alarmTitle != nil ? H - 108 : H - 56
    /// First free spot for `box`: stepping up from where it starts, else stepping down
    /// below the marker (from `below`), else where it started.
    func settle(_ box: CGRect, step: CGFloat, below: CGFloat) -> CGRect {
      var b = box
      while b.minY >= 92 {
        if !placed.contains(where: { $0.intersects(b) }) { return b }
        b.origin.y -= step
      }
      b.origin.y = below
      while b.maxY <= lowest {
        if !placed.contains(where: { $0.intersects(b) }) { return b }
        b.origin.y += step
      }
      return box
    }
    func leader(_ x: CGFloat, from top: CGFloat, to bottom: CGFloat, _ col: UIColor, width: CGFloat) {
      guard top < bottom else { return }
      c.setStrokeColor(col.cgColor); c.setLineWidth(width)
      c.move(to: CGPoint(x: x, y: top)); c.addLine(to: CGPoint(x: x, y: bottom)); c.strokePath()
    }
    for item in f.items.sorted(by: { $0.rangeNm < $1.rangeNm }) {
      let x = CGFloat(item.x) * W
      let y = min(max(CGFloat(item.y) * H, 110), H - 30)
      // Alarms are amber or red; otherwise each target source has its own colour.
      let col = item.severity == .normal
        ? (item.source.flatMap { sourceColors[$0] }.flatMap { color(hex: $0) } ?? hud) : color(item.severity)

      c.setStrokeColor(col.cgColor)
      c.setLineWidth(3)
      var top = y
      switch item.kind {
      case .waypoint:
        let d: CGFloat = 14
        c.move(to: CGPoint(x: x, y: y - d)); c.addLine(to: CGPoint(x: x + d, y: y))
        c.addLine(to: CGPoint(x: x, y: y + d)); c.addLine(to: CGPoint(x: x - d, y: y)); c.closePath()
        c.strokePath()
        top = y - d
      case .aton, .mark:
        let r: CGFloat = 10
        c.strokeEllipse(in: CGRect(x: x - r, y: y - 2 * r, width: 2 * r, height: 2 * r))
        top = y - 2 * r
      case .vessel:
        // Corner brackets around where the ship sits, resting on the water line.
        let bw: CGFloat = 30, bh: CGFloat = 18, k: CGFloat = 11, cy = y - bh * 0.7
        for (px, py, sx, sy) in [(x - bw, cy - bh, 1.0, 1.0), (x + bw, cy - bh, -1.0, 1.0),
                                 (x - bw, cy + bh, 1.0, -1.0), (x + bw, cy + bh, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
          c.move(to: CGPoint(x: px + sx * k, y: py)); c.addLine(to: CGPoint(x: px, y: py))
          c.addLine(to: CGPoint(x: px, y: py + sy * k))
        }
        c.strokePath()
        top = cy - bh
      }
      let w = max(textWidth(item.title, labelFont(28)), textWidth(item.detail, font(20, .regular))) + 16
      let box = settle(CGRect(x: min(max(x - w / 2, 0), W - w), y: top - 64, width: w, height: 58),
                       step: 60, below: y + 18)
      placed.append(box)
      if box.minY > y { leader(x, from: y + 6, to: box.minY, col, width: 1.5) }
      else { leader(x, from: box.maxY, to: top - 4, col, width: 1.5) }
      text(item.title, at: CGPoint(x: x, y: box.minY), font: labelFont(28), color: col, align: .center)
      text(item.detail, at: CGPoint(x: x, y: box.minY + 32), font: font(20, .regular), color: col, align: .center)
    }

    // TimeZero marks: icon on the water, one-line label above, stepped clear of other labels.
    for m in f.marks {
      let x = CGFloat(m.x) * W
      let y = min(max(CGFloat(m.y) * H, 100), H - 30)
      let col = m.alarm ? red : markColor
      drawMarkIcon(m.icon, at: CGPoint(x: x, y: y), color: col, in: c)
      let label = "\(m.title) \(m.detail)"
      let w = textWidth(label, labelFont(21)) + 12
      let box = settle(CGRect(x: min(max(x - w / 2, 4), W - 4 - w), y: y - 48, width: w, height: 26),
                       step: 30, below: y + 16)
      placed.append(box)
      if box.minY > y { leader(x, from: y + 12, to: box.minY, col, width: 1.2) }
      else { leader(x, from: box.maxY, to: y - 22, col, width: 1.2) }
      text(label, at: CGPoint(x: x, y: box.minY), font: labelFont(21), color: col, align: .center)
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
