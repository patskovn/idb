/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import FBControlCore
import FBSimulatorControl
import Foundation

/// Frame pusher abstraction. Concrete pushers convert + write frames to the consumer.
protocol FramePusher: AnyObject {
  func setup(source: VideoFrameSource, edgeInsets: VideoStreamEdgeInsets) throws
  func tearDown() throws
  func writeEncodedFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameNumber: UInt,
    timeAtFirstFrame: TimeInterval,
    frameDuration: TimeInterval,
    forceKeyFrame: Bool
  ) throws
  /// As `writeEncodedFrame`, for a source that something else may write into while it is read. `sourceIsIntact` is
  /// asked once, after the pusher has read the source for the last time: when it answers no, the frame is not
  /// encoded and the result is false, and the caller reads the source again. A pusher that cannot hold a frame back
  /// writes it regardless and never asks.
  func writeEncodedFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameNumber: UInt,
    timeAtFirstFrame: TimeInterval,
    frameDuration: TimeInterval,
    forceKeyFrame: Bool,
    sourceIsIntact: () -> Bool
  ) throws -> Bool
  /// Starts the encoder on a throwaway frame whose output is discarded, so the first frame written does not wait
  /// for it. Called once, after `setup`.
  func warm(with pixelBuffer: CVPixelBuffer) throws
  /// Hands on every frame the encoder still holds, without ending it, so a pusher set aside and taken up again
  /// cannot emit frames older than those written since.
  func completeFrames()
  /// A frame was written although the source surface changed while it was being read; counted in the pusher's stats.
  func recordTornFrame()
  /// A read of the source was thrown away and done again because the surface changed under it.
  func recordReadRedone()
  /// How long after the Simulator reported a frame it was read from the surface; kept in the pusher's stats.
  func recordCaptureDelay(_ seconds: TimeInterval)
  func currentStats() -> VideoEncoderStats?
  /// Changes the encoder's average bitrate mid-stream, for rate adaptation. Ignored by pushers
  /// without a bitrate.
  func setAverageBitRate(_ bitsPerSecond: Int)
}

extension FramePusher {
  func writeEncodedFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameNumber: UInt,
    timeAtFirstFrame: TimeInterval,
    frameDuration: TimeInterval,
    forceKeyFrame: Bool,
    sourceIsIntact: () -> Bool
  ) throws -> Bool {
    try writeEncodedFrame(pixelBuffer, frameNumber: frameNumber, timeAtFirstFrame: timeAtFirstFrame, frameDuration: frameDuration, forceKeyFrame: forceKeyFrame)
    return true
  }

  func recordReadRedone() {}
  func setAverageBitRate(_ bitsPerSecond: Int) {}
  func warm(with pixelBuffer: CVPixelBuffer) throws {}
  func completeFrames() {}
  func recordTornFrame() {}
  func recordCaptureDelay(_ seconds: TimeInterval) {}
  func currentStats() -> VideoEncoderStats? { nil }
}

/// Set-up frame pushers keyed by the source each was set up for, so a stream that switches between displays
/// takes one rather than starting an encoder on the switch.
struct FramePusherPool {
  private var pushers: [VideoFrameSource: any FramePusher] = [:]

  func contains(_ source: VideoFrameSource) -> Bool {
    pushers[source] != nil
  }

  mutating func take(_ source: VideoFrameSource) -> (any FramePusher)? {
    pushers.removeValue(forKey: source)
  }

  /// Returns the pusher already kept for `source`, which the caller tears down.
  mutating func keep(_ pusher: any FramePusher, for source: VideoFrameSource) -> (any FramePusher)? {
    pushers.updateValue(pusher, forKey: source)
  }

  mutating func removeAll() -> [any FramePusher] {
    defer { pushers = [:] }
    return Array(pushers.values)
  }
}
