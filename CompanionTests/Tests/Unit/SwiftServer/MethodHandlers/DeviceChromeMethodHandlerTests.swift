/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBSimulatorControl
import Foundation
import IDBGRPCSwift
import Testing

/// What a client is told of a device's body.
@Suite
struct DeviceChromeMethodHandlerTests {

  @Test
  func everyButtonIsToldWithItsPlaceAgainstTheScreen() {
    let chrome = SimulatorChrome(
      identifier: "com.apple.dt.devicekit.chrome.phone11", screenSize: CGSize(width: 402, height: 874), screenCornerRadius: 62,
      buttons: [
        SimulatorChrome.Button(name: "volume-up", title: "Volume Up", kind: "button", edge: .left, start: 204, length: 64, usagePage: 12, usage: 233),
        SimulatorChrome.Button(name: "power", title: "Sleep/Wake", kind: "button", edge: .right, start: 245, length: 101, usagePage: 12, usage: 48),
        SimulatorChrome.Button(name: "home", title: "Home", kind: "button", edge: .bottom, start: 171, length: 60, usagePage: 12, usage: 64),
        SimulatorChrome.Button(name: "top", title: "Top", kind: "switch", edge: .top, start: -5, length: 30, usagePage: 0, usage: 0),
      ])

    let response = DeviceChromeMethodHandler.response(for: chrome)

    #expect(response.identifier == "com.apple.dt.devicekit.chrome.phone11")
    #expect(response.screenWidthPoints == 402)
    #expect(response.screenHeightPoints == 874)
    #expect(response.screenCornerRadius == 62)
    #expect(response.buttons.map(\.name) == ["volume-up", "power", "home", "top"])
    #expect(response.buttons.map(\.edge) == [.left, .right, .bottom, .top])
    #expect(response.buttons.map(\.start) == [204, 245, 171, -5])
    #expect(response.buttons.map(\.length) == [64, 101, 60, 30])
    #expect(response.buttons[0].title == "Volume Up")
    #expect(response.buttons[3].kind == "switch")
    #expect(response.buttons[0].usagePage == 12)
    #expect(response.buttons[0].usage == 233)
  }
}
