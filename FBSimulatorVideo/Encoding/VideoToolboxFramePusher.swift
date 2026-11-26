/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import CoreVideo
import FBControlCore
import FBSimulatorControl
import FBVideoCore
import Foundation
import VideoToolbox
import os

extension CMFormatDescription {
  /// `chromaFormat` in an HEVC decoder configuration record for 4:4:4.
  static let hevcChromaFormat444: UInt8 = 3

  /// The chroma format an HEVC stream's decoder configuration record (`hvcC`) declares: 1 for 4:2:0, 2 for 4:2:2,
  /// 3 for 4:4:4. nil when the description carries no such record.
  var hevcChromaFormat: UInt8? {
    let atoms = CMFormatDescriptionGetExtension(self, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
    // The record's 17th byte: two bits of chroma format under six reserved ones.
    guard let record = atoms?["hvcC"] as? Data, record.count > 16 else {
      return nil
    }
    return record[record.startIndex + 16] & 0x3
  }
}

/// Errors from the VideoToolbox sessions a `VideoToolboxFramePusher` (and `PixelBufferConverter`) drives.
enum VideoToolboxFramePusherError: Error {
  case failedToCreatePixelTransferSession(status: OSStatus)
  case failedToStartCompressionSession(status: OSStatus)
  case compressionSessionNil
  case failedToSetCompressionSessionProperties(status: OSStatus)
  case failedToPrepareCompressionSession(status: OSStatus)
  case missingCompressionSession
  case failedToCompress(status: OSStatus)
  case fullChromaNotEncoded
}

extension VideoToolboxFramePusherError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .failedToCreatePixelTransferSession(let status):
      return "Failed to create VTPixelTransferSession: \(status)"
    case .failedToStartCompressionSession(let status):
      return "Failed to start Compression Session \(status)"
    case .compressionSessionNil:
      return "Failed to start Compression Session (nil)"
    case .failedToSetCompressionSessionProperties(let status):
      return "Failed to set compression session properties \(status)"
    case .failedToPrepareCompressionSession(let status):
      return "Failed to prepare compression session \(status)"
    case .missingCompressionSession:
      return "No compression session"
    case .failedToCompress(let status):
      return "Failed to compress \(status)"
    case .fullChromaNotEncoded:
      return "The encoder took the 4:4:4 profile but did not encode 4:4:4"
    }
  }
}

/// Encodes frames via a VTCompressionSession (BGRA→YCbCr via `PixelBufferConverter`) and hands each
/// encoded sample to an `EncodedSampleConsumer` — a transport writer, a JPEG framer or a file
/// writer. Outcomes are accounted for by `EncoderStatsRecorder`.
///
/// @unchecked Sendable: `VTCompressionSessionEncodeFrame`'s `@Sendable` output handler can run on a
/// VideoToolbox thread after the encode call returns, so it captures `self`. VideoToolbox invokes a
/// session's output handlers serially, in decode order, so the handler's two collaborators are never
/// entered concurrently: the encoded-sample consumer, whose state (a transport writer's continuity
/// counters, the Minicap header flag, the file writer) is touched only from the handler, and the
/// stats recorder, which additionally locks the counters the owning actor reads. The pusher's own
/// stored properties are immutable after `setup`. `tearDown` flushes every pending handler before
/// it invalidates the session.
final class VideoToolboxFramePusher: FramePusher, @unchecked Sendable {
  let settings: VideoToolboxEncoderSettings
  /// The scale factor between 0-1. nil for no scaling.
  let scaleFactor: Double?
  let videoCodec: CMVideoCodecType
  let encodedSampleConsumer: any EncodedSampleConsumer
  let logger: any ControlCoreLogger

  var compressionSession: VTCompressionSession?
  /// BGRA→YCbCr, in the encoder's input format at the encoded output size; nil until `setup`.
  private var converter: PixelBufferConverter?
  let statsRecorder: EncoderStatsRecorder

  init(
    settings: VideoToolboxEncoderSettings,
    scaleFactor: Double?,
    videoCodec: CMVideoCodecType,
    encodedSampleConsumer: any EncodedSampleConsumer,
    logger: any ControlCoreLogger
  ) {
    self.settings = settings
    self.scaleFactor = scaleFactor
    self.encodedSampleConsumer = encodedSampleConsumer
    self.logger = logger
    self.videoCodec = videoCodec
    self.statsRecorder = EncoderStatsRecorder(logger: logger)
  }

  /// The output handler: hands the sample to the encoded-sample consumer and records the outcome.
  func handleCompressedSampleBuffer(_ sampleBuffer: CMSampleBuffer?, encodeStatus: OSStatus, infoFlags: VTEncodeInfoFlags) {
    statsRecorder.record(outcome(of: sampleBuffer, encodeStatus: encodeStatus, infoFlags: infoFlags))
  }

  private func outcome(of sampleBuffer: CMSampleBuffer?, encodeStatus: OSStatus, infoFlags: VTEncodeInfoFlags) -> EncoderStatsRecorder.Outcome {
    if encodeStatus != noErr {
      return .encodeError(encodeStatus)
    }
    if infoFlags.contains(.frameDropped) {
      return .dropped
    }
    guard let sampleBuffer, encodedSampleConsumer.consume(sampleBuffer, logger: logger) else {
      return .writeFailed
    }
    let encodedBytes = CMSampleBufferGetDataBuffer(sampleBuffer).map(CMBlockBufferGetDataLength) ?? 0
    return .written(encodedBytes: encodedBytes)
  }

  func setup(source: VideoFrameSource, edgeInsets: VideoStreamEdgeInsets) throws {
    let encoderSpecification = settings.encoderSpecification

    let sourceWidth = source.width
    let sourceHeight = source.height
    // The composited frame includes the edge insets, so the converter's pool and compression session must
    // accommodate the full output size — the same `VideoOutputDimensions` the composited pool uses.
    let dimensions = VideoOutputDimensions.calculate(
      sourceWidth: sourceWidth, sourceHeight: sourceHeight,
      scaleFactor: scaleFactor, edgeInsets: edgeInsets)
    if let scaleFactor, scaleFactor > 0, scaleFactor < 1 {
      logger.info().log("Applying \(scaleFactor) scale from w=\(sourceWidth)/h=\(sourceHeight) to output w=\(dimensions.width)/h=\(dimensions.height)")
    }

    let pipeline: (converter: PixelBufferConverter, session: VTCompressionSession)
    switch settings.encodedChroma {
    case .subsampled:
      pipeline = try makePipeline(dimensions: dimensions, chroma: .subsampled, encoderSpecification: encoderSpecification)
    case .full:
      // Not every hardware encoder has the 4:4:4 profile; one without it still streams, in 4:2:0.
      do {
        pipeline = try makePipeline(dimensions: dimensions, chroma: .full, encoderSpecification: encoderSpecification)
      } catch {
        logger.log("This encoder cannot encode 4:4:4 (\(error.localizedDescription)); encoding 4:2:0 instead")
        pipeline = try makePipeline(dimensions: dimensions, chroma: .subsampled, encoderSpecification: encoderSpecification)
      }
    }
    self.converter = pipeline.converter
    self.compressionSession = pipeline.session
  }

  /// The converter and the compression session for one chroma, set up and ready to encode. Whatever was made
  /// before a step failed is released again.
  private func makePipeline(
    dimensions: VideoOutputDimensions, chroma: VideoStreamChroma, encoderSpecification: [String: Any]
  ) throws -> (converter: PixelBufferConverter, session: VTCompressionSession) {
    let destinationWidth = dimensions.width
    let destinationHeight = dimensions.height
    let converter = try PixelBufferConverter(
      outputWidth: destinationWidth, outputHeight: destinationHeight, pixelFormat: VideoToolboxEncoderSettings.encoderPixelFormat(for: chroma),
      destinationColor: settings.colorDescription)
    logger.info().log("Created BGRA→YCbCr \(chroma.rawValue) conversion pipeline at w=\(destinationWidth)/h=\(destinationHeight) (GPU via VTPixelTransferSession)")

    // No create-time output callback: each frame is encoded with the block-based
    // `VTCompressionSessionEncodeFrame(...outputHandler:)` overload (see `writeEncodedFrame`),
    // so the session needs neither an `outputCallback` nor a `refcon`.
    var compressionSession: VTCompressionSession?
    func createCompressionSession(_ specification: [String: Any]) -> OSStatus {
      unsafe VTCompressionSessionCreate(
        allocator: nil,
        width: Int32(destinationWidth),
        height: Int32(destinationHeight),
        codecType: videoCodec,
        encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: converter.outputBufferAttributes as CFDictionary,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &compressionSession
      )
    }
    var status = createCompressionSession(encoderSpecification)
    if status != noErr, let fallback = settings.fallbackEncoderSpecification {
      logger.info().log("Hardware compression session refused (\(status)); retrying with a software encoder allowed")
      status = createCompressionSession(fallback)
    }
    guard status == noErr else {
      converter.invalidate()
      throw VideoToolboxFramePusherError.failedToStartCompressionSession(status: status)
    }
    guard let compressionSession else {
      converter.invalidate()
      throw VideoToolboxFramePusherError.compressionSessionNil
    }
    do {
      try configure(compressionSession, dimensions: dimensions, chroma: chroma)
      if chroma == .full, !encodesFullChroma(compressionSession, converter: converter) {
        throw VideoToolboxFramePusherError.fullChromaNotEncoded
      }
    } catch {
      VTCompressionSessionInvalidate(compressionSession)
      converter.invalidate()
      throw error
    }
    return (converter, compressionSession)
  }

  /// Whether the session's output really is 4:4:4. An encoder takes the name of a profile it does not have without
  /// complaint, and that name reads back as set, so the only proof is a frame: one is encoded here and the chroma
  /// format its parameter sets declare is read. The frame is a keyframe whose output is dropped, as in `warm`, which
  /// also spares the first real frame the encoder's start-up.
  private func encodesFullChroma(_ compressionSession: VTCompressionSession, converter: PixelBufferConverter) -> Bool {
    guard let frame = converter.makeOutputBuffer() else {
      return false
    }
    let chromaFormat = OSAllocatedUnfairLock<UInt8?>(initialState: nil)
    let status = VTCompressionSessionEncodeFrame(
      compressionSession,
      imageBuffer: frame,
      presentationTimeStamp: .zero,
      duration: .invalid,
      frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary,
      infoFlagsOut: nil,
      outputHandler: { status, _, sampleBuffer in
        guard status == noErr, let sampleBuffer, let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
          return
        }
        chromaFormat.withLock { $0 = format.hevcChromaFormat }
      }
    )
    guard status == noErr else {
      return false
    }
    VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
    return chromaFormat.withLock { $0 } == CMFormatDescription.hevcChromaFormat444
  }

  private func configure(_ compressionSession: VTCompressionSession, dimensions: VideoOutputDimensions, chroma: VideoStreamChroma) throws {
    let sessionProperties = settings.sessionProperties(outputWidth: dimensions.width, outputHeight: dimensions.height, chroma: chroma)
    if case .compressedVideo = settings.format {
      logger.info().log(
        "Rate control \(settings.rateControl) resolved to \(sessionProperties[kVTCompressionPropertyKey_AverageBitRate as String] ?? 0) bps average for w=\(dimensions.width)/h=\(dimensions.height), chroma \(chroma.rawValue)")
    }

    let propertiesStatus = VTSessionSetProperties(compressionSession, propertyDictionary: sessionProperties as CFDictionary)
    if propertiesStatus != noErr {
      throw VideoToolboxFramePusherError.failedToSetCompressionSessionProperties(status: propertiesStatus)
    }
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
    if prepareStatus != noErr {
      throw VideoToolboxFramePusherError.failedToPrepareCompressionSession(status: prepareStatus)
    }
  }

  func tearDown() throws {
    if let compressionSession {
      VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(compressionSession)
      self.compressionSession = nil
    }
    converter?.invalidate()
    converter = nil
  }

  func writeEncodedFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameNumber: UInt,
    timeAtFirstFrame: TimeInterval,
    frameDuration: TimeInterval,
    forceKeyFrame: Bool
  ) throws {
    _ = try writeEncodedFrame(
      pixelBuffer, frameNumber: frameNumber, timeAtFirstFrame: timeAtFirstFrame, frameDuration: frameDuration, forceKeyFrame: forceKeyFrame,
      sourceIsIntact: { true })
  }

  func writeEncodedFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameNumber: UInt,
    timeAtFirstFrame: TimeInterval,
    frameDuration: TimeInterval,
    forceKeyFrame: Bool,
    sourceIsIntact: () -> Bool
  ) throws -> Bool {
    guard let compressionSession else {
      throw VideoToolboxFramePusherError.missingCompressionSession
    }

    var bufferToWrite = pixelBuffer

    let encodeStart = ContinuousClock.now
    statsRecorder.recordSubmissionStarting(at: encodeStart)

    // BGRA→YCbCr (and scale, since the pool is destination-sized) in one pass; on failure the encoder
    // takes the BGRA frame and converts internally.
    if let converter {
      switch converter.convert(pixelBuffer) {
      case let .converted(convertedBuffer):
        bufferToWrite = convertedBuffer
      case let .transferFailed(status):
        logger.log("VTPixelTransferSession BGRA→YCbCr failed: \(status) — falling back to BGRA input")
      case let .poolExhausted(status):
        logger.log("Failed to get a pixel buffer from the converter's pool: \(status)")
      }
    }

    let time = CMTimeMakeWithSeconds(ProcessInfo.processInfo.systemUptime - timeAtFirstFrame, preferredTimescale: Int32(NSEC_PER_SEC))
    let duration = frameDuration > 0 ? CMTimeMakeWithSeconds(frameDuration, preferredTimescale: Int32(NSEC_PER_SEC)) : CMTime.invalid
    var frameProperties: [String: Any]?
    if frameNumber == 0 || forceKeyFrame {
      frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
    }

    // The conversion above was the last read of the source. One that was written into meanwhile is part one frame and
    // part the next, so it is not encoded; the converted buffer goes back to its pool.
    guard sourceIsIntact() else {
      return false
    }

    // `[weak self]`: the session does not retain the pusher, so a strong capture would be a cycle
    // (pusher → session → handler → pusher). The handler may run on a VideoToolbox thread after this
    // call returns (see the class doc).
    let handler: VTCompressionOutputHandler = { [weak self] encodeStatus, infoFlags, sampleBuffer in
      self?.handleCompressedSampleBuffer(sampleBuffer, encodeStatus: encodeStatus, infoFlags: infoFlags)
    }

    let status = VTCompressionSessionEncodeFrame(
      compressionSession,
      imageBuffer: bufferToWrite,
      presentationTimeStamp: time,
      duration: duration,
      frameProperties: frameProperties as CFDictionary?,
      infoFlagsOut: nil,
      outputHandler: handler
    )

    statsRecorder.recordEncodeSubmission(ContinuousClock.now - encodeStart)

    if status != 0 {
      throw VideoToolboxFramePusherError.failedToCompress(status: status)
    }
    return true
  }

  /// A keyframe, so the session's next frame need not reference it; that frame is forced to a keyframe anyway.
  /// Waits for the output, which is dropped rather than handed to the consumer or counted in the stats.
  func warm(with pixelBuffer: CVPixelBuffer) throws {
    guard let compressionSession else {
      throw VideoToolboxFramePusherError.missingCompressionSession
    }
    var source = pixelBuffer
    if let converter, case let .converted(nv12Buffer) = converter.convert(pixelBuffer) {
      source = nv12Buffer
    }
    let status = VTCompressionSessionEncodeFrame(
      compressionSession,
      imageBuffer: source,
      presentationTimeStamp: .zero,
      duration: .invalid,
      frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary,
      infoFlagsOut: nil,
      outputHandler: { _, _, _ in }
    )
    if status != noErr {
      throw VideoToolboxFramePusherError.failedToCompress(status: status)
    }
    VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
  }

  func completeFrames() {
    if let compressionSession {
      VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
    }
  }

  func recordTornFrame() {
    statsRecorder.recordTornFrame()
  }

  func recordReadRedone() {
    statsRecorder.recordReadRedone()
  }

  func currentStats() -> VideoEncoderStats? {
    statsRecorder.snapshot
  }
}
