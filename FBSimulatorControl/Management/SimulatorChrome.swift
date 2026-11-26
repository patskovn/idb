/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import CoreSimulator
import FBControlCore
import Foundation

/// The body of a simulated device as Simulator draws it around the screen: which hardware buttons
/// it has and where on its edges they are.
///
/// Xcode installs one description per body shape (`*.devicechrome`, shared by the device types of
/// that shape), which a device type names in its profile. The description places each button on
/// the picture of the whole body; here they are given relative to the screen, which is what
/// something drawn around a picture of the screen needs.
public struct SimulatorChrome: Equatable, Sendable {

  /// The edge of the body a button is on.
  public enum Edge: String, Sendable {
    case left, right, top, bottom
  }

  public struct Button: Equatable, Sendable {
    /// The description's name for it, such as `volume-up`, `volume-down`, `power`, `action`, `mute`, `home`.
    public let name: String
    /// What Simulator calls it, such as "Volume Up".
    public let title: String
    /// `button`, `switch` or `crown`.
    public let kind: String
    public let edge: Edge
    /// Where it starts along its edge and how long it is, in points of the screen measured from the
    /// screen's top for a left or right edge and from its left for a top or bottom one. A button
    /// beside the bezel rather than the screen starts before 0 or ends past the screen's size.
    public let start: Double
    public let length: Double
    /// The HID usage Simulator sends for it.
    public let usagePage: Int
    public let usage: Int

    public init(name: String, title: String, kind: String, edge: Edge, start: Double, length: Double, usagePage: Int, usage: Int) {
      self.name = name
      self.title = title
      self.kind = kind
      self.edge = edge
      self.start = start
      self.length = length
      self.usagePage = usagePage
      self.usage = usage
    }
  }

  /// The description's identifier, such as `com.apple.dt.devicekit.chrome.phone11`.
  public let identifier: String
  /// The screen the buttons are placed against, in points.
  public let screenSize: CGSize
  /// The radius of the screen's corners in points; 0 for a screen with square ones.
  public let screenCornerRadius: Double
  public let buttons: [Button]

  public init(identifier: String, screenSize: CGSize, screenCornerRadius: Double = 0, buttons: [Button]) {
    self.identifier = identifier
    self.screenSize = screenSize
    self.screenCornerRadius = screenCornerRadius
    self.buttons = buttons
  }
}

public enum SimulatorChromeError: Error, LocalizedError, Equatable {
  /// The device type's profile names no chrome.
  case notNamed(deviceType: String)
  /// No installed description has the identifier the profile names.
  case notInstalled(identifier: String, searched: [String])
  /// The description is not the JSON it is expected to be, or lacks the picture of the body.
  case unreadable(identifier: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case let .notNamed(deviceType):
      return "The device type \(deviceType) names no device chrome"
    case let .notInstalled(identifier, searched):
      return "No device chrome \(identifier) is installed in \(searched.joined(separator: ", "))"
    case let .unreadable(identifier, reason):
      return "Cannot read the device chrome \(identifier): \(reason)"
    }
  }
}

extension SimulatorChrome {

  /// Where Xcode installs the descriptions.
  public static let installDirectories = ["/Library/Developer/DeviceKit/Chrome"]

  /// Reads the description `identifier` from the first of `directories` that has it.
  public static func read(
    identifier: String, screenSize: CGSize, screenCornerRadius: Double = 0, directories: [String] = installDirectories
  ) throws -> SimulatorChrome {
    for directory in directories {
      let bundles = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
      for bundle in bundles.sorted() where bundle.hasSuffix(".devicechrome") {
        let resources = URL(fileURLWithPath: directory).appendingPathComponent(bundle).appendingPathComponent("Contents/Resources")
        guard let description = try? Data(contentsOf: resources.appendingPathComponent("chrome.json")),
          Self.identifier(of: description) == identifier
        else {
          continue
        }
        return try SimulatorChrome(description: description, screenSize: screenSize, screenCornerRadius: screenCornerRadius) { image in
          Self.pageSize(ofPDF: resources.appendingPathComponent("\(image).pdf"))
        }
      }
    }
    throw SimulatorChromeError.notInstalled(identifier: identifier, searched: directories)
  }

  private static func identifier(of description: Data) -> String? {
    ((try? JSONSerialization.jsonObject(with: description)) as? [String: Any])?["identifier"] as? String
  }

  /// The pictures are one-page PDFs, sized in points.
  private static func pageSize(ofPDF url: URL) -> CGSize? {
    guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
      return nil
    }
    return page.getBoxRect(.mediaBox).size
  }

  /// Places the buttons of a description (`chrome.json`) against a screen of `screenSize` points.
  /// `imageSize` gives the size in points of one of the description's pictures by name.
  ///
  /// The description places a button on the picture of the whole body: on an edge (`anchor`), at an
  /// offset along it from the body's start, its end or its middle (`align`), and its picture's
  /// extent along the edge is its length. The screen sits in the middle of the body, so the bezel on
  /// each side is half of what the body is larger by, and taking that off gives the place against
  /// the screen. An offset from the end is negative in every description that has one.
  init(description: Data, screenSize: CGSize, screenCornerRadius: Double = 0, imageSize: (String) -> CGSize?) throws {
    guard let json = (try? JSONSerialization.jsonObject(with: description)) as? [String: Any],
      let identifier = json["identifier"] as? String
    else {
      throw SimulatorChromeError.unreadable(identifier: "?", reason: "it is not a JSON object with an identifier")
    }
    guard let composite = (json["images"] as? [String: Any])?["composite"] as? String, let bodySize = imageSize(composite) else {
      throw SimulatorChromeError.unreadable(identifier: identifier, reason: "it has no picture of the whole body")
    }
    let bezel = CGSize(width: (bodySize.width - screenSize.width) / 2, height: (bodySize.height - screenSize.height) / 2)
    var buttons: [Button] = []
    for input in json["inputs"] as? [[String: Any]] ?? [] {
      guard let name = input["name"] as? String, let edge = (input["anchor"] as? String).flatMap(Edge.init(rawValue:)),
        let offsets = (input["offsets"] as? [String: Any])?["normal"] as? [String: Any],
        let image = input["image"] as? String, let size = imageSize(image)
      else {
        continue
      }
      let alongHeight = edge == .left || edge == .right
      let offset = ((alongHeight ? offsets["y"] : offsets["x"]) as? NSNumber)?.doubleValue ?? 0
      let length = Double(alongHeight ? size.height : size.width)
      let body = Double(alongHeight ? bodySize.height : bodySize.width)
      let start: Double
      switch input["align"] as? String {
      case "trailing":
        start = body + offset - length
      case "center":
        start = (body - length) / 2 + offset
      default:
        start = offset
      }
      buttons.append(
        Button(
          name: name, title: input["accessibilityTitle"] as? String ?? name, kind: input["type"] as? String ?? "button", edge: edge,
          start: start - Double(alongHeight ? bezel.height : bezel.width), length: length,
          usagePage: (input["usagePage"] as? NSNumber)?.intValue ?? 0, usage: (input["usage"] as? NSNumber)?.intValue ?? 0))
    }
    self.init(identifier: identifier, screenSize: screenSize, screenCornerRadius: screenCornerRadius, buttons: buttons)
  }
}

extension Simulator {

  /// The body Simulator draws around this device's screen. Throws when the device type names none
  /// or the one it names is not installed.
  public func chrome() throws -> SimulatorChrome {
    guard let deviceType = device.deviceType else {
      throw SimulatorChromeError.notNamed(deviceType: name)
    }
    let profile = deviceType.bundle?.url(forResource: "profile", withExtension: "plist").flatMap { NSDictionary(contentsOf: $0) }
    guard let identifier = profile?["chromeIdentifier"] as? String else {
      throw SimulatorChromeError.notNamed(deviceType: deviceType.name ?? name)
    }
    let scale = max(1, CGFloat(deviceType.mainScreenScale))
    return try SimulatorChrome.read(
      identifier: identifier, screenSize: CGSize(width: deviceType.mainScreenSize.width / scale, height: deviceType.mainScreenSize.height / scale),
      screenCornerRadius: Self.screenCornerRadius(of: deviceType))
  }

  /// The radius of a device type's screen corners in points, which its capabilities give
  /// (`DeviceCornerRadius`); 0 where they give none.
  private static func screenCornerRadius(of deviceType: SimDeviceType) -> Double {
    if let radius = deviceType.capabilities?["DeviceCornerRadius"] as? NSNumber {
      return radius.doubleValue
    }
    // As the device type's bundle has them, for a CoreSimulator that hands out something else.
    let file = deviceType.bundle?.url(forResource: "capabilities", withExtension: "plist").flatMap { NSDictionary(contentsOf: $0) }
    return ((file?["capabilities"] as? [String: Any])?["DeviceCornerRadius"] as? NSNumber)?.doubleValue ?? 0
  }
}
