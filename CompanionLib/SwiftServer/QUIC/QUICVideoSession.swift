/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBVideoCore
import Foundation
import Network
import os

/// The bytes of a QUIC video session. The `idb-video` client (`Tools/IDBVideo`) keeps its own copy;
/// change both together.
///
/// - The client opens one bidirectional *control stream* and writes the session token on it. Until
///   it has, the companion sends nothing.
/// - Each encoded frame then arrives on a unidirectional stream of its own, opened by the companion:
///   a 20-byte header followed by the frame's Annex-B bytes, ended by the stream's FIN.
///   Header: version (UInt8), flags (UInt8, bit 0 = keyframe), reserved (UInt16), sequence (UInt64),
///   capture time (UInt64): the companion host's uptime in nanoseconds
///   (`DispatchTime.now().uptimeNanoseconds`) when the frame was submitted for encoding. Integers are
///   big-endian. A client on the same host can subtract it from its own uptime to get the latency.
/// - The client writes control messages on the control stream: `ack` + sequence when it has
///   received a frame, `keyFrame` to ask for one, `ping` to keep an idle session open.
enum QUICVideoWire {
  static let alpn = "idb-video/1"
  static let version: UInt8 = 1
  static let frameHeaderLength = 20
  static let keyFrameFlag: UInt8 = 1 << 0
  /// QUIC closes a connection after this long without packets; the client pings well inside it.
  static let idleTimeoutMilliseconds = 30_000

  enum Control: UInt8 {
    case ack = 1
    case keyFrame = 2
    case ping = 3

    var payloadLength: Int {
      switch self {
      case .ack: return 8
      case .keyFrame, .ping: return 0
      }
    }
  }

  static func frameHeader(sequence: UInt64, isKeyFrame: Bool, capturedAtUptimeNanos: UInt64) -> Data {
    var header = Data(capacity: frameHeaderLength)
    header.append(version)
    header.append(isKeyFrame ? keyFrameFlag : 0)
    header.append(contentsOf: [0, 0])
    header.append(contentsOf: bigEndianBytes(sequence))
    header.append(contentsOf: bigEndianBytes(capturedAtUptimeNanos))
    return header
  }

  /// Single-stream framing (`IDB_QUIC_FRAMING=stream`): every frame goes on one long-lived
  /// unidirectional stream, each preceded by a 24-byte header: version 2 (UInt8), flags (UInt8),
  /// reserved (UInt16), payload length (UInt32), sequence (UInt64), capture time (UInt64).
  static let streamVersion: UInt8 = 2
  static let streamFrameHeaderLength = 24

  static func streamFrameHeader(length: Int, sequence: UInt64, isKeyFrame: Bool, capturedAtUptimeNanos: UInt64) -> Data {
    var header = Data(capacity: streamFrameHeaderLength)
    header.append(streamVersion)
    header.append(isKeyFrame ? keyFrameFlag : 0)
    header.append(contentsOf: [0, 0])
    header.append(contentsOf: bigEndianBytes(UInt64(length)).suffix(4))
    header.append(contentsOf: bigEndianBytes(sequence))
    header.append(contentsOf: bigEndianBytes(capturedAtUptimeNanos))
    return header
  }

  static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
  }

  static func uint64(bigEndian bytes: some Collection<UInt8>) -> UInt64 {
    bytes.reduce(0) { ($0 << 8) | UInt64($1) }
  }
}

/// Whether an Annex-B access unit starts a group of pictures: it carries parameter sets or an
/// IDR/IRAP slice. Stops at the first other slice, so a frame's payload is not scanned.
enum AnnexBKeyFrameDetector {
  static func isKeyFrame(_ data: Data, codec: VideoStreamCodec) -> Bool {
    var index = data.startIndex
    let end = data.endIndex
    while index + 3 < end {
      guard data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 else {
        index += 1
        continue
      }
      let header = data[index + 3]
      switch codec {
      case .h264:
        let type = header & 0x1f
        if type == 5 || type == 7 {
          return true
        }
        if (1...4).contains(type) {
          return false
        }
      case .hevc:
        let type = (header >> 1) & 0x3f
        if (16...21).contains(type) || type == 32 || type == 33 {
          return true
        }
        if type < 32 {
          return false
        }
      }
      index += 3
    }
    return false
  }
}

enum QUICVideoSessionError: Error, LocalizedError {
  case invalidPort(UInt32)
  case listenerFailed(String)

  var errorDescription: String? {
    switch self {
    case let .invalidPort(port):
      return "\(port) is not a UDP port"
    case let .listenerFailed(reason):
      return "The QUIC listener failed: \(reason)"
    }
  }
}

/// When the session asks the video stream to drop frames before encoding them.
///
/// Configurable for experiments with `IDB_QUIC_BACKPRESSURE`, e.g. `frames=8`, `age=150` or
/// `frames=8,age=150` (milliseconds): drop while more than `frames` frames are unacknowledged, or
/// while the oldest frame on the wire has waited longer than `age` for its acknowledgement. The
/// default, `frames=2`, is the stream's own threshold: more than two unacknowledged frames.
struct QUICBackpressurePolicy: Equatable, CustomStringConvertible {
  var maxFrames: Int?
  var maxAgeNanos: UInt64?

  static let `default` = QUICBackpressurePolicy(maxFrames: 2, maxAgeNanos: nil)

  static func parse(_ value: String?) -> QUICBackpressurePolicy {
    guard let value, !value.isEmpty else {
      return .default
    }
    var policy = QUICBackpressurePolicy(maxFrames: nil, maxAgeNanos: nil)
    for part in value.split(separator: ",") {
      let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard pair.count == 2, let number = Double(pair[1]) else {
        continue
      }
      switch pair[0] {
      case "frames":
        policy.maxFrames = Int(number)
      case "age":
        policy.maxAgeNanos = UInt64(number * 1_000_000)
      default:
        continue
      }
    }
    return policy.maxFrames == nil && policy.maxAgeNanos == nil ? .default : policy
  }

  /// The number to report as queued: the stream drops a frame before encoding it when this is
  /// more than two.
  func reportedQueue(outstanding: Int, oldestSentAt: UInt64?, now: UInt64) -> Int {
    if self == .default {
      return outstanding
    }
    var drop = false
    if let maxFrames, outstanding > maxFrames {
      drop = true
    }
    if let maxAgeNanos, let oldestSentAt, now > oldestSentAt, now - oldestSentAt > maxAgeNanos {
      drop = true
    }
    return drop ? max(outstanding, 3) : min(outstanding, 2)
  }

  var description: String {
    [maxFrames.map { "frames=\($0)" }, maxAgeNanos.map { "age=\($0 / 1_000_000)ms" }].compactMap { $0 }.joined(separator: ",")
  }
}

/// Delay-based rate adaptation for experiments, enabled with `IDB_QUIC_ADAPTIVE_BITRATE`, e.g.
/// `start=3000000,min=400000,max=8000000` (bits per second; optional `high=50,low=20` queueing-delay
/// thresholds in ms, `down=0.7` multiplicative decrease, `up=0.05` relative increase per interval,
/// `interval=250` ms). Each interval the session takes the median of (acknowledgement round trip -
/// minimum round trip over the last 10 s) as the queueing delay: above `high`, or frames dropped
/// before encoding while above `low`, multiplies the target by `down`; below `low` with no drops
/// raises it by `up`. The target goes to the encoder through `onBitRateChange`.
struct QUICAdaptiveBitRate: Equatable {
  var start = 3_000_000
  var minimum = 400_000
  var maximum = 8_000_000
  var highQueueNanos: UInt64 = 50_000_000
  var lowQueueNanos: UInt64 = 20_000_000
  var decrease = 0.7
  var increase = 0.05
  var intervalMilliseconds = 250

  static func parse(_ value: String?) -> QUICAdaptiveBitRate? {
    guard let value, !value.isEmpty, value != "0" else {
      return nil
    }
    var config = QUICAdaptiveBitRate()
    for part in value.split(separator: ",") {
      let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard pair.count == 2, let number = Double(pair[1]) else {
        continue
      }
      switch pair[0] {
      case "start": config.start = Int(number)
      case "min": config.minimum = Int(number)
      case "max": config.maximum = Int(number)
      case "high": config.highQueueNanos = UInt64(number * 1_000_000)
      case "low": config.lowQueueNanos = UInt64(number * 1_000_000)
      case "down": config.decrease = number
      case "up": config.increase = number
      case "interval": config.intervalMilliseconds = Int(number)
      default: continue
      }
    }
    return config
  }

  /// The next target, or nil to keep the current one (no samples this interval).
  func next(current: Int, queueDelays: [UInt64], drops: Int) -> Int? {
    guard !queueDelays.isEmpty else {
      return drops > 0 ? max(minimum, Int(Double(current) * decrease)) : nil
    }
    let sorted = queueDelays.sorted()
    let median = sorted[sorted.count / 2]
    if median > highQueueNanos || (drops > 0 && median > lowQueueNanos) {
      return max(minimum, Int(Double(current) * decrease))
    }
    if median < lowQueueNanos && drops == 0 {
      return min(maximum, current + max(50_000, Int(Double(current) * increase)))
    }
    return current
  }
}

/// Sends a video stream's encoded frames to one client over QUIC.
///
/// A `DataConsumer`: the video stream hands it one Annex-B access unit per `consumeData`. Frames
/// sent but not yet acknowledged by the client are reported as `queued`, so the stream drops
/// frames before encoding them once the network falls behind, instead of letting latency build
/// up in buffers. A keyframe makes every frame still in flight useless, so sending one cancels
/// their streams.
///
/// @unchecked Sendable: every mutable property is confined to `queue`, on which Network.framework
/// also calls every handler; `outstanding` is read from the encoder's thread and is locked.
final class QUICVideoSession: TimedFrameConsumer, @unchecked Sendable {

  private(set) var port: UInt16 = 0
  let certificateSHA256: Data
  let token: Data

  private let codec: VideoStreamCodec
  private let logger: any ControlCoreLogger
  private let queue = DispatchQueue(label: "com.facebook.idb.quic-video")
  private let listener: NWListener
  private let frameStreamOptions: NWProtocolQUIC.Options
  private let onClientReady: @Sendable () -> Void
  private let onKeyFrameRequest: @Sendable () -> Void
  private let endedStream: AsyncStream<Void>
  private let endedContinuation: AsyncStream<Void>.Continuation
  /// Frames handed over by `consumeFrame` and not yet acknowledged, dropped or cancelled, and when
  /// each of those already on the wire was sent. Read from the encoder's thread.
  private struct Outstanding {
    var count = 0
    var sentAt: [UInt64: UInt64] = [:]
    /// How often the stream was told to drop a frame since the rate controller last looked.
    var dropSignals = 0
  }

  private let outstanding = OSAllocatedUnfairLock(initialState: Outstanding())
  private let backpressure = QUICBackpressurePolicy.parse(ProcessInfo.processInfo.environment["IDB_QUIC_BACKPRESSURE"])
  private let adaptiveBitRate = QUICAdaptiveBitRate.parse(ProcessInfo.processInfo.environment["IDB_QUIC_ADAPTIVE_BITRATE"])
  private let onBitRateChange: @Sendable (Int) -> Void
  /// `IDB_QUIC_KEYFRAME_MIN_INTERVAL_MS=N` ignores a client's keyframe request while a keyframe is
  /// still unacknowledged or one was sent less than N ms ago (0, the default, honours every request).
  private let keyFrameMinIntervalNanos = UInt64(ProcessInfo.processInfo.environment["IDB_QUIC_KEYFRAME_MIN_INTERVAL_MS"].flatMap(Double.init) ?? 0) * 1_000_000
  /// `IDB_QUIC_CANCEL_ON_KEYFRAME=0` keeps in-flight frames when a keyframe is sent.
  private let cancelOnKeyFrame = ProcessInfo.processInfo.environment["IDB_QUIC_CANCEL_ON_KEYFRAME"] != "0"
  private let trace = VideoFrameTrace.shared
  private lazy var traceStreamID = trace?.makeStreamID() ?? 0

  // Confined to `queue`.
  private var listenerReady: CheckedContinuation<Void, any Error>?
  private var connecting: [ObjectIdentifier: NWConnectionGroup] = [:]
  private var client: NWConnectionGroup?
  private var controlStream: NWConnection?
  private var controlBuffer = Data()
  /// Frames on the wire; `stream` is the frame's own stream with per-frame framing, nil with
  /// single-stream framing.
  private var inFlight: [UInt64: (stream: NWConnection?, sentAt: UInt64)] = [:]
  /// The long-lived stream that carries every frame with single-stream framing.
  private var frameStream: NWConnection?
  /// `IDB_QUIC_FRAMING=stream` sends every frame on one long-lived stream instead of one stream per frame.
  private let streamFraming = ProcessInfo.processInfo.environment["IDB_QUIC_FRAMING"] == "stream"
  private var nextSequence: UInt64 = 0
  private var lastKeyFrameSentAt: UInt64 = 0
  private var keyFrameInFlight: UInt64?
  private var ignoredKeyFrameRequests = 0
  // Rate adaptation, confined to `queue`.
  private var roundTrips: [(at: UInt64, nanos: UInt64)] = []
  private var intervalRoundTrips: [UInt64] = []
  private var bitRateTarget = 0
  private var bitRateChanges = 0
  private var bitRateTimer: DispatchSourceTimer?
  private var ended = false
  private var statsTimer: DispatchSourceTimer?
  private var window = Stats()
  private var total = Stats()

  private struct Stats {
    var frames = 0
    var keyFrames = 0
    var bytes = 0
    var acknowledged = 0
    var cancelled = 0
    var roundTripNanos: UInt64 = 0
    var roundTripMaxNanos: UInt64 = 0
  }

  /// Listens on `port` (0 for any) and returns once the listener is ready.
  static func start(
    port: UInt32,
    codec: VideoStreamCodec,
    logger: any ControlCoreLogger,
    onClientReady: @escaping @Sendable () -> Void,
    onKeyFrameRequest: @escaping @Sendable () -> Void,
    onBitRateChange: @escaping @Sendable (Int) -> Void = { _ in }
  ) async throws -> QUICVideoSession {
    guard port <= UInt32(UInt16.max) else {
      throw QUICVideoSessionError.invalidPort(port)
    }
    let identity = try QUICSessionIdentity.make()
    let session = try QUICVideoSession(
      port: UInt16(port), identity: identity, codec: codec, logger: logger, onClientReady: onClientReady, onKeyFrameRequest: onKeyFrameRequest,
      onBitRateChange: onBitRateChange)
    try await session.startListening()
    return session
  }

  private init(
    port: UInt16,
    identity: QUICSessionIdentity,
    codec: VideoStreamCodec,
    logger: any ControlCoreLogger,
    onClientReady: @escaping @Sendable () -> Void,
    onKeyFrameRequest: @escaping @Sendable () -> Void,
    onBitRateChange: @escaping @Sendable (Int) -> Void
  ) throws {
    self.onBitRateChange = onBitRateChange
    self.certificateSHA256 = identity.certificateSHA256
    var token = Data(count: 32)
    for index in token.indices {
      token[index] = UInt8.random(in: 0...255)
    }
    self.token = token
    self.codec = codec
    self.logger = logger
    self.onClientReady = onClientReady
    self.onKeyFrameRequest = onKeyFrameRequest
    (endedStream, endedContinuation) = AsyncStream<Void>.makeStream()

    let quic = NWProtocolQUIC.Options(alpn: [QUICVideoWire.alpn])
    quic.idleTimeout = QUICVideoWire.idleTimeoutMilliseconds
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, identity.identity)
    let parameters = NWParameters(quic: quic)
    if let serviceClass = Self.serviceClass(named: ProcessInfo.processInfo.environment["IDB_QUIC_SERVICE_CLASS"]) {
      parameters.serviceClass = serviceClass
    }
    if port == 0 {
      listener = try NWListener(using: parameters)
    } else {
      listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    frameStreamOptions = NWProtocolQUIC.Options(alpn: [QUICVideoWire.alpn])
    frameStreamOptions.direction = .unidirectional
  }

  // MARK: DataConsumer

  func consumeData(_ data: Data) {
    let now = DispatchTime.now().uptimeNanoseconds
    let timing = EncodedFrameTiming(
      submittedAtUptimeNanos: now, encodedAtUptimeNanos: now, isKeyFrame: AnnexBKeyFrameDetector.isKeyFrame(data, codec: codec))
    consumeFrame(data, timing: timing)
  }

  func consumeFrame(_ data: Data, timing: EncodedFrameTiming) {
    outstanding.withLock { $0.count += 1 }
    queue.async { self.send(frame: data, timing: timing) }
  }

  func consumeEndOfFile() {
    queue.async { self.end("the video stream ended") }
  }

  var consumption: DataConsumption {
    let now = DispatchTime.now().uptimeNanoseconds
    return .queued(
      unprocessed: outstanding.withLock { state -> Int in
        let reported = backpressure.reportedQueue(outstanding: state.count, oldestSentAt: state.sentAt.values.min(), now: now)
        if reported > 2 {
          state.dropSignals += 1
        }
        return reported
      })
  }

  static func serviceClass(named name: String?) -> NWParameters.ServiceClass? {
    switch name {
    case "interactiveVideo": return .interactiveVideo
    case "interactiveVoice": return .interactiveVoice
    case "responsiveData": return .responsiveData
    case "signaling": return .signaling
    case "background": return .background
    case "bestEffort": return .bestEffort
    default: return nil
    }
  }

  // MARK: Lifecycle

  /// Returns once the session has ended: closed, its client gone, or its listener failed.
  func waitUntilEnded() async {
    for await _ in endedStream {}
  }

  func close() {
    queue.async { self.end("the session was stopped") }
  }

  private func startListening() async throws {
    listener.stateUpdateHandler = { [weak self] state in
      self?.listenerStateChanged(state)
    }
    listener.newConnectionGroupHandler = { [weak self] group in
      self?.accept(group)
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        self.listenerReady = continuation
        self.listener.start(queue: self.queue)
      }
    }
  }

  private func listenerStateChanged(_ state: NWListener.State) {
    switch state {
    case .ready:
      port = listener.port?.rawValue ?? 0
      listenerReady?.resume()
      listenerReady = nil
    case let .failed(error):
      listenerReady?.resume(throwing: QUICVideoSessionError.listenerFailed("\(error)"))
      listenerReady = nil
      end("the QUIC listener failed: \(error)")
    case .cancelled:
      listenerReady?.resume(throwing: QUICVideoSessionError.listenerFailed("cancelled"))
      listenerReady = nil
    default:
      break
    }
  }

  private func end(_ reason: String) {
    guard !ended else {
      return
    }
    ended = true
    statsTimer?.cancel()
    statsTimer = nil
    bitRateTimer?.cancel()
    bitRateTimer = nil
    for entry in inFlight.values {
      entry.stream?.forceCancel()
    }
    inFlight.removeAll()
    frameStream?.forceCancel()
    frameStream = nil
    outstanding.withLock { $0 = Outstanding() }
    controlStream?.cancel()
    client?.cancel()
    for group in connecting.values {
      group.cancel()
    }
    connecting.removeAll()
    listener.cancel()
    accumulate(window)
    window = Stats()
    logger.log("QUIC video session ended (\(reason)): \(summary(of: total)), \(ignoredKeyFrameRequests) keyframe requests ignored, \(bitRateChanges) bitrate changes, final target \(bitRateTarget)")
    endedContinuation.finish()
  }

  // MARK: Accepting the client

  private func accept(_ group: NWConnectionGroup) {
    guard !ended, client == nil else {
      group.cancel()
      return
    }
    let id = ObjectIdentifier(group)
    connecting[id] = group
    group.newConnectionHandler = { [weak self, weak group] stream in
      guard let self, let group else {
        stream.cancel()
        return
      }
      self.acceptStream(stream, on: group)
    }
    group.stateUpdateHandler = { [weak self, weak group] state in
      guard let self, let group else { return }
      switch state {
      case let .failed(error):
        self.groupEnded(group, reason: "failed: \(error)")
      case .cancelled:
        self.groupEnded(group, reason: "closed")
      default:
        break
      }
    }
    group.start(queue: queue)
  }

  private func groupEnded(_ group: NWConnectionGroup, reason: String) {
    if group === client {
      end("the client connection \(reason)")
    } else {
      connecting.removeValue(forKey: ObjectIdentifier(group))
    }
  }

  /// The first stream a connection opens must carry the token; any other is refused.
  private func acceptStream(_ stream: NWConnection, on group: NWConnectionGroup) {
    guard client == nil, controlStream == nil else {
      stream.cancel()
      return
    }
    stream.start(queue: queue)
    readToken(from: stream, on: group, received: Data())
  }

  private func readToken(from stream: NWConnection, on group: NWConnectionGroup, received: Data) {
    stream.receive(minimumIncompleteLength: 1, maximumLength: token.count - received.count) { [weak self] content, _, isComplete, error in
      guard let self, !self.ended else { return }
      var received = received
      if let content {
        received.append(content)
      }
      if received.count < self.token.count {
        if isComplete || error != nil {
          group.cancel()
        } else {
          self.readToken(from: stream, on: group, received: received)
        }
        return
      }
      guard Self.constantTimeEqual(received, self.token), self.client == nil else {
        self.logger.log("QUIC video: refused a connection from \(stream.endpoint) that did not present the session token")
        group.cancel()
        return
      }
      self.connecting.removeValue(forKey: ObjectIdentifier(group))
      self.client = group
      self.controlStream = stream
      self.logger.log(
        "QUIC video: client connected from \(stream.endpoint); backpressure \(self.backpressure), cancel on keyframe \(self.cancelOnKeyFrame), framing \(self.streamFraming ? "single stream" : "stream per frame")")
      self.startStatsTimer()
      self.startRateAdaptation()
      self.readControl(from: stream)
      self.onClientReady()
    }
  }

  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else {
      return false
    }
    return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
  }

  // MARK: Control messages

  private func readControl(from stream: NWConnection) {
    stream.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
      guard let self, !self.ended else { return }
      if let content {
        self.controlBuffer.append(content)
        self.processControlMessages()
      }
      if let error {
        self.end("the control stream failed: \(error)")
      } else if isComplete {
        self.end("the client closed its control stream")
      } else {
        self.readControl(from: stream)
      }
    }
  }

  private func processControlMessages() {
    while let first = controlBuffer.first {
      guard let message = QUICVideoWire.Control(rawValue: first) else {
        end("the client sent an unknown control message \(first)")
        return
      }
      let length = 1 + message.payloadLength
      guard controlBuffer.count >= length else {
        return
      }
      let payload = controlBuffer.dropFirst().prefix(message.payloadLength)
      switch message {
      case .ack:
        acknowledge(sequence: QUICVideoWire.uint64(bigEndian: payload))
      case .keyFrame:
        requestKeyFrameFromClient()
      case .ping:
        break
      }
      controlBuffer = Data(controlBuffer.dropFirst(length))
    }
  }

  private func requestKeyFrameFromClient() {
    if keyFrameMinIntervalNanos > 0 {
      let now = DispatchTime.now().uptimeNanoseconds
      if keyFrameInFlight != nil || now - lastKeyFrameSentAt < keyFrameMinIntervalNanos {
        ignoredKeyFrameRequests += 1
        return
      }
    }
    onKeyFrameRequest()
  }

  private func acknowledge(sequence: UInt64) {
    guard let entry = inFlight.removeValue(forKey: sequence) else {
      return
    }
    if keyFrameInFlight == sequence {
      keyFrameInFlight = nil
    }
    release(sequence: sequence)
    entry.stream?.cancel()
    let ackedAt = DispatchTime.now().uptimeNanoseconds
    let roundTrip = ackedAt - entry.sentAt
    if adaptiveBitRate != nil {
      roundTrips.append((ackedAt, roundTrip))
      intervalRoundTrips.append(roundTrip)
    }
    window.acknowledged += 1
    window.roundTripNanos += roundTrip
    window.roundTripMaxNanos = max(window.roundTripMaxNanos, roundTrip)
  }

  // MARK: Sending frames

  private func send(frame: Data, timing: EncodedFrameTiming) {
    guard !ended, let client else {
      release()
      return
    }
    let isKeyFrame = timing.isKeyFrame
    // Frames on the single stream cannot be withdrawn; only per-frame streams can be cancelled.
    if isKeyFrame && cancelOnKeyFrame && !streamFraming {
      cancelInFlight()
    }
    let stream: NWConnection
    if streamFraming, let frameStream {
      stream = frameStream
    } else {
      guard let newStream = NWConnection(from: client, using: frameStreamOptions) else {
        release()
        return
      }
      newStream.start(queue: queue)
      stream = newStream
      if streamFraming {
        frameStream = newStream
      }
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let sequence = nextSequence
    nextSequence += 1
    var message =
      streamFraming
      ? QUICVideoWire.streamFrameHeader(length: frame.count, sequence: sequence, isKeyFrame: isKeyFrame, capturedAtUptimeNanos: timing.submittedAtUptimeNanos)
      : QUICVideoWire.frameHeader(sequence: sequence, isKeyFrame: isKeyFrame, capturedAtUptimeNanos: timing.submittedAtUptimeNanos)
    message.append(frame)
    trace?.record(transport: "quic", streamID: traceStreamID, sequence: sequence, timing: timing, handedOffAtUptimeNanos: now, bytes: frame.count)
    inFlight[sequence] = (streamFraming ? nil : stream, now)
    outstanding.withLock { $0.sentAt[sequence] = now }
    let context: NWConnection.ContentContext = streamFraming ? .defaultStream : .finalMessage
    stream.send(content: message, contentContext: context, isComplete: !streamFraming, completion: .contentProcessed { [weak self] error in
      guard let self, let error, self.inFlight.removeValue(forKey: sequence) != nil else { return }
      if self.keyFrameInFlight == sequence {
        self.keyFrameInFlight = nil
      }
      self.release(sequence: sequence)
      self.logger.log("QUIC video: failed to send frame \(sequence): \(error)")
    })
    window.frames += 1
    window.bytes += message.count
    if isKeyFrame {
      lastKeyFrameSentAt = now
      keyFrameInFlight = sequence
      window.keyFrames += 1
    }
  }

  /// Cancels the streams of frames the client has not acknowledged: after a keyframe it can
  /// decode without them.
  private func cancelInFlight() {
    for (sequence, entry) in inFlight {
      entry.stream?.forceCancel()
      release(sequence: sequence)
    }
    window.cancelled += inFlight.count
    inFlight.removeAll()
    keyFrameInFlight = nil
  }

  /// One handed-over frame is done: acknowledged, cancelled, failed, or never sent (no sequence).
  private func release(sequence: UInt64? = nil) {
    outstanding.withLock { state in
      state.count = max(0, state.count - 1)
      if let sequence {
        state.sentAt.removeValue(forKey: sequence)
      }
    }
  }

  // MARK: Rate adaptation

  private func startRateAdaptation() {
    guard let config = adaptiveBitRate else {
      return
    }
    applyBitRate(config.start)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let interval = DispatchTimeInterval.milliseconds(config.intervalMilliseconds)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler { [weak self] in
      self?.adaptBitRate(config)
    }
    bitRateTimer = timer
    timer.resume()
    logger.log("QUIC video: adaptive bitrate on, \(config)")
  }

  private func adaptBitRate(_ config: QUICAdaptiveBitRate) {
    let now = DispatchTime.now().uptimeNanoseconds
    roundTrips.removeAll { now - $0.at > 10_000_000_000 }
    let minimum = roundTrips.map(\.nanos).min() ?? 0
    let queueDelays = intervalRoundTrips.map { $0 > minimum ? $0 - minimum : 0 }
    intervalRoundTrips.removeAll()
    let drops = outstanding.withLock { state -> Int in
      defer { state.dropSignals = 0 }
      return state.dropSignals
    }
    guard let next = config.next(current: bitRateTarget, queueDelays: queueDelays, drops: drops) else {
      return
    }
    if abs(next - bitRateTarget) * 100 >= bitRateTarget * 3 {
      applyBitRate(next)
    }
  }

  private func applyBitRate(_ bitsPerSecond: Int) {
    bitRateTarget = bitsPerSecond
    bitRateChanges += 1
    trace?.recordEvent("bitrate \(bitsPerSecond)")
    onBitRateChange(bitsPerSecond)
  }

  // MARK: Stats

  private func startStatsTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let interval = 5.0
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      if self.window.frames > 0 || self.window.cancelled > 0 {
        self.logger.log("QUIC video: \(self.summary(of: self.window, over: interval)), \(self.inFlight.count) in flight")
      }
      self.accumulate(self.window)
      self.window = Stats()
    }
    statsTimer = timer
    timer.resume()
  }

  private func accumulate(_ stats: Stats) {
    total.frames += stats.frames
    total.keyFrames += stats.keyFrames
    total.bytes += stats.bytes
    total.acknowledged += stats.acknowledged
    total.cancelled += stats.cancelled
    total.roundTripNanos += stats.roundTripNanos
    total.roundTripMaxNanos = max(total.roundTripMaxNanos, stats.roundTripMaxNanos)
  }

  private func summary(of stats: Stats, over seconds: Double? = nil) -> String {
    let averageRoundTrip = stats.acknowledged > 0 ? Double(stats.roundTripNanos) / Double(stats.acknowledged) / 1e6 : 0
    var parts = ["\(stats.frames) frames (\(stats.keyFrames) key)"]
    if let seconds {
      parts.append(String(format: "%.1f fps", Double(stats.frames) / seconds))
      parts.append(String(format: "%.0f kbit/s", Double(stats.bytes) * 8 / seconds / 1000))
    } else {
      parts.append("\(stats.bytes) bytes")
    }
    parts.append(String(format: "ack RTT avg %.1f ms max %.1f ms", averageRoundTrip, Double(stats.roundTripMaxNanos) / 1e6))
    parts.append("\(stats.cancelled) stale cancelled")
    return parts.joined(separator: ", ")
  }
}
