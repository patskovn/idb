/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Whether macOS lets this process record what other processes play: "System Audio Recording
/// Only" under Screen & System Audio Recording in Privacy & Security.
///
/// The permission belongs to the app responsible for the process, which for a companion started
/// from a terminal is the terminal. It is asked about before a tap is made, never by making one:
/// Core Audio answers a tap from a process whose permission is undecided by asking the user, and
/// holds the call until the question is answered. With the screen locked nobody can answer, and a
/// question left open that way has been seen to leave the Mac's audio service answering no client
/// at all, so that nothing on the Mac played, until it timed out minutes later.
public enum SystemAudioCapturePermission: Sendable, Equatable {
  case granted
  case denied
  /// Nobody has been asked yet.
  case undecided
  /// This macOS has no way to ask without making a tap.
  case unknown

  public static func current() -> SystemAudioCapturePermission {
    guard let preflight else {
      return .unknown
    }
    switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
    case 0: return .granted
    case 1: return .denied
    default: return .undecided
    }
  }

  /// What to tell someone whose stream has no sound because of this permission.
  public var remedy: String {
    "The companion is not allowed to record system audio on its Mac. Start it from an app that is (a terminal listed under "
      + "System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only), or add the app that starts it there."
  }

  private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int

  /// TCC's own check, which the system frameworks use and no public API offers for this service.
  private static let preflight: Preflight? = {
    guard let framework = unsafe dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
      let symbol = unsafe dlsym(framework, "TCCAccessPreflight")
    else {
      return nil
    }
    return unsafe unsafeBitCast(symbol, to: Preflight.self)
  }()
}
