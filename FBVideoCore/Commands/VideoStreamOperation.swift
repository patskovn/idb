/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Streams encoded video frames to a data consumer. `Sendable` because the async lifecycle methods
/// are awaited across concurrency domains.
public protocol VideoStreamOperation: AnyObject, Sendable {
  /// Starts the Streaming, to a Data Consumer.
  func startStreaming(_ consumer: any DataConsumer) async throws

  /// Stops the Streaming.
  func stopStreaming() async throws

  /// Waits for the stream to complete (returns once it has stopped).
  func awaitCompletion() async throws

  /// Asks for the next encoded frame to be a keyframe, so a consumer that joined late or lost
  /// frames can resume decoding. Fire-and-forget; a stream with no keyframes ignores it.
  func requestKeyFrame()

  /// Changes the encoder's average bitrate, for rate adaptation. Fire-and-forget; a stream without a
  /// bitrate ignores it.
  func setAverageBitRate(_ bitsPerSecond: Int)
}

public extension VideoStreamOperation {
  func requestKeyFrame() {}
  func setAverageBitRate(_ bitsPerSecond: Int) {}
}
