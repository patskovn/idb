/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CryptoKit
import Foundation
import Network
import Security

/// The client's copy of the companion's `QUICVideoWire` (CompanionLib/SwiftServer/QUIC); change
/// both together.
enum QUICVideoWire {
  static let frameHeaderLength = 20
  /// Single-stream framing: version 2, a 24-byte header with the payload length (see the companion).
  static let streamVersion: UInt8 = 2
  static let streamFrameHeaderLength = 24
  static let version: UInt8 = 1
  static let keyFrameFlag: UInt8 = 1 << 0
  static let idleTimeoutMilliseconds = 30_000

  enum Control: UInt8 {
    case ack = 1
    case keyFrame = 2
    case ping = 3
  }

  static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
  }

  static func uint64(bigEndian bytes: some Collection<UInt8>) -> UInt64 {
    bytes.reduce(0) { ($0 << 8) | UInt64($1) }
  }
}

/// Receives a companion's QUIC video session and writes its frames, in order, as one Annex-B stream.
///
/// Each frame arrives on a stream of its own, so a frame delayed by a lost packet does not hold up
/// later ones, and the frames can complete out of order. They are written in sequence order. A
/// frame that arrives after a later one was written is dropped, and a gap that persists is skipped
/// at the next keyframe; if none is waiting, the receiver asks for one and writes nothing until it
/// arrives, rather than handing a decoder frames that refer to a frame it never got.
///
/// @unchecked Sendable: all mutable state is confined to `queue`, on which Network.framework
/// calls every handler.
final class QUICVideoReceiver: @unchecked Sendable {
  private struct Frame {
    let sequence: UInt64
    let isKeyFrame: Bool
    /// The companion's uptime when the frame was submitted for encoding.
    let capturedAt: UInt64
    /// This host's uptime when the frame's stream completed.
    let receivedAt: UInt64
    let payload: Data
  }

  private struct Stats {
    var received = 0
    var written = 0
    var keyFrames = 0
    var bytes = 0
    var late = 0
    var skipped = 0
    var keyFrameRequests = 0
  }

  /// How long a gap may stay open before the receiver gives up on it and asks for a keyframe.
  private let gapTimeout: DispatchTimeInterval
  /// The most frames held back waiting for a gap to close or a keyframe to arrive.
  private static let maximumPending = 120

  private let host: String
  private let port: UInt16
  private let alpn: String
  private let certificateSHA256: Data
  private let token: Data
  private let output: FileHandle
  private let frameLog: FrameLog?
  /// Written after every frame so parser-based viewers (ffplay, ffmpeg, mpv) can end the access unit
  /// at once instead of waiting for the next frame's start; nil to write frames bare.
  private let accessUnitDelimiter: Data?
  /// Streams the companion has opened; with per-frame framing the stream limit is raised as they are used.
  private var incomingStreams = 0
  private let statsInterval: Double
  private let maxUDPPayloadSize: Int
  private let onEnd: @Sendable (String) -> Void
  private let queue = DispatchQueue(label: "com.facebook.idb.idb-video")

  // Confined to `queue`.
  private var group: NWConnectionGroup?
  private var control: NWConnection?
  private var timers: [any DispatchSourceTimer] = []
  private var ended = false
  private var waitingForKeyFrame = true
  private var nextSequence: UInt64 = 0
  private var pending: [UInt64: Frame] = [:]
  private var gapCheckScheduled = false
  private var lastKeyFrameRequest: UInt64 = 0
  private var window = Stats()
  private var connectedAt: UInt64 = 0
  private var firstFrameLogged = false

  init(
    host: String, port: UInt16, alpn: String, certificateSHA256: Data, token: Data, output: FileHandle, frameLog: FrameLog?,
    statsInterval: Double,
    maxUDPPayloadSize: Int = 0,
    gapTimeoutMilliseconds: Int = 100,
    accessUnitDelimiter: Data? = nil,
    onEnd: @escaping @Sendable (String) -> Void
  ) {
    self.accessUnitDelimiter = accessUnitDelimiter
    self.maxUDPPayloadSize = maxUDPPayloadSize
    self.gapTimeout = .milliseconds(gapTimeoutMilliseconds)
    self.host = host
    self.port = port
    self.alpn = alpn
    self.certificateSHA256 = certificateSHA256
    self.token = token
    self.output = output
    self.frameLog = frameLog
    self.statsInterval = statsInterval
    self.onEnd = onEnd
  }

  func start() {
    queue.async { self.connect() }
  }

  func stop() {
    queue.async { self.end("stopped") }
  }

  // MARK: Connection

  private func connect() {
    let options = NWProtocolQUIC.Options(alpn: [alpn])
    options.idleTimeout = QUICVideoWire.idleTimeoutMilliseconds
    // Every frame is a stream the companion opens; leave it room to run ahead of the stream
    // credit returned as frames complete.
    options.initialMaxStreamsUnidirectional = 1024
    if maxUDPPayloadSize > 0 {
      options.maxUDPPayloadSize = maxUDPPayloadSize
    }
    let expected = certificateSHA256
    sec_protocol_options_set_verify_block(
      options.securityProtocolOptions,
      { _, trust, complete in
        let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate] ?? []
        guard let leaf = chain.first else {
          complete(false)
          return
        }
        let matches = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == expected
        if !matches {
          log("refusing the QUIC server: its certificate does not match the fingerprint from the companion")
        }
        complete(matches)
      }, queue)

    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: NWParameters(quic: options))
    self.group = group
    group.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.openControlStream(on: group)
      case let .waiting(error):
        // Network.framework passes through `waiting` on the way to `ready`; only a connection
        // still waiting a few seconds later is worth reporting.
        self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
          guard let self, !self.ended, self.control == nil else { return }
          log("still connecting to \(self.host):\(self.port): \(error)")
        }
      case let .failed(error):
        self.end("the QUIC connection failed: \(error)")
      case .cancelled:
        self.end("the QUIC connection closed")
      default:
        break
      }
    }
    group.newConnectionHandler = { [weak self, weak group] stream in
      guard let self else { return }
      self.raiseStreamLimitIfNeeded(group)
      self.receiveFrame(on: stream)
    }
    connectedAt = DispatchTime.now().uptimeNanoseconds
    group.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self, !self.ended, self.control == nil else { return }
      self.end("could not connect over QUIC (UDP) to \(self.host):\(self.port) within 10 s; check that UDP reaches the companion, or use --transport grpc")
    }
  }

  private func openControlStream(on group: NWConnectionGroup) {
    guard control == nil, let stream = NWConnection(from: group) else {
      return
    }
    control = stream
    stream.stateUpdateHandler = { [weak self] state in
      if case let .failed(error) = state {
        self?.end("the control stream failed: \(error)")
      }
    }
    stream.start(queue: queue)
    stream.send(content: token, completion: .contentProcessed { [weak self] error in
      if let error {
        self?.end("failed to send the session token: \(error)")
      }
    })
    log("QUIC connected to \(host):\(port) in \(milliseconds(since: connectedAt)) ms")
    startTimers()
  }

  private func sendControl(_ message: QUICVideoWire.Control, sequence: UInt64? = nil) {
    guard let control else {
      return
    }
    var bytes = [message.rawValue]
    if let sequence {
      bytes += QUICVideoWire.bigEndianBytes(sequence)
    }
    control.send(content: Data(bytes), completion: .idempotent)
  }

  private func end(_ reason: String) {
    guard !ended else {
      return
    }
    ended = true
    for timer in timers {
      timer.cancel()
    }
    timers.removeAll()
    control?.cancel()
    group?.cancel()
    onEnd(reason)
  }

  // MARK: Frames

  /// Network.framework does not grant the companion more unidirectional streams as the finished ones
  /// close, so with one stream per frame it would stop at the initial limit. Raise it ahead of use.
  private func raiseStreamLimitIfNeeded(_ group: NWConnectionGroup?) {
    incomingStreams += 1
    guard incomingStreams % 256 == 0, let group,
      let metadata = group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
    else {
      return
    }
    metadata.localMaxStreamsUnidirectional = incomingStreams + 1024
  }

  private func receiveFrame(on stream: NWConnection) {
    stream.start(queue: queue)
    read(stream, buffer: ReceiveBuffer())
  }

  /// The bytes received on a stream so far. A reference, so appending a chunk does not copy what
  /// arrived before it.
  private final class ReceiveBuffer: @unchecked Sendable {  // used only on the receiver queue
    var data = Data()
  }

  private func read(_ stream: NWConnection, buffer: ReceiveBuffer) {
    stream.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] content, _, isComplete, error in
      guard let self, !self.ended else {
        stream.cancel()
        return
      }
      if let content {
        buffer.data.append(content)
      }
      // Single-stream framing: frames follow one another on this stream until the session ends.
      if buffer.data.first == QUICVideoWire.streamVersion {
        self.consumeStreamFrames(&buffer.data)
        if error != nil || isComplete {
          stream.cancel()
        } else {
          self.read(stream, buffer: buffer)
        }
        return
      }
      if error != nil {
        // The companion cancels the streams of frames a keyframe made stale.
        stream.cancel()
        return
      }
      guard isComplete else {
        self.read(stream, buffer: buffer)
        return
      }
      stream.cancel()
      self.parse(buffer.data)
    }
  }

  /// Takes every complete frame off the front of a single-stream buffer.
  private func consumeStreamFrames(_ buffer: inout Data) {
    let headerLength = QUICVideoWire.streamFrameHeaderLength
    while buffer.count >= headerLength {
      let header = [UInt8](buffer.prefix(headerLength))
      guard header[0] == QUICVideoWire.streamVersion else {
        log("ignoring a malformed frame stream (version \(header[0]))")
        buffer.removeAll()
        return
      }
      let length = Int(QUICVideoWire.uint64(bigEndian: header[4..<8]))
      guard buffer.count >= headerLength + length else {
        return
      }
      let start = buffer.startIndex
      let frame = Frame(
        sequence: QUICVideoWire.uint64(bigEndian: header[8..<16]),
        isKeyFrame: header[1] & QUICVideoWire.keyFrameFlag != 0,
        capturedAt: QUICVideoWire.uint64(bigEndian: header[16..<24]),
        receivedAt: DispatchTime.now().uptimeNanoseconds,
        payload: buffer.subdata(in: (start + headerLength)..<(start + headerLength + length)))
      buffer = Data(buffer.dropFirst(headerLength + length))
      handle(frame, wireBytes: headerLength + length)
    }
  }

  private func parse(_ message: Data) {
    // A stream the companion closed without a frame, as it does when the session ends.
    guard !message.isEmpty else {
      return
    }
    let bytes = [UInt8](message.prefix(QUICVideoWire.frameHeaderLength))
    guard bytes.count == QUICVideoWire.frameHeaderLength, bytes[0] == QUICVideoWire.version else {
      log("ignoring a malformed frame of \(message.count) bytes")
      return
    }
    let frame = Frame(
      sequence: QUICVideoWire.uint64(bigEndian: bytes[4..<12]),
      isKeyFrame: bytes[1] & QUICVideoWire.keyFrameFlag != 0,
      capturedAt: QUICVideoWire.uint64(bigEndian: bytes[12..<20]),
      receivedAt: DispatchTime.now().uptimeNanoseconds,
      payload: message.dropFirst(QUICVideoWire.frameHeaderLength))
    handle(frame, wireBytes: message.count)
  }

  private func handle(_ frame: Frame, wireBytes: Int) {
    sendControl(.ack, sequence: frame.sequence)
    window.received += 1
    window.bytes += wireBytes
    if frame.isKeyFrame {
      window.keyFrames += 1
    }
    if !firstFrameLogged {
      firstFrameLogged = true
      log("first frame \(frame.sequence)\(frame.isKeyFrame ? " (keyframe)" : "") after \(milliseconds(since: connectedAt)) ms")
    }
    accept(frame)
  }

  private func accept(_ frame: Frame) {
    if !waitingForKeyFrame && frame.sequence < nextSequence {
      window.late += 1
      return
    }
    pending[frame.sequence] = frame
    if waitingForKeyFrame {
      if pending[nextSequence] != nil {
        // The missing frame arrived after all: carry on from it.
        waitingForKeyFrame = false
      } else if let keyFrame = latestPendingKeyFrame() {
        resume(at: keyFrame)
      } else {
        trimPending()
        return
      }
    }
    drain()
    guard !pending.isEmpty else {
      return
    }
    // A gap: a later keyframe makes the missing frames unnecessary.
    if let keyFrame = latestPendingKeyFrame() {
      window.skipped += Int(keyFrame - nextSequence)
      resume(at: keyFrame)
      drain()
    }
    if !pending.isEmpty {
      scheduleGapCheck()
    }
  }

  private func latestPendingKeyFrame() -> UInt64? {
    pending.values.filter { $0.isKeyFrame && $0.sequence >= nextSequence }.map(\.sequence).max()
  }

  /// Continues the output from the keyframe at `sequence`, dropping everything before it.
  private func resume(at sequence: UInt64) {
    pending = pending.filter { $0.key >= sequence }
    nextSequence = sequence
    waitingForKeyFrame = false
  }

  private func drain() {
    while let frame = pending.removeValue(forKey: nextSequence) {
      write(frame)
      nextSequence += 1
    }
  }

  private func trimPending() {
    while pending.count > Self.maximumPending, let oldest = pending.keys.min() {
      pending.removeValue(forKey: oldest)
    }
  }

  private func scheduleGapCheck() {
    guard !gapCheckScheduled else {
      return
    }
    gapCheckScheduled = true
    let gapStart = nextSequence
    queue.asyncAfter(deadline: .now() + gapTimeout) { [weak self] in
      guard let self, !self.ended else { return }
      self.gapCheckScheduled = false
      if self.waitingForKeyFrame {
        // Ask again until a keyframe arrives: the first request or its keyframe can be lost.
        self.requestKeyFrame()
        self.scheduleGapCheck()
        return
      }
      guard self.nextSequence == gapStart, !self.pending.isEmpty else {
        if !self.pending.isEmpty {
          self.scheduleGapCheck()
        }
        return
      }
      self.window.skipped += 1
      self.waitingForKeyFrame = true
      self.requestKeyFrame()
      self.trimPending()
    }
  }

  private func requestKeyFrame() {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now - lastKeyFrameRequest > 500_000_000 else {
      return
    }
    lastKeyFrameRequest = now
    window.keyFrameRequests += 1
    sendControl(.keyFrame)
  }

  private func write(_ frame: Frame) {
    do {
      if let accessUnitDelimiter {
        try output.write(contentsOf: frame.payload + accessUnitDelimiter)
      } else {
        try output.write(contentsOf: frame.payload)
      }
      frameLog?.record(
        bytes: frame.payload.count, isKeyFrame: frame.isKeyFrame, sequence: frame.sequence, capturedAt: frame.capturedAt,
        receivedAt: frame.receivedAt)
      window.written += 1
    } catch {
      end("cannot write the video: \(error)")
    }
  }

  // MARK: Timers

  private func startTimers() {
    timers.append(repeating(every: 5) { [weak self] in
      self?.sendControl(.ping)
    })
    // The companion sends a keyframe when the client connects; ask again if none has come.
    queue.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, !self.ended, self.waitingForKeyFrame else { return }
      self.requestKeyFrame()
    }
    if statsInterval > 0 {
      let interval = statsInterval
      timers.append(repeating(every: interval) { [weak self] in
        guard let self else { return }
        let stats = self.window
        self.window = Stats()
        log(
          String(
            format: "%.1f fps written, %.0f kbit/s, %d received (%d key), %d late, %d skipped, %d keyframe requests, %d pending%@",
            Double(stats.written) / interval, Double(stats.bytes) * 8 / interval / 1000, stats.received, stats.keyFrames,
            stats.late, stats.skipped, stats.keyFrameRequests, self.pending.count, self.waitingForKeyFrame ? ", waiting for a keyframe" : ""))
      })
    }
  }

  private func repeating(every seconds: Double, _ handler: @escaping @Sendable () -> Void) -> any DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + seconds, repeating: seconds)
    timer.setEventHandler(handler: handler)
    timer.resume()
    return timer
  }

  private func milliseconds(since start: UInt64) -> UInt64 {
    (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
}
