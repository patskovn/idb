/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import ArgumentParser
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import IDBGRPCSwift

/// Streams a target's screen from an idb companion over QUIC and writes the Annex-B video to a
/// file or stdout, for example into `ffplay -f hevc -`.
///
/// The session is started over the companion's gRPC port; the companion answers with a QUIC
/// endpoint, the fingerprint of the certificate it will present and a token. The frames then
/// arrive over QUIC, and the gRPC call stays open to stop the session.
@main
struct IDBVideo: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "idb-video",
    abstract: "Stream a simulator's screen from idb_companion over QUIC.")

  enum Codec: String, ExpressibleByArgument {
    case hevc, h264
  }

  enum Transport: String, ExpressibleByArgument {
    case quic, grpc
  }

  @Option(help: "The companion's gRPC address: host:port, or unix:<socket path>.")
  var companion = "localhost:10882"

  @Option(help: "The host to reach the QUIC endpoint on. Defaults to the companion's host.")
  var quicHost: String?

  @Option(help: "The UDP port for the companion to listen on. 0 lets it pick.")
  var quicPort: UInt32 = 0

  @Option(help: "Connect QUIC to this host:port instead of the endpoint the companion offers, e.g. a network emulator in front of it.")
  var quicConnect: String?

  @Option(help: "Ask the companion to send QUIC datagrams of at most this many bytes (QUIC max_udp_payload_size). 0 keeps Network.framework's default.")
  var quicMaxUDPPayload: Int = 0

  @Option(help: "How long a gap in the frame sequence may stay open before asking for a keyframe, in milliseconds.")
  var gapTimeoutMs: Int = 100

  @Flag(help: "Write frames without an access unit delimiter after each one. By default one is appended so ffplay, ffmpeg and mpv show each frame as soon as it arrives instead of when the next one starts.")
  var noAud = false

  @Option(help: "hevc or h264.")
  var codec: Codec = .hevc

  @Option(help: "A fixed frame rate. Without it, frames are sent when the screen changes.")
  var fps: UInt64?

  @Option(help: "Scale the screen by this factor (0-1) before encoding.")
  var scale: Double?

  @Option(help: "Average bitrate in bits per second.")
  var bitrate: Double?

  @Option(help: "Seconds between periodic keyframes.")
  var keyFrameRate: Double?

  @Option(name: .shortAndLong, help: "Where to write the Annex-B stream: a file path, or - for stdout.")
  var output = "-"

  @Option(help: "Stop after this many seconds.")
  var duration: Double?

  @Option(help: "Seconds between statistics lines on stderr. 0 turns them off.")
  var statsInterval: Double = 2

  @Option(help: "quic, or grpc to receive the frames on the gRPC call itself (for comparison).")
  var transport: Transport = .quic

  @Option(help: "Append a line per frame written: uptime in nanoseconds, bytes, and 1 for a keyframe.")
  var frameLog: String?

  mutating func run() async throws {
    signal(SIGPIPE, SIG_IGN)
    let (target, defaultQUICHost) = try parseCompanion()
    guard let quicHost = quicHost ?? defaultQUICHost else {
      throw ValidationError("--quic-host is required with a unix socket companion")
    }
    let output = try openOutput()
    let frameLog = try frameLog.map(FrameLog.init(path:))
    let quicConnectOverride = try quicConnect.map(parseHostPort)
    let maxUDPPayload = quicMaxUDPPayload
    let gapTimeout = gapTimeoutMs
    // HEVC AUD (type 35, pic_type 2) / H.264 AUD (type 9, primary_pic_type 7).
    let accessUnitDelimiter: Data? = noAud ? nil : Data(codec == .hevc ? [0, 0, 0, 1, 0x46, 0x01, 0x50] : [0, 0, 0, 1, 0x09, 0xF0])
    let codec = codec
    let start = Idb_VideoStreamRequest.with {
      $0.start = .with {
        $0.transport = transport == .quic ? .quic : .grpc
        $0.quicPort = quicPort
        $0.format = codec == .hevc ? .hevc : .h264
        $0.fps = fps ?? 0
        $0.scaleFactor = scale ?? 0
        $0.avgBitrate = bitrate ?? 0
        $0.keyFrameRate = keyFrameRate ?? 0
      }
    }

    let (controlMessages, control) = AsyncStream<Idb_VideoStreamRequest>.makeStream()
    control.yield(start)
    let stop: @Sendable (String) -> Void = { reason in
      log("stopping: \(reason)")
      control.yield(.with { $0.stop = .init() })
      control.finish()
    }
    let signals = installSignalHandlers { stop("interrupted") }
    defer { signals.forEach { $0.cancel() } }
    if let duration {
      Task {
        try? await Task.sleep(for: .seconds(duration))
        stop("--duration elapsed")
      }
    }

    let statsInterval = statsInterval
    let transport = try HTTP2ClientTransport.Posix(target: target, transportSecurity: .plaintext)
    try await withGRPCClient(transport: transport) { client in
      let service = Idb_CompanionService.Client(wrapping: client)
      try await service.video_stream(
        request: StreamingClientRequest { writer in
          for await message in controlMessages {
            try await writer.write(message)
          }
        }
      ) { response in
        var receiver: QUICVideoReceiver?
        defer { receiver?.stop() }
        var payloadStats = PayloadStats(interval: statsInterval)
        var payloadSequence: UInt64 = 0
        for try await message in response.messages {
          switch message.output {
          case let .quicSession(session):
            guard receiver == nil else {
              continue
            }
            guard var port = UInt16(exactly: session.port) else {
              throw ValidationError("The companion offered an invalid QUIC port \(session.port)")
            }
            var quicHost = quicHost
            if let override = quicConnectOverride {
              (quicHost, port) = override
              log("connecting QUIC through \(quicHost):\(port) instead of the offered port \(session.port)")
            }
            log("QUIC session on \(quicHost):\(port), certificate sha256 \(session.certificateSha256.map { String(format: "%02x", $0) }.joined())")
            let newReceiver = QUICVideoReceiver(
              host: quicHost, port: port, alpn: session.alpn, certificateSHA256: session.certificateSha256, token: session.token,
              output: output, frameLog: frameLog, statsInterval: statsInterval, maxUDPPayloadSize: maxUDPPayload,
              gapTimeoutMilliseconds: gapTimeout, accessUnitDelimiter: accessUnitDelimiter, onEnd: stop)
            newReceiver.start()
            receiver = newReceiver
          case let .logOutput(data):
            FileHandle.standardError.write(data)
          case let .payload(payload):
            // The gRPC transport: each payload is one Annex-B access unit.
            guard case let .data(frame) = payload.source else {
              continue
            }
            let isKeyFrame = AnnexBKeyFrameDetector.isKeyFrame(frame, codec: codec)
            do {
              try output.write(contentsOf: accessUnitDelimiter.map { frame + $0 } ?? frame)
            } catch {
              stop("cannot write the video: \(error)")
              continue
            }
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            frameLog?.record(bytes: frame.count, isKeyFrame: isKeyFrame, sequence: payloadSequence, capturedAt: 0, receivedAt: receivedAt)
            payloadSequence += 1
            payloadStats.record(bytes: frame.count, isKeyFrame: isKeyFrame)
          case nil:
            break
          }
        }
      }
    }
  }

  private func parseCompanion() throws -> (any ResolvableTarget, String?) {
    if companion.hasPrefix("unix:") {
      return (.unixDomainSocket(path: String(companion.dropFirst("unix:".count))), nil)
    }
    guard let colon = companion.lastIndex(of: ":"), let port = Int(companion[companion.index(after: colon)...]) else {
      throw ValidationError("--companion must be host:port or unix:<path>, not \(companion)")
    }
    var host = String(companion[..<colon])
    if host.hasPrefix("["), host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    return (.dns(host: host, port: port), host)
  }

  private func parseHostPort(_ value: String) throws -> (String, UInt16) {
    guard let colon = value.lastIndex(of: ":"), let port = UInt16(value[value.index(after: colon)...]) else {
      throw ValidationError("expected host:port, not \(value)")
    }
    var host = String(value[..<colon])
    if host.hasPrefix("["), host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    return (host, port)
  }

  private func openOutput() throws -> FileHandle {
    if output == "-" {
      return .standardOutput
    }
    guard FileManager.default.createFile(atPath: output, contents: nil) else {
      throw ValidationError("Cannot create \(output)")
    }
    return try FileHandle(forWritingTo: URL(fileURLWithPath: output))
  }

  private func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) -> [any DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler(handler: handler)
      source.resume()
      return source
    }
  }
}

func log(_ message: String) {
  FileHandle.standardError.write(Data("idb-video: \(message)\n".utf8))
}
