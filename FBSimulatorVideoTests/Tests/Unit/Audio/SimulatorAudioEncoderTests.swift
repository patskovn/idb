/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFAudio
@testable import FBSimulatorVideo
import XCTest

final class AudioSilenceGateTests: XCTestCase {

  func testSilenceBeforeAnySoundIsNotSent() {
    var gate = AudioSilenceGate(hangover: 3)
    for _ in 0..<10 {
      XCTAssertFalse(gate.admit(peak: 0).send)
    }
  }

  func testTheFirstBlockOfSoundStartsARunAndTheNextContinuesIt() {
    var gate = AudioSilenceGate(hangover: 3)
    _ = gate.admit(peak: 0)
    let first = gate.admit(peak: 0.5)
    let second = gate.admit(peak: 0.5)
    XCTAssertTrue(first.send && first.startsRun)
    XCTAssertTrue(second.send && !second.startsRun)
  }

  func testSilenceIsSentForTheHangoverAndThenTheRunEnds() {
    var gate = AudioSilenceGate(hangover: 3)
    _ = gate.admit(peak: 0.5)
    let sent = (0..<6).map { _ in gate.admit(peak: 0).send }
    XCTAssertEqual(sent, [true, true, true, false, false, false])
  }

  func testSoundInsideTheHangoverContinuesTheRunAndSoundAfterItStartsAnother() {
    var gate = AudioSilenceGate(hangover: 3)
    _ = gate.admit(peak: 0.5)
    _ = gate.admit(peak: 0)
    XCTAssertFalse(gate.admit(peak: 0.5).startsRun)
    for _ in 0..<5 {
      _ = gate.admit(peak: 0)
    }
    XCTAssertTrue(gate.admit(peak: 0.5).startsRun)
  }

  func testNoiseUnderTheThresholdIsSilence() {
    var gate = AudioSilenceGate(hangover: 3)
    XCTAssertFalse(gate.admit(peak: AudioSilenceGate.silencePeak / 2).send)
    XCTAssertTrue(gate.admit(peak: AudioSilenceGate.silencePeak * 2).send)
  }
}

final class SimulatorAudioEncoderTests: XCTestCase {

  /// Stereo blocks of a 1 kHz tone at half scale, as a tap delivers them: 512 frames at a time.
  private func tone(seconds: Double, sampleRate: Double = 48_000, blockFrames: Int = 512, amplitude: Float = 0.5) -> [[Float]] {
    let frames = Int(seconds * sampleRate)
    var blocks: [[Float]] = []
    var frame = 0
    while frame < frames {
      let count = min(blockFrames, frames - frame)
      var block = [Float](repeating: 0, count: count * 2)
      for index in 0..<count {
        let value = amplitude * Float(sin(2 * Double.pi * 1000 * Double(frame + index) / sampleRate))
        block[2 * index] = value
        block[2 * index + 1] = value
      }
      blocks.append(block)
      frame += count
    }
    return blocks
  }

  /// Feeds blocks as if each played right after the one before, the first at `start`.
  private func feed(_ blocks: [[Float]], to encoder: SimulatorAudioEncoder, sampleRate: Double = 48_000, start: UInt64 = 1_000_000_000) -> [SimulatorAudioPacket] {
    var packets: [SimulatorAudioPacket] = []
    var frames = 0
    for block in blocks {
      packets += encoder.append(block, playedAtUptimeNanos: start + UInt64(Double(frames) / sampleRate * 1e9))
      frames += block.count / 2
    }
    return packets
  }

  /// Decodes packets the way a client does, from their bytes alone, and returns the left channel.
  private func decode(_ packets: [SimulatorAudioPacket]) throws -> [Float] {
    var description = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 480, mBytesPerFrame: 0,
      mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    let opus = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
    let pcm = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let decoder = try XCTUnwrap(AVAudioConverter(from: opus, to: pcm))
    var samples: [Float] = []
    for packet in packets {
      let compressed = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.data.count)
      packet.data.copyBytes(to: compressed.data.assumingMemoryBound(to: UInt8.self), count: packet.data.count)
      compressed.byteLength = UInt32(packet.data.count)
      compressed.packetCount = 1
      compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.data.count))
      let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1920))
      var given = false
      var error: NSError?
      let status = decoder.convert(to: output, error: &error) { _, inputStatus in
        if given {
          inputStatus.pointee = .noDataNow
          return nil
        }
        given = true
        inputStatus.pointee = .haveData
        return compressed
      }
      XCTAssertNotEqual(status, .error, "\(String(describing: error))")
      samples += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
    }
    return samples
  }

  func testSilenceProducesNoPackets() throws {
    let encoder = try SimulatorAudioEncoder(sampleRate: 48_000, channels: 2)
    let silence = [[Float]](repeating: [Float](repeating: 0, count: 1024), count: 200)
    XCTAssertTrue(feed(silence, to: encoder).isEmpty)
  }

  func testATonePacksIntoTenMillisecondPacketsStampedWhereTheyPlayed() throws {
    let encoder = try SimulatorAudioEncoder(sampleRate: 48_000, channels: 2)
    let packets = feed(tone(seconds: 1), to: encoder, start: 5_000_000_000)

    // 48000 frames are 100 packets of 480.
    XCTAssertEqual(packets.count, 100)
    XCTAssertEqual(packets.map(\.startsRun), [true] + [Bool](repeating: false, count: 99))
    for (index, packet) in packets.enumerated() {
      let expected = 5_000_000_000 + Int64(index) * 10_000_000
      // Within a frame of the 10 ms grid: blocks of 512 do not land on it, so the time is carried over.
      XCTAssertLessThan(abs(Int64(packet.playedAtUptimeNanos) - expected), 25_000, "packet \(index)")
      XCTAssertFalse(packet.data.isEmpty)
    }
  }

  func testThePacketsDecodeToTheToneAtItsLevel() throws {
    let encoder = try SimulatorAudioEncoder(sampleRate: 48_000, channels: 2)
    let decoded = try decode(feed(tone(seconds: 1), to: encoder))

    XCTAssertGreaterThan(decoded.count, 47_000)
    // A half-scale sine has an RMS of 0.354; the first packets hold the codec's start.
    let steady = decoded.suffix(24_000)
    let rms = (steady.reduce(0) { $0 + Double($1 * $1) } / Double(steady.count)).squareRoot()
    XCTAssertEqual(rms, 0.354, accuracy: 0.03)
  }

  func testARunEndsAfterTheHangoverAndTheNextSoundStartsAnother() throws {
    let encoder = try SimulatorAudioEncoder(sampleRate: 48_000, channels: 2)
    let silence = [[Float]](repeating: [Float](repeating: 0, count: 1024), count: 188)  // two seconds
    let packets = feed(tone(seconds: 0.5) + silence + tone(seconds: 0.5), to: encoder)

    // Each half second of tone is 50 packets, the first followed by the hangover of silence.
    XCTAssertEqual(packets.count, 50 + SimulatorAudioEncoder.hangoverPackets + 50, accuracy: 2)
    XCTAssertEqual(packets.filter(\.startsRun).count, 2)
    let second = try XCTUnwrap(packets.lastIndex(where: \.startsRun))
    // The second run is stamped where it played: two and a half seconds after the first began.
    XCTAssertEqual(Double(packets[second].playedAtUptimeNanos - packets[0].playedAtUptimeNanos) / 1e9, 2.5, accuracy: 0.02)
  }

  func testAudioAtAnotherRateIsConvertedTo48kHz() throws {
    let encoder = try SimulatorAudioEncoder(sampleRate: 44_100, channels: 2)
    let packets = feed(tone(seconds: 1, sampleRate: 44_100), to: encoder, sampleRate: 44_100)

    // A second of sound is still a hundred packets, less what the converter holds back.
    XCTAssertEqual(packets.count, 100, accuracy: 2)
    let decoded = try decode(packets)
    let steady = decoded.suffix(24_000)
    let rms = (steady.reduce(0) { $0 + Double($1 * $1) } / Double(steady.count)).squareRoot()
    XCTAssertEqual(rms, 0.354, accuracy: 0.03)
  }

  func testOnlyStereoIsEncoded() {
    XCTAssertThrowsError(try SimulatorAudioEncoder(sampleRate: 48_000, channels: 1))
  }
}

final class SimulatorAudioProcessesTests: XCTestCase {

  /// launchd_sim is 100; 101 and 102 are its children, 103 a grandchild, 200 another simulator's
  /// launchd with its child 201, and 300 a process of the Mac's own.
  private let parents: [pid_t: pid_t] = [100: 1, 101: 100, 102: 100, 103: 102, 200: 1, 201: 200, 300: 1]

  private func objects(_ pids: [pid_t], under launchd: pid_t = 100) -> [AudioObjectID] {
    SimulatorAudioProcesses.objects(
      under: launchd, among: pids.map { HostAudioObjects.Process(object: AudioObjectID($0) + 1000, pid: $0) }, parent: { self.parents[$0] })
  }

  func testTheSimulatorsChildrenAndTheirChildrenAreItsProcesses() {
    XCTAssertEqual(objects([101, 102, 103]), [1101, 1102, 1103])
  }

  func testAnotherSimulatorsProcessesAndTheMacsOwnAreNot() {
    XCTAssertEqual(objects([101, 201, 300, 200]), [1101])
  }

  func testTheLaunchdItselfAndAProcessThatHasExitedAreNot() {
    XCTAssertEqual(objects([100, 999]), [])
  }

  func testAProcessTooFarDownIsNotLookedFor() {
    var chain: [pid_t: pid_t] = [100: 1]
    for pid in 101...120 {
      chain[pid_t(pid)] = pid_t(pid - 1)
    }
    let found = SimulatorAudioProcesses.objects(
      under: 100, among: [HostAudioObjects.Process(object: 1, pid: 103), HostAudioObjects.Process(object: 2, pid: 120)], parent: { chain[$0] })
    XCTAssertEqual(found, [1])
  }
}
