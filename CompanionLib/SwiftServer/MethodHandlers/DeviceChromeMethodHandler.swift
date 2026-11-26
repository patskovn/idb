/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift

/// Answers where the hardware buttons are on a simulator's body, for a client that draws them
/// around its picture of the screen.
struct DeviceChromeMethodHandler {

  let target: CompanionTarget

  func handle() throws -> Idb_DeviceChromeResponse {
    let chrome: SimulatorChrome
    do {
      chrome = try target.simulator().chrome()
    } catch let error as SimulatorChromeError {
      // The device has no body described, which the caller can do without.
      throw RPCError(code: .notFound, message: error.localizedDescription)
    }
    return Self.response(for: chrome)
  }

  static func response(for chrome: SimulatorChrome) -> Idb_DeviceChromeResponse {
    .with {
      $0.identifier = chrome.identifier
      $0.screenWidthPoints = chrome.screenSize.width
      $0.screenHeightPoints = chrome.screenSize.height
      $0.screenCornerRadius = chrome.screenCornerRadius
      $0.buttons = chrome.buttons.map { button in
        .with {
          $0.name = button.name
          $0.title = button.title
          $0.kind = button.kind
          $0.edge = edge(button.edge)
          $0.start = button.start
          $0.length = button.length
          $0.usagePage = UInt32(clamping: button.usagePage)
          $0.usage = UInt32(clamping: button.usage)
        }
      }
    }
  }

  private static func edge(_ edge: SimulatorChrome.Edge) -> Idb_DeviceChromeResponse.Edge {
    switch edge {
    case .left: return .left
    case .right: return .right
    case .top: return .top
    case .bottom: return .bottom
    }
  }
}
