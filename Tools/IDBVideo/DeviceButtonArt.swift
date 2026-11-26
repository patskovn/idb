/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

/// Pictures of the device's buttons, for drawing beside the screen.
enum DeviceButtonArt {
  /// The Home button as the phones that have one show it: a dark disc with a rounded square
  /// outlined in its middle. `diameter` pixels each way, as RGBA with straight alpha, clear outside
  /// the disc. `pressed` draws it lit, as under a finger.
  static func homeButton(diameter: Int, pressed: Bool) -> [UInt8]? {
    guard diameter >= 8 else {
      return nil
    }
    return draw(width: diameter, height: diameter) { context in
      let size = CGFloat(diameter)
      let line = max(1.5, size / 24)
      let disc = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
      context.setFillColor(gray: pressed ? litFill : fill, alpha: 1)
      context.fillEllipse(in: disc)
      context.setStrokeColor(gray: pressed ? litRim : rim, alpha: 1)
      context.setLineWidth(line)
      context.strokeEllipse(in: disc)
      // The rounded square: a little over a third of the button across.
      let side = size * 0.36
      let square = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
      context.setStrokeColor(gray: pressed ? litMark : mark, alpha: 1)
      context.setLineWidth(line)
      context.addPath(CGPath(roundedRect: square, cornerWidth: side * 0.26, cornerHeight: side * 0.26, transform: nil))
      context.strokePath()
    }
  }

  /// The volume buttons as one upright capsule: a plus in its top half, which turns the volume up,
  /// and a minus in its bottom half, which turns it down. `width` by `height` pixels as RGBA with
  /// straight alpha, clear outside the capsule. The half that is `pressed`, if either, is drawn lit.
  static func volumeCapsule(width: Int, height: Int, pressed: DeviceButton?) -> [UInt8]? {
    guard width >= 8, height >= 2 * width else {
      return nil
    }
    return draw(width: width, height: height) { context in
      let size = CGSize(width: width, height: height)
      let line = max(1.5, size.width / 26)
      let body = CGRect(origin: .zero, size: size).insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
      let capsule = CGPath(roundedRect: body, cornerWidth: body.width / 2, cornerHeight: body.width / 2, transform: nil)
      context.addPath(capsule)
      context.setFillColor(gray: fill, alpha: 1)
      context.fillPath()
      // Core Graphics counts rows from the bottom: the top half is the upper one in its space.
      let halves: [(button: DeviceButton, rect: CGRect)] = [
        (.volumeUp, CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)),
        (.volumeDown, CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)),
      ]
      for half in halves where half.button == pressed {
        context.saveGState()
        context.addPath(capsule)
        context.clip()
        context.setFillColor(gray: litFill, alpha: 1)
        context.fill(half.rect)
        context.restoreGState()
      }
      context.addPath(capsule)
      context.setStrokeColor(gray: pressed == nil ? rim : litRim, alpha: 1)
      context.setLineWidth(line)
      context.strokePath()
      // Between the two, a line only just lighter than the body: enough to tell them apart.
      context.setStrokeColor(gray: divider, alpha: 1)
      context.setLineWidth(1)
      context.move(to: CGPoint(x: body.minX + body.width * 0.3, y: (size.height / 2).rounded() + 0.5))
      context.addLine(to: CGPoint(x: body.maxX - body.width * 0.3, y: (size.height / 2).rounded() + 0.5))
      context.strokePath()
      // The plus and the minus, each in the middle of its half.
      let arm = size.width * 0.17
      context.setLineWidth(line * 1.3)
      context.setLineCap(.round)
      for half in halves {
        context.setStrokeColor(gray: half.button == pressed ? litMark : mark, alpha: 1)
        let centre = CGPoint(x: half.rect.midX, y: half.rect.midY)
        context.move(to: CGPoint(x: centre.x - arm, y: centre.y))
        context.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
        if half.button == .volumeUp {
          context.move(to: CGPoint(x: centre.x, y: centre.y - arm))
          context.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
        }
        context.strokePath()
      }
    }
  }

  /// The viewer's own button for the screen's corners: a disc with an arc in it, the round of a
  /// corner. `pressed` draws it lit, as under a finger; it looks the same whichever way the corners are.
  static func cornersButton(diameter: Int, pressed: Bool) -> [UInt8]? {
    guard diameter >= 8 else {
      return nil
    }
    let lit = pressed
    return draw(width: diameter, height: diameter) { context in
      let size = CGFloat(diameter)
      let line = max(1.5, size / 26)
      let disc = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
      context.setFillColor(gray: lit ? litFill : fill, alpha: 1)
      context.fillEllipse(in: disc)
      context.setStrokeColor(gray: lit ? litRim : rim, alpha: 1)
      context.setLineWidth(line)
      context.strokeEllipse(in: disc)
      // A quarter of a circle, the top right one, set so that the arc itself is in the middle of the disc.
      let radius = size * 0.3
      let centre = CGPoint(x: size / 2 - radius * 0.5, y: size / 2 - radius * 0.5)
      context.setStrokeColor(gray: lit ? litMark : mark, alpha: 1)
      context.setLineWidth(line * 1.3)
      context.setLineCap(.round)
      context.addArc(center: centre, radius: radius, startAngle: .pi / 2, endAngle: 0, clockwise: true)
      context.strokePath()
    }
  }

  /// The lock button as an upright capsule with a closed padlock in its middle. `width` by `height`
  /// pixels as RGBA with straight alpha, clear outside the capsule. `pressed` draws it lit.
  static func lockCapsule(width: Int, height: Int, pressed: Bool) -> [UInt8]? {
    guard width >= 8, height >= width * 3 / 2 else {
      return nil
    }
    return draw(width: width, height: height) { context in
      let size = CGSize(width: width, height: height)
      let line = max(1.5, size.width / 26)
      let body = CGRect(origin: .zero, size: size).insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
      context.addPath(CGPath(roundedRect: body, cornerWidth: body.width / 2, cornerHeight: body.width / 2, transform: nil))
      context.setFillColor(gray: pressed ? litFill : fill, alpha: 1)
      context.setStrokeColor(gray: pressed ? litRim : rim, alpha: 1)
      context.setLineWidth(line)
      context.drawPath(using: .fillStroke)
      // The padlock: a solid case with a shackle looped over it, the pair centred in the capsule.
      // Core Graphics counts rows from the bottom, so the shackle is drawn above the case.
      let caseSize = CGSize(width: (size.width * 0.38).rounded(), height: (size.width * 0.29).rounded())
      let shackleRadius = caseSize.width * 0.3
      let shackleRise = caseSize.height * 0.34
      let padlockHeight = caseSize.height + shackleRise + shackleRadius
      let padlockCase = CGRect(
        x: ((size.width - caseSize.width) / 2).rounded(), y: ((size.height - padlockHeight) / 2).rounded(), width: caseSize.width,
        height: caseSize.height)
      context.setFillColor(gray: pressed ? litMark : mark, alpha: 1)
      context.setStrokeColor(gray: pressed ? litMark : mark, alpha: 1)
      context.addPath(CGPath(roundedRect: padlockCase, cornerWidth: caseSize.width * 0.14, cornerHeight: caseSize.width * 0.14, transform: nil))
      context.fillPath()
      context.setLineWidth(line * 1.3)
      context.setLineCap(.butt)
      context.move(to: CGPoint(x: padlockCase.midX - shackleRadius, y: padlockCase.maxY))
      context.addLine(to: CGPoint(x: padlockCase.midX - shackleRadius, y: padlockCase.maxY + shackleRise))
      context.addArc(
        center: CGPoint(x: padlockCase.midX, y: padlockCase.maxY + shackleRise), radius: shackleRadius, startAngle: .pi, endAngle: 0,
        clockwise: true)
      context.addLine(to: CGPoint(x: padlockCase.midX + shackleRadius, y: padlockCase.maxY))
      context.strokePath()
    }
  }

  // The greys of a button's body, rim and mark, at rest and under a finger.
  private static let fill: CGFloat = 0.11
  private static let divider: CGFloat = 0.2
  private static let rim: CGFloat = 0.40
  private static let mark: CGFloat = 0.72
  private static let litFill: CGFloat = 0.34
  private static let litRim: CGFloat = 0.62
  private static let litMark: CGFloat = 0.95

  /// What `body` draws into a clear bitmap of `width` by `height` pixels, as RGBA with straight alpha.
  private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else {
        return false
      }
      body(context)
      return true
    }
    guard drawn else {
      return nil
    }
    // Core Graphics multiplies colour by alpha; the terminal wants it straight.
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Int(pixels[offset + 3])
      if alpha > 0, alpha < 255 {
        for channel in 0..<3 {
          pixels[offset + channel] = UInt8(min(255, Int(pixels[offset + channel]) * 255 / alpha))
        }
      }
    }
    return pixels
  }
}
