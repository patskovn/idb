/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import Testing

@testable import idb_video

@Suite
struct AudioJitterBufferTests {

  private func write(_ buffer: AudioJitterBuffer, frames: Int, value: Float) {
    let left = [Float](repeating: value, count: frames)
    let right = [Float](repeating: -value, count: frames)
    left.withUnsafeBufferPointer { l in
      right.withUnsafeBufferPointer { r in
        buffer.write(left: l, right: r)
      }
    }
  }

  private func read(_ buffer: AudioJitterBuffer, frames: Int) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: 9, count: frames)
    var right = [Float](repeating: 9, count: frames)
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        buffer.read(left: l.baseAddress!, right: r.baseAddress!, frames: frames)
      }
    }
    return (left, right)
  }

  @Test
  func anEmptyBufferPlaysSilence() {
    let buffer = AudioJitterBuffer(targetFrames: 100, maximumFrames: 1000)
    let played = read(buffer, frames: 64)
    #expect(played.left == [Float](repeating: 0, count: 64))
    #expect(played.right == [Float](repeating: 0, count: 64))
    #expect(buffer.counts.played == 0)
  }

  @Test
  func aSoundStartsAfterTheTargetDelayOfSilence() {
    let buffer = AudioJitterBuffer(targetFrames: 100, maximumFrames: 1000)
    write(buffer, frames: 50, value: 0.5)
    #expect(buffer.buffered == 150)

    let played = read(buffer, frames: 160)
    #expect(played.left == [Float](repeating: 0, count: 100) + [Float](repeating: 0.5, count: 50) + [Float](repeating: 0, count: 10))
    #expect(played.right.dropFirst(100).prefix(50) == ArraySlice([Float](repeating: -0.5, count: 50)))
    #expect(buffer.counts.starts == 1)
    #expect(buffer.counts.played == 150)
  }

  @Test
  func soundThatFollowsWhileSomeIsWaitingIsNotDelayedAgain() {
    let buffer = AudioJitterBuffer(targetFrames: 100, maximumFrames: 1000)
    write(buffer, frames: 50, value: 0.5)
    _ = read(buffer, frames: 120)
    write(buffer, frames: 50, value: 0.25)

    #expect(buffer.buffered == 80)
    #expect(read(buffer, frames: 80).left == [Float](repeating: 0.5, count: 30) + [Float](repeating: 0.25, count: 50))
    #expect(buffer.counts.starts == 1)
  }

  @Test
  func aSoundAfterTheBufferRanDryIsDelayedAgain() {
    let buffer = AudioJitterBuffer(targetFrames: 100, maximumFrames: 1000)
    write(buffer, frames: 50, value: 0.5)
    _ = read(buffer, frames: 200)
    write(buffer, frames: 50, value: 0.25)

    #expect(buffer.buffered == 150)
    #expect(buffer.counts.starts == 2)
  }

  @Test
  func tooMuchWaitingIsDroppedBackToTheTarget() {
    let buffer = AudioJitterBuffer(targetFrames: 100, maximumFrames: 300)
    write(buffer, frames: 150, value: 0.1)  // 250 with the delay
    write(buffer, frames: 100, value: 0.2)  // 350: over

    #expect(buffer.buffered == 100)
    #expect(buffer.counts.overflows == 1)
    #expect(buffer.counts.dropped == 250)
    // What is left is the newest sound.
    #expect(read(buffer, frames: 100).left == [Float](repeating: 0.2, count: 100))
  }

  @Test
  func theRingWrapsAroundWithoutLosingOrder() {
    let buffer = AudioJitterBuffer(targetFrames: 0, maximumFrames: 20_000)
    var expected: [Float] = []
    var played: [Float] = []
    // Many times the ring's capacity, in writes and reads of sizes that do not divide it.
    for round in 0..<400 {
      let value = Float(round % 97) / 100
      write(buffer, frames: 701, value: value)
      expected += [Float](repeating: value, count: 701)
      played += read(buffer, frames: 701).left
    }
    #expect(played == expected)
  }
}

@Suite
struct AudioPacketParsingTests {

  /// A packet as the companion writes it.
  private func packet(sequence: UInt64, startsRun: Bool, playedAt: UInt64, payload: [UInt8]) -> Data {
    var bytes: [UInt8] = [3, startsRun ? 1 : 0, 0, 0]
    bytes += QUICVideoWire.bigEndianBytes(UInt64(payload.count)).suffix(4)
    bytes += QUICVideoWire.bigEndianBytes(sequence)
    bytes += QUICVideoWire.bigEndianBytes(playedAt)
    return Data(bytes + payload)
  }

  @Test
  func wholePacketsAreTakenAndAPartialOneIsLeft() throws {
    let first = packet(sequence: 4, startsRun: true, playedAt: 1000, payload: [1, 2, 3])
    let second = packet(sequence: 5, startsRun: false, playedAt: 2000, payload: [4, 5])
    var buffer = first + second.prefix(20)

    let packets = try #require(QUICVideoWire.takeAudioPackets(from: &buffer))
    #expect(packets == [QUICVideoWire.AudioPacket(sequence: 4, startsRun: true, playedAtUptimeNanos: 1000, payload: Data([1, 2, 3]))])
    #expect(buffer == second.prefix(20))

    // The rest of the second arrives.
    buffer.append(second.dropFirst(20))
    let rest = try #require(QUICVideoWire.takeAudioPackets(from: &buffer))
    #expect(rest == [QUICVideoWire.AudioPacket(sequence: 5, startsRun: false, playedAtUptimeNanos: 2000, payload: Data([4, 5]))])
    #expect(buffer.isEmpty)
  }

  @Test
  func severalPacketsInOneReadAreAllTaken() throws {
    var buffer = Data()
    for sequence in 0..<5 {
      buffer.append(packet(sequence: UInt64(sequence), startsRun: sequence == 0, playedAt: UInt64(sequence) * 10, payload: [UInt8(sequence)]))
    }
    let packets = try #require(QUICVideoWire.takeAudioPackets(from: &buffer))
    #expect(packets.map(\.sequence) == [0, 1, 2, 3, 4])
    #expect(packets.map(\.startsRun) == [true, false, false, false, false])
  }

  @Test
  func bytesThatAreNotAnAudioStreamAreRefusedAndLeftAlone() {
    var buffer = packet(sequence: 0, startsRun: true, playedAt: 0, payload: [1]) + Data(repeating: 9, count: 30)
    let before = buffer
    #expect(QUICVideoWire.takeAudioPackets(from: &buffer) == nil)
    #expect(buffer == before)
  }

  @Test
  func aBufferThatDoesNotStartAtZeroIsReadFromItsStart() throws {
    let data = Data([0xff, 0xff]) + packet(sequence: 9, startsRun: false, playedAt: 7, payload: [8])
    var buffer = data.dropFirst(2)
    let packets = try #require(QUICVideoWire.takeAudioPackets(from: &buffer))
    #expect(packets.map(\.sequence) == [9])
    #expect(buffer.isEmpty)
  }
}
