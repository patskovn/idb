/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreAudio
import FBControlCore
import FBSimulatorControl
import Foundation
import os

public enum SimulatorAudioStreamError: Error, LocalizedError {
  case notPermitted(SystemAudioCapturePermission)
  case noOutputDevice
  case alreadyStarted

  public var errorDescription: String? {
    switch self {
    case let .notPermitted(permission):
      return permission.remedy
    case .noOutputDevice:
      return "The companion's Mac has no audio output device, which the simulator's audio is read against"
    case .alreadyStarted:
      return "The audio stream was already started"
    }
  }
}

/// What a simulator plays, live, as Opus packets: its apps, SpringBoard and its system sounds, and
/// nothing else that plays on the Mac.
///
/// The simulator's processes are tapped where they play into the Mac's audio system
/// (`ProcessAudioTap`), and the tap follows them as they come and go. While it is read the Mac does
/// not play the simulator itself, unless `mutesHost` is false. Silence is not sent
/// (`AudioSilenceGate`).
///
/// @unchecked Sendable: `tap`, `tapped` and the listeners are confined to `control`; `encoder` and
/// the counts to `audio`.
public final class SimulatorAudioStream: @unchecked Sendable {
  public static let sampleRate = Int(SimulatorAudioEncoder.sampleRate)
  public static let channels = SimulatorAudioEncoder.channels
  public static let framesPerPacket = SimulatorAudioEncoder.framesPerPacket

  private let udid: String
  private let mutesHost: Bool
  private let logger: any ControlCoreLogger
  private let onPacket: @Sendable (SimulatorAudioPacket) -> Void
  private let control = DispatchQueue(label: "com.facebook.idb.simulator-audio")
  private let audio = DispatchQueue(label: "com.facebook.idb.simulator-audio.samples", qos: .userInteractive)

  private var tap: ProcessAudioTap?
  private var tapped: [AudioObjectID] = []
  /// Each stops listening to one thing on the audio system.
  private var stopListening: [() -> Void] = []
  private var stopped = false

  private var encoder: SimulatorAudioEncoder?
  private var packets = 0
  private var bytes = 0
  private var runs = 0

  /// - Parameters:
  ///   - mutesHost: Whether the Mac stops playing the simulator's sound itself while it is streamed.
  ///   - onPacket: Called with each packet, in order, on a queue of the stream's own.
  public init(
    simulator: Simulator, mutesHost: Bool = true, logger: any ControlCoreLogger, onPacket: @escaping @Sendable (SimulatorAudioPacket) -> Void
  ) {
    udid = simulator.udid
    self.mutesHost = mutesHost
    self.logger = logger
    self.onPacket = onPacket
  }

  /// Starts reading the simulator's audio. Throws when the Mac does not allow it or cannot do it;
  /// nothing is left running then.
  public func start() throws {
    try control.sync {
      guard tap == nil, !stopped else {
        throw SimulatorAudioStreamError.alreadyStarted
      }
      let permission = SystemAudioCapturePermission.current()
      guard permission == .granted else {
        throw SimulatorAudioStreamError.notPermitted(permission)
      }
      let started = try makeTap()
      // Apps start and stop playing for as long as the stream runs.
      listen(to: kAudioHardwarePropertyProcessObjectList) { [weak self] in
        self?.followProcesses()
      }
      // The tap is read against the output device's clock, so it moves with the default output.
      listen(to: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
        self?.followOutputDevice()
      }
      logger.log("Simulator audio: reading \(tapped.count) processes at \(Int(started.sampleRate)) Hz\(mutesHost ? ", muted on this Mac" : "")")
    }
  }

  /// On `control`. Taps the simulator's processes as they are now and starts encoding what they play.
  @discardableResult
  private func makeTap() throws -> ProcessAudioTap {
    guard let output = HostAudioObjects.defaultOutputDeviceUID() else {
      throw SimulatorAudioStreamError.noOutputDevice
    }
    let processes = simulatorProcesses()
    let tap = try ProcessAudioTap(processes: processes, mutesProcesses: mutesHost, outputDeviceUID: output, queue: audio) { [weak self] samples, playedAt in
      self?.encode(samples, playedAt: playedAt)
    }
    do {
      let encoder = try SimulatorAudioEncoder(sampleRate: tap.sampleRate, channels: tap.channels)
      audio.sync { self.encoder = encoder }
    } catch {
      tap.stop()
      throw error
    }
    self.tap = tap
    tapped = processes
    return tap
  }

  /// On `control`. Calls `changed` there whenever the audio system's `selector` changes.
  private func listen(to selector: AudioObjectPropertySelector, changed: @escaping @Sendable () -> Void) {
    let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
    var address = HostAudioObjects.address(selector)
    guard unsafe AudioObjectAddPropertyListenerBlock(HostAudioObjects.system, &address, control, block) == noErr else {
      return
    }
    stopListening.append { [control] in
      var address = HostAudioObjects.address(selector)
      unsafe AudioObjectRemovePropertyListenerBlock(HostAudioObjects.system, &address, control, block)
    }
  }

  /// Stops reading; the Mac plays the simulator's sound itself again.
  public func stop() {
    control.sync {
      guard !stopped else {
        return
      }
      stopped = true
      for stop in stopListening {
        stop()
      }
      stopListening.removeAll()
      guard let tap else {
        return
      }
      tap.stop()
      self.tap = nil
      // Blocks already handed over are encoded before the counts are read.
      let (packets, bytes, runs) = audio.sync { (self.packets, self.bytes, self.runs) }
      let tenths = packets * Self.framesPerPacket * 10 / Self.sampleRate
      logger.log("Simulator audio ended: \(packets) packets (\(tenths / 10).\(tenths % 10) s of sound in \(runs) runs), \(bytes) bytes")
    }
  }

  private func simulatorProcesses() -> [AudioObjectID] {
    guard let launchd = SimulatorAudioProcesses.launchdPID(udid: udid) else {
      return []
    }
    return SimulatorAudioProcesses.objects(under: launchd, among: HostAudioObjects.processes()).sorted()
  }

  /// On `control`, when the Mac's list of audio clients has changed.
  private func followProcesses() {
    guard let tap, !stopped else {
      return
    }
    let processes = simulatorProcesses()
    guard processes != tapped else {
      return
    }
    do {
      try tap.setProcesses(processes)
      logger.log("Simulator audio: reading \(processes.count) processes, was \(tapped.count)")
      tapped = processes
    } catch {
      logger.log("Simulator audio: \(error.localizedDescription)")
    }
  }

  /// On `control`, when the Mac's default output device has changed: the tap is made again against
  /// the new one. The packet after it starts a run, the encoder being new.
  private func followOutputDevice() {
    guard let tap, !stopped else {
      return
    }
    tap.stop()
    self.tap = nil
    do {
      let tap = try makeTap()
      logger.log("Simulator audio: the Mac's output device changed; reading \(tapped.count) processes at \(Int(tap.sampleRate)) Hz")
    } catch {
      logger.log("Simulator audio stopped: the Mac's output device changed, and \(error.localizedDescription)")
    }
  }

  /// On `audio`.
  private func encode(_ samples: [Float], playedAt: UInt64) {
    guard let encoder else {
      return
    }
    for packet in encoder.append(samples, playedAtUptimeNanos: playedAt) {
      packets += 1
      bytes += packet.data.count
      if packet.startsRun {
        runs += 1
      }
      onPacket(packet)
    }
  }
}
