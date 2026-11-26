/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBSimulatorControl
import Foundation
import Testing

/// Where a device chrome description's buttons are against the screen.
@Suite
struct SimulatorChromeTests {

  /// The inputs of the chrome the Face ID phones share, as Xcode installs it.
  private static let phone = """
    {
      "identifier": "com.apple.dt.devicekit.chrome.phone11",
      "images": { "composite": "PhoneComposite" },
      "inputs": [
        { "name": "action", "accessibilityTitle": "Action", "type": "button", "usagePage": 11, "usage": 45, "image": "Mute BTN",
          "anchor": "left", "align": "leading", "offsets": { "normal": { "x": 8, "y": 160 }, "rollover": { "x": 3, "y": 160 } } },
        { "name": "volume-up", "accessibilityTitle": "Volume Up", "type": "button", "usagePage": 12, "usage": 233, "image": "Vol BTN",
          "anchor": "left", "align": "leading", "offsets": { "normal": { "x": 8, "y": 221 }, "rollover": { "x": 3, "y": 221 } } },
        { "name": "volume-down", "accessibilityTitle": "Volume Down", "type": "button", "usagePage": 12, "usage": 234, "image": "Vol BTN",
          "anchor": "left", "align": "leading", "offsets": { "normal": { "x": 8, "y": 300 }, "rollover": { "x": 3, "y": 300 } } },
        { "name": "power", "accessibilityTitle": "Sleep/Wake", "type": "button", "usagePage": 12, "usage": 48, "image": "X_Power BTN",
          "anchor": "right", "align": "leading", "offsets": { "normal": { "x": -8, "y": 262 }, "rollover": { "x": -3, "y": 262 } } }
      ]
    }
    """

  private static let phoneImages: [String: CGSize] = [
    "PhoneComposite": CGSize(width: 436, height: 908), "Vol BTN": CGSize(width: 16, height: 64), "Mute BTN": CGSize(width: 16, height: 34),
    "X_Power BTN": CGSize(width: 16, height: 101),
  ]

  private func chrome(_ description: String, screen: CGSize, images: [String: CGSize]) throws -> SimulatorChrome {
    try SimulatorChrome(description: Data(description.utf8), screenSize: screen) { images[$0] }
  }

  @Test
  func aSideButtonIsPlacedDownTheScreenLessTheBezelAboveIt() throws {
    // The body is 34 points taller than the 874 point screen: 17 of bezel above it.
    let chrome = try chrome(Self.phone, screen: CGSize(width: 402, height: 874), images: Self.phoneImages)

    #expect(chrome.identifier == "com.apple.dt.devicekit.chrome.phone11")
    #expect(chrome.buttons.map(\.name) == ["action", "volume-up", "volume-down", "power"])
    let volumeUp = try #require(chrome.buttons.first { $0.name == "volume-up" })
    #expect(volumeUp.edge == .left)
    #expect(volumeUp.start == 204)
    #expect(volumeUp.length == 64)
    #expect(volumeUp.title == "Volume Up")
    #expect(volumeUp.kind == "button")
    #expect(volumeUp.usagePage == 12)
    #expect(volumeUp.usage == 233)
    let power = try #require(chrome.buttons.first { $0.name == "power" })
    #expect(power.edge == .right)
    #expect(power.start == 245)
    #expect(power.length == 101)
  }

  @Test
  func aButtonAlignedToTheMiddleOrTheEndIsMeasuredFromThere() throws {
    // A tablet's Home button in the middle of its chin, and its power button in from the right of its top.
    let tablet = """
      {
        "identifier": "tablet",
        "images": { "composite": "Body" },
        "inputs": [
          { "name": "home", "type": "button", "image": "Home BTN", "anchor": "bottom", "align": "center", "offsets": { "normal": { "x": 0, "y": -65 } } },
          { "name": "power", "type": "button", "image": "Power BTN", "anchor": "top", "align": "trailing", "offsets": { "normal": { "x": -65, "y": 8 } } }
        ]
      }
      """
    let chrome = try chrome(
      tablet, screen: CGSize(width: 768, height: 1024),
      images: ["Body": CGSize(width: 868, height: 1224), "Home BTN": CGSize(width: 60, height: 60), "Power BTN": CGSize(width: 70, height: 16)])

    let home = try #require(chrome.buttons.first { $0.name == "home" })
    #expect(home.edge == .bottom)
    // Centred on an 868 point body with 50 points of bezel left of the screen.
    #expect(home.start == (868 - 60) / 2 - 50)
    #expect(home.length == 60)
    #expect(home.title == "home", "a button with no title of its own goes by its name")
    let power = try #require(chrome.buttons.first { $0.name == "power" })
    #expect(power.edge == .top)
    // Its right end 65 points in from the body's right.
    #expect(power.start == 868 - 65 - 70 - 50)
  }

  @Test
  func aButtonWhosePictureIsMissingIsLeftOut() throws {
    var images = Self.phoneImages
    images["X_Power BTN"] = nil
    let chrome = try chrome(Self.phone, screen: CGSize(width: 402, height: 874), images: images)

    #expect(chrome.buttons.map(\.name) == ["action", "volume-up", "volume-down"])
  }

  @Test
  func aDescriptionWithNoPictureOfTheBodyCannotBePlaced() {
    #expect(throws: SimulatorChromeError.unreadable(identifier: "com.apple.dt.devicekit.chrome.phone11", reason: "it has no picture of the whole body")) {
      _ = try chrome(Self.phone, screen: CGSize(width: 402, height: 874), images: [:])
    }
  }

  @Test
  func theDescriptionIsFoundAmongTheInstalledOnesByItsIdentifier() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    // Another body's description beside it, which must not be taken for it.
    for (bundle, description) in [("other", Self.phone.replacingOccurrences(of: "phone11", with: "phone2")), ("phone11", Self.phone)] {
      let resources = directory.appendingPathComponent("\(bundle).devicechrome/Contents/Resources")
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      try Data(description.utf8).write(to: resources.appendingPathComponent("chrome.json"))
      for (image, size) in Self.phoneImages {
        var box = CGRect(origin: .zero, size: bundle == "other" ? CGSize(width: size.width * 2, height: size.height * 2) : size)
        let context = try #require(CGContext(resources.appendingPathComponent("\(image).pdf") as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
      }
    }

    let chrome = try SimulatorChrome.read(
      identifier: "com.apple.dt.devicekit.chrome.phone11", screenSize: CGSize(width: 402, height: 874), screenCornerRadius: 62,
      directories: [directory.path])

    #expect(chrome.screenCornerRadius == 62)

    #expect(chrome.buttons.first { $0.name == "volume-down" }?.start == 283)
    #expect(chrome.buttons.first { $0.name == "volume-down" }?.length == 64)
  }

  @Test
  func aDescriptionThatIsNotInstalledSaysWhereItWasLookedFor() {
    #expect(throws: SimulatorChromeError.notInstalled(identifier: "nowhere", searched: ["/nonexistent"])) {
      _ = try SimulatorChrome.read(identifier: "nowhere", screenSize: CGSize(width: 1, height: 1), directories: ["/nonexistent"])
    }
  }
}
