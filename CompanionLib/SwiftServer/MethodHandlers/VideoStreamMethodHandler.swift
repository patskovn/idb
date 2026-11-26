/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import FBVideoCore
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import SwiftProtobuf
import os

struct VideoStreamMethodHandler {

  let target: CompanionTarget
  let targetLogger: any ControlCoreLogger
  let commandExecutor: IDBCommandExecutor

  func handle(requestStream: RequestStreamReader<Idb_VideoStreamRequest>, responseStream: RPCWriter<Idb_VideoStreamResponse>, context: ServerContext) async throws {
    guard case let .start(start) = try await requestStream.requiredNext().control
    else { throw RPCError(code: .failedPrecondition, message: "Expected start control") }

    if start.transport == .quic {
      try await handleQUIC(start: start, requestStream: requestStream, responseStream: responseStream)
      return
    }

    let videoStream = try await startVideoStream(request: start, responseStream: responseStream)

    let observeClientCancelStreaming = observeControl(requestStream: requestStream, videoStream: videoStream)

    let observeVideoStreamStop = Task<Void, any Error> {
      try await videoStream.awaitCompletion()
    }

    // Stop the stream however the call ends. A client that goes away without sending `stop` (a
    // cancelled call, a dropped connection) makes the observer throw; rethrowing before stopping
    // would leave the encoder running for the rest of the companion's life.
    let winner = await Task.select(observeClientCancelStreaming, observeVideoStreamStop)
    observeClientCancelStreaming.cancel()
    observeVideoStreamStop.cancel()
    try await videoStream.stopStreaming()
    targetLogger.log("The video stream is terminated")
    try await winner.value
  }

  private func startVideoStream(request start: Idb_VideoStreamRequest.Start, responseStream: RPCWriter<Idb_VideoStreamResponse>) async throws -> any VideoStreamOperation {
    let consumer: any DataConsumer

    if start.filePath.isEmpty {
      let responseWriter = FIFOStreamWriter(stream: responseStream)

      let forwarding = ResponseForwardingConsumer { data in
        try responseWriter.send(Idb_VideoStreamResponse.with { $0.payload.data = data })
      }
      if let trace = VideoFrameTrace.shared {
        consumer = TracingFrameConsumer(wrapping: forwarding, trace: trace, transport: "grpc")
      } else {
        consumer = forwarding
      }
    } else {
      consumer = try FileWriter.syncWriter(forFilePath: start.filePath)
    }

    return try await target.videoStream.create(
      configuration: VideoStreamRequestTranslation.configuration(from: start), to: consumer)
  }

  /// Reads the requests after `start` until the client sends `stop`.
  private func observeControl(requestStream: RequestStreamReader<Idb_VideoStreamRequest>, videoStream: any VideoStreamOperation) -> Task<Void, any Error> {
    Task<Void, any Error> {
      for try await request in requestStream {
        switch request.control {
        case .start:
          throw RPCError(code: .failedPrecondition, message: "Video streaming already started")
        case .stop:
          return
        case .keyFrame:
          videoStream.requestKeyFrame()
        case .none:
          throw RPCError(code: .invalidArgument, message: "Client should not close request stream explicitly, send `stop` frame first")
        }
      }
    }
  }

  // MARK: QUIC transport

  /// Streams over a QUIC session of its own. The first response says where to connect; the call
  /// then stays open as the session's control channel until the client stops it, the client's
  /// QUIC connection ends, or the video stream does.
  private func handleQUIC(start: Idb_VideoStreamRequest.Start, requestStream: RequestStreamReader<Idb_VideoStreamRequest>, responseStream: RPCWriter<Idb_VideoStreamResponse>) async throws {
    guard start.filePath.isEmpty else {
      throw RPCError(code: .invalidArgument, message: "The QUIC transport streams to the client; it cannot write to file_path")
    }
    // The client asks for a keyframe when it connects and whenever it has lost a frame, and QUIC delivers the
    // rest, so a periodic one is only a burst of bytes that every frame after it pays for.
    let configuration = VideoStreamRequestTranslation.configuration(from: start, periodicKeyFrames: false)
    guard case let .compressedVideo(codec, _) = configuration.format else {
      throw RPCError(code: .invalidArgument, message: "The QUIC transport carries H.264 or HEVC, not \(configuration.format)")
    }

    // The session can ask for a keyframe or a bitrate before the video stream exists, so requests go
    // through a relay the stream is attached to once created.
    let keyFrameRelay = StreamControlRelay()
    let session: QUICVideoSession
    do {
      session = try await QUICVideoSession.start(
        port: start.quicPort,
        codec: codec,
        logger: targetLogger,
        onClientReady: { keyFrameRelay.request() },
        onKeyFrameRequest: { keyFrameRelay.request() },
        onBitRateChange: { keyFrameRelay.setAverageBitRate($0) })
    } catch {
      throw RPCError(code: .unavailable, message: "Failed to start the QUIC video session: \(error)")
    }

    let videoStream: any VideoStreamOperation
    do {
      try await responseStream.write(
        Idb_VideoStreamResponse.with {
          $0.quicSession = .with {
            $0.port = UInt32(session.port)
            $0.certificateSha256 = session.certificateSHA256
            $0.token = session.token
            $0.alpn = QUICVideoWire.alpn
          }
        })
      targetLogger.log("QUIC video session listening on UDP port \(session.port) for \(configuration)")
      videoStream = try await target.videoStream.create(configuration: configuration, to: session)
    } catch {
      session.close()
      keyFrameRelay.detach()
      throw error
    }
    keyFrameRelay.attach(videoStream)

    let observeControl = observeControl(requestStream: requestStream, videoStream: videoStream)
    let observeVideoStreamStop = Task<Void, any Error> {
      try await videoStream.awaitCompletion()
    }
    let observeSessionEnd = Task<Void, any Error> {
      await session.waitUntilEnded()
    }

    let winner = await Task.select(observeControl, observeVideoStreamStop, observeSessionEnd)
    for task in [observeControl, observeVideoStreamStop, observeSessionEnd] {
      task.cancel()
    }
    session.close()
    // The session's callbacks hold the relay, the relay holds the stream, and the stream's encoder
    // holds the session as its consumer: detaching breaks that cycle so all of it is freed.
    defer { keyFrameRelay.detach() }
    try await videoStream.stopStreaming()
    targetLogger.log("The QUIC video stream is terminated")
    try await winner.value
  }
}

/// Forwards keyframe requests and bitrate changes to a video stream attached after they may start
/// arriving. What was asked for before then is passed on when the stream is attached.
private final class StreamControlRelay: Sendable {
  private struct State: Sendable {
    var videoStream: (any VideoStreamOperation)?
    var detached = false
    var requestedBeforeAttach = false
    var bitRateBeforeAttach: Int?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Drops the stream once the session is over; later requests do nothing.
  func detach() {
    state.withLock { state in
      state.videoStream = nil
      state.detached = true
    }
  }

  func attach(_ stream: any VideoStreamOperation) {
    let (requested, bitRate) = state.withLock { state -> (Bool, Int?) in
      guard !state.detached else {
        return (false, nil)
      }
      state.videoStream = stream
      defer {
        state.requestedBeforeAttach = false
        state.bitRateBeforeAttach = nil
      }
      return (state.requestedBeforeAttach, state.bitRateBeforeAttach)
    }
    if let bitRate {
      stream.setAverageBitRate(bitRate)
    }
    if requested {
      stream.requestKeyFrame()
    }
  }

  func setAverageBitRate(_ bitsPerSecond: Int) {
    let stream = state.withLock { state -> (any VideoStreamOperation)? in
      if state.videoStream == nil {
        state.bitRateBeforeAttach = bitsPerSecond
      }
      return state.videoStream
    }
    stream?.setAverageBitRate(bitsPerSecond)
  }

  func request() {
    let stream = state.withLock { state -> (any VideoStreamOperation)? in
      if state.videoStream == nil {
        state.requestedBeforeAttach = true
      }
      return state.videoStream
    }
    stream?.requestKeyFrame()
  }
}
