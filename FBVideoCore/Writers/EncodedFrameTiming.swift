/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import FBControlCore
import Foundation

/// When an encoded frame entered and left the encoder, on the host's uptime clock
/// (`DispatchTime.now().uptimeNanoseconds`, which is `mach_absolute_time` and stops while asleep).
public struct EncodedFrameTiming: Sendable, Equatable {
  /// When the frame was handed to the frame pusher, before colour conversion and encoding.
  public let submittedAtUptimeNanos: UInt64
  /// When the frame, converted, was handed to the encoder.
  public let encodeCalledAtUptimeNanos: UInt64
  /// When the encoder produced the frame.
  public let encodedAtUptimeNanos: UInt64
  public let isKeyFrame: Bool

  public init(submittedAtUptimeNanos: UInt64, encodeCalledAtUptimeNanos: UInt64? = nil, encodedAtUptimeNanos: UInt64, isKeyFrame: Bool) {
    self.submittedAtUptimeNanos = submittedAtUptimeNanos
    self.encodeCalledAtUptimeNanos = encodeCalledAtUptimeNanos ?? submittedAtUptimeNanos
    self.encodedAtUptimeNanos = encodedAtUptimeNanos
    self.isKeyFrame = isKeyFrame
  }
}

/// A consumer that wants each encoded frame with its timing. The compressed-video writers hand such a
/// consumer every frame through `consumeFrame` instead of `consumeData`.
public protocol TimedFrameConsumer: DataConsumer {
  func consumeFrame(_ data: Data, timing: EncodedFrameTiming)
}

/// Carries the submit time from the frame pusher to the writer on the encoded sample itself, so it
/// survives the encoder's asynchronous output handler without a side table.
public enum EncodedFrameTimingAttachment {
  private static var submittedKey: CFString {
    "com.facebook.idb.submittedAtUptimeNanos" as CFString
  }

  private static var encodeCalledKey: CFString {
    "com.facebook.idb.encodeCalledAtUptimeNanos" as CFString
  }

  public static func attach(submittedAtUptimeNanos: UInt64, encodeCalledAtUptimeNanos: UInt64, to sampleBuffer: CMSampleBuffer) {
    CMSetAttachment(sampleBuffer, key: submittedKey, value: NSNumber(value: submittedAtUptimeNanos), attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
    CMSetAttachment(sampleBuffer, key: encodeCalledKey, value: NSNumber(value: encodeCalledAtUptimeNanos), attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
  }

  public static func submittedAtUptimeNanos(of sampleBuffer: CMSampleBuffer) -> UInt64? {
    (CMGetAttachment(sampleBuffer, key: submittedKey, attachmentModeOut: nil) as? NSNumber)?.uint64Value
  }

  public static func encodeCalledAtUptimeNanos(of sampleBuffer: CMSampleBuffer) -> UInt64? {
    (CMGetAttachment(sampleBuffer, key: encodeCalledKey, attachmentModeOut: nil) as? NSNumber)?.uint64Value
  }
}
