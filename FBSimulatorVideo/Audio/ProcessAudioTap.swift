/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AudioToolbox
import CoreAudio
import Foundation

/// Reads what a set of the Mac's audio clients play, mixed down to stereo, as they play it.
///
/// Core Audio hands a tap's audio to a device, so the tap is put in a private aggregate device and
/// read with that device's I/O callback. The aggregate also holds the Mac's default output device,
/// whose clock the tap is read against.
///
/// Make one only when `SystemAudioCapturePermission.current()` is `granted`: see there for why.
///
/// @unchecked Sendable: the Core Audio objects are made in `init` and only read after it, apart from
/// `stop`, which the owner calls once.
// @safe: The I/O callback's identifier is only handed back to Core Audio, to stop and remove it.
@safe final class ProcessAudioTap: @unchecked Sendable {

  /// Samples as the tap delivers them: interleaved 32-bit floats, `channels` to a frame.
  let sampleRate: Double
  let channels: Int

  private let description: CATapDescription
  private let tap: AudioObjectID
  private let device: AudioObjectID
  private var ioProc: AudioDeviceIOProcID?

  /// - Parameters:
  ///   - processes: The audio clients to read, as Core Audio process objects. May be empty.
  ///   - mutesProcesses: Whether the Mac stops playing them itself while they are read.
  ///   - queue: Where `handler` is called.
  ///   - handler: Called with each block of interleaved samples and the uptime, in nanoseconds, at
  ///     which its first frame played.
  init(
    processes: [AudioObjectID], mutesProcesses: Bool, outputDeviceUID: String, queue: DispatchQueue,
    handler: @escaping @Sendable (_ samples: [Float], _ playedAtUptimeNanos: UInt64) -> Void
  ) throws {
    description = CATapDescription(stereoMixdownOfProcesses: processes)
    description.uuid = UUID()
    description.name = "idb simulator audio"
    description.isPrivate = true
    description.muteBehavior = mutesProcesses ? .mutedWhenTapped : .unmuted

    var tap = AudioObjectID(kAudioObjectUnknown)
    try HostAudioError.check(unsafe AudioHardwareCreateProcessTap(description, &tap), "tap the simulator's processes")
    self.tap = tap

    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var formatAddress = HostAudioObjects.address(kAudioTapPropertyFormat)
    let formatStatus = unsafe AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format)
    let isFloat = format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
    guard formatStatus == noErr, isFloat, format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
      AudioHardwareDestroyProcessTap(tap)
      throw HostAudioError(action: "read the tap's format (\(format.mFormatID), \(format.mBitsPerChannel) bits, \(format.mChannelsPerFrame) channels)", status: formatStatus)
    }
    sampleRate = format.mSampleRate
    let channels = Int(format.mChannelsPerFrame)
    self.channels = channels
    let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "idb simulator audio",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
    ]
    var device = AudioObjectID(kAudioObjectUnknown)
    let created = unsafe AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
    guard created == noErr else {
      AudioHardwareDestroyProcessTap(tap)
      throw HostAudioError(action: "make a device to read the tap with", status: created)
    }
    self.device = device

    var ioProc: AudioDeviceIOProcID?
    var status = unsafe AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, queue) { _, input, inputTime, _, _ in
      // The tap's streams come after the output device's own inputs, if it has any.
      let buffers = unsafe UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
      let samples: [Float]
      let count = buffers.count
      if interleaved {
        guard count >= 1, unsafe Int(buffers[count - 1].mNumberChannels) == channels, let data = unsafe buffers[count - 1].mData else {
          return
        }
        let floats = unsafe Int(buffers[count - 1].mDataByteSize) / MemoryLayout<Float>.size
        samples = unsafe Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: floats))
      } else {
        guard count >= channels else {
          return
        }
        var frames = Int.max
        for channel in 0..<channels {
          frames = unsafe min(frames, Int(buffers[count - channels + channel].mDataByteSize) / MemoryLayout<Float>.size)
        }
        var mixed = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
          guard let data = unsafe buffers[count - channels + channel].mData else {
            return
          }
          let source = unsafe data.assumingMemoryBound(to: Float.self)
          for frame in 0..<frames {
            mixed[frame * channels + channel] = unsafe source[frame]
          }
        }
        samples = mixed
      }
      guard !samples.isEmpty else {
        return
      }
      let time = unsafe inputTime.pointee
      let ticks = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : mach_absolute_time()
      handler(samples, Self.nanoseconds(fromHostTicks: ticks))
    }
    if status == noErr {
      status = unsafe AudioDeviceStart(device, ioProc)
    }
    guard status == noErr else {
      if let ioProc = unsafe ioProc {
        unsafe AudioDeviceDestroyIOProcID(device, ioProc)
      }
      AudioHardwareDestroyAggregateDevice(device)
      AudioHardwareDestroyProcessTap(tap)
      throw HostAudioError(action: "start reading the tap", status: status)
    }
    unsafe self.ioProc = ioProc
  }

  /// Changes which audio clients are read, without a break in what the others play.
  func setProcesses(_ processes: [AudioObjectID]) throws {
    description.processes = processes
    var address = HostAudioObjects.address(kAudioTapPropertyDescription)
    // The property's value is a reference to the description.
    let status = withUnsafePointer(to: description) { reference in
      unsafe AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), reference)
    }
    try HostAudioError.check(status, "change which processes the tap reads")
  }

  /// Stops reading and removes the tap; what the processes play is heard on the Mac again.
  func stop() {
    guard let ioProc = unsafe ioProc else {
      return
    }
    unsafe self.ioProc = nil
    unsafe AudioDeviceStop(device, ioProc)
    unsafe AudioDeviceDestroyIOProcID(device, ioProc)
    AudioHardwareDestroyAggregateDevice(device)
    AudioHardwareDestroyProcessTap(tap)
  }

  deinit {
    stop()
  }

  private static let timebase: (numerator: UInt64, denominator: UInt64) = {
    var info = mach_timebase_info_data_t()
    unsafe mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(max(info.denom, 1)))
  }()

  /// Host clock ticks as the nanoseconds of uptime that `DispatchTime` reads.
  static func nanoseconds(fromHostTicks ticks: UInt64) -> UInt64 {
    let (numerator, denominator) = timebase
    let (high, low) = ticks.multipliedFullWidth(by: numerator)
    return denominator.dividingFullWidth((high, low)).quotient
  }
}
