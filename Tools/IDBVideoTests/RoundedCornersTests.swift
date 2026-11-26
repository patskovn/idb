/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Testing

@testable import idb_video

/// What of a picture is made clear to show the screen's rounded corners.
@Suite
struct RoundedCornersTests {

  private func alphas(width: Int, height: Int, radius: Int) -> [[UInt8]] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    if let mask = CornerMask(width: width, height: height, radius: radius) {
      pixels.withUnsafeMutableBytes { mask.apply(to: $0.baseAddress!) }
    }
    return (0..<height).map { y in (0..<width).map { x in pixels[(y * width + x) * 4 + 3] } }
  }

  @Test
  func theTipsOfTheCornersAreClearAndTheRestIsNot() {
    let alpha = alphas(width: 400, height: 600, radius: 60)

    for (x, y) in [(0, 0), (399, 0), (0, 599), (399, 599)] {
      #expect(alpha[y][x] == 0, "the corner at \(x), \(y)")
    }
    // The middles of the sides, the middle of the picture, and well inside a corner.
    #expect(alpha[0][200] == 255)
    #expect(alpha[300][0] == 255)
    #expect(alpha[300][200] == 255)
    #expect(alpha[40][40] == 255)
  }

  @Test
  func theFourCornersAreTheSame() {
    let alpha = alphas(width: 300, height: 500, radius: 50)

    for y in 0..<100 {
      for x in 0..<100 {
        #expect(alpha[y][x] == alpha[y][299 - x])
        #expect(alpha[y][x] == alpha[499 - y][x])
        #expect(alpha[y][x] == alpha[499 - y][299 - x])
      }
    }
  }

  @Test
  func theCurveSEdgeIsCoveredInPart() {
    let alpha = alphas(width: 1206, height: 2622, radius: 186)

    #expect(alpha.joined().filter { $0 > 0 && $0 < 255 }.count > 400, "the pixels the curve crosses are neither clear nor whole")
  }

  @Test
  func theCurveIsTheContinuousOneNotAQuarterCircle() {
    // A quarter circle of this radius meets the top side 186 pixels in from the corner and is flush
    // with it from there on. The continuous curve is still coming away from the side there.
    let alpha = alphas(width: 1206, height: 2622, radius: 186)

    #expect(alpha[0][186 + 8] < 255, "the top row is still cut into past where a circle's arc would have ended")
    #expect(alpha[186 + 8][0] < 255, "and so is the left column")
    #expect(alpha[0][186 * 2] == 255, "but not for long")
    #expect(alpha[12][12] == 0)
  }

  @Test
  func noRadiusChangesNothing() {
    #expect(alphas(width: 10, height: 10, radius: 0).joined().allSatisfy { $0 == 255 })
  }
}
