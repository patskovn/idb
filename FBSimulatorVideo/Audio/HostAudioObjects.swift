/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreAudio
import Foundation

/// A Core Audio call that failed, with what it was doing.
struct HostAudioError: Error, LocalizedError {
  let action: String
  let status: OSStatus

  var errorDescription: String? {
    "Could not \(action): Core Audio error \(status)"
  }

  static func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else {
      throw HostAudioError(action: action, status: status)
    }
  }
}

/// Reads of the Mac's audio system that the simulator audio tap needs.
enum HostAudioObjects {

  static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }

  static let system = AudioObjectID(kAudioObjectSystemObject)

  /// A process that is a client of the audio system: its Core Audio object and its pid.
  struct Process: Equatable {
    let object: AudioObjectID
    let pid: pid_t
  }

  /// Every process that is a client of the audio system now.
  static func processes() -> [Process] {
    var address = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard unsafe AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard unsafe AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
      return []
    }
    return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { object in
      var pid: pid_t = 0
      var pidSize = UInt32(MemoryLayout<pid_t>.size)
      var pidAddress = self.address(kAudioProcessPropertyPID)
      guard unsafe AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else {
        return nil
      }
      return Process(object: object, pid: pid)
    }
  }

  /// The device the Mac plays through by default, by its UID.
  static func defaultOutputDeviceUID() -> String? {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = address(kAudioHardwarePropertyDefaultOutputDevice)
    guard unsafe AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else {
      return nil
    }
    var uid: Unmanaged<CFString>?
    var uidSize = unsafe UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var uidAddress = self.address(kAudioDevicePropertyDeviceUID)
    guard unsafe AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid = unsafe uid else {
      return nil
    }
    return unsafe uid.takeRetainedValue() as String
  }
}
