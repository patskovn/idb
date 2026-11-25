/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBVideoCore
import Foundation
import os

/// One line per encoded video frame, for measuring where latency accrues. Written only when the
/// companion's environment has `IDB_VIDEO_TRACE` naming a file; lines are appended, so a harness can
/// truncate the file between runs.
///
/// Columns, space separated: transport, stream id, sequence, submitted, encoded, handed off, bytes,
/// keyframe (1/0), encode called. The stream id tells concurrent or leftover streams apart; encode
/// called is when the converted frame was handed to the encoder (submitted to encode called is the
/// colour conversion and scaling). Times are host uptime in nanoseconds (`DispatchTime.now().uptimeNanoseconds`):
/// submitted is when the frame reached the frame pusher, encoded when the encoder produced it, handed
/// off when the transport took it.
final class VideoFrameTrace: @unchecked Sendable {
  static let shared: VideoFrameTrace? = ProcessInfo.processInfo.environment["IDB_VIDEO_TRACE"].flatMap { try? VideoFrameTrace(path: $0) }

  private let handle: FileHandle
  private let lock = NSLock()

  init(path: String) throws {
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
  }

  private let nextStreamID = OSAllocatedUnfairLock<Int>(initialState: 1)

  /// A new id for a stream's lines.
  func makeStreamID() -> Int {
    nextStreamID.withLock { value -> Int in
      defer { value += 1 }
      return value
    }
  }

  /// An `event <uptime> <text>` line, e.g. a rate-adaptation decision.
  func recordEvent(_ text: String) {
    let line = "event \(DispatchTime.now().uptimeNanoseconds) \(text)\n"
    lock.withLock {
      _ = try? handle.seekToEnd()
      handle.write(Data(line.utf8))
    }
  }

  func record(transport: String, streamID: Int, sequence: UInt64, timing: EncodedFrameTiming, handedOffAtUptimeNanos: UInt64, bytes: Int) {
    let line = "\(transport) \(streamID) \(sequence) \(timing.submittedAtUptimeNanos) \(timing.encodedAtUptimeNanos) \(handedOffAtUptimeNanos) \(bytes) \(timing.isKeyFrame ? 1 : 0) \(timing.encodeCalledAtUptimeNanos)\n"
    lock.withLock {
      // Seek every time: the file may have been truncated since the last line.
      _ = try? handle.seekToEnd()
      handle.write(Data(line.utf8))
    }
  }
}

/// Traces each frame a transport is handed, then passes it on unchanged.
final class TracingFrameConsumer: TimedFrameConsumer, Sendable {
  private let inner: any DataConsumer
  private let trace: VideoFrameTrace
  private let transport: String
  private let streamID: Int
  private let nextSequence = OSAllocatedUnfairLock<UInt64>(initialState: 0)

  init(wrapping inner: any DataConsumer, trace: VideoFrameTrace, transport: String) {
    self.inner = inner
    self.trace = trace
    self.transport = transport
    self.streamID = trace.makeStreamID()
  }

  func consumeFrame(_ data: Data, timing: EncodedFrameTiming) {
    let sequence = nextSequence.withLock { value -> UInt64 in
      defer { value += 1 }
      return value
    }
    trace.record(transport: transport, streamID: streamID, sequence: sequence, timing: timing, handedOffAtUptimeNanos: DispatchTime.now().uptimeNanoseconds, bytes: data.count)
    inner.consumeData(data)
  }

  func consumeData(_ data: Data) {
    inner.consumeData(data)
  }

  func consumeEndOfFile() {
    inner.consumeEndOfFile()
  }

  var consumption: DataConsumption {
    inner.consumption
  }
}
