/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFAudio
import Foundation

enum AudioPlayerError: Error, LocalizedError {
  case unsupportedFormat(sampleRate: Int, channels: Int, framesPerPacket: Int)
  case noDecoder

  var errorDescription: String? {
    switch self {
    case let .unsupportedFormat(sampleRate, channels, framesPerPacket):
      return "cannot play the companion's audio (\(sampleRate) Hz, \(channels) channels, \(framesPerPacket) frames per packet): only stereo is played"
    case .noDecoder:
      return "this Mac has no Opus decoder"
    }
  }
}

/// Plays the device's sound on this Mac's default output: decodes the companion's Opus packets and
/// feeds the sound card from an `AudioJitterBuffer`.
///
/// @unchecked Sendable: the decoder and the log are used on the receiver's queue only, which is
/// where `receive` is called; the sound card's thread touches the jitter buffer alone.
final class AudioPlayer: @unchecked Sendable {
  private let opus: AVAudioFormat
  private let pcm: AVAudioFormat
  private let decoder: AVAudioConverter
  private let output: AVAudioPCMBuffer
  private let buffer: AudioJitterBuffer
  private let engine = AVAudioEngine()
  private let packetLog: FileHandle?
  private var configurationObserver: (any NSObjectProtocol)?
  private var packets = 0
  private var failures = 0

  /// - Parameters:
  ///   - bufferMilliseconds: How long a sound waits before it plays, for the packets after its
  ///     first to arrive in.
  ///   - packetLogPath: Appends a line per packet: uptime in nanoseconds, bytes, 1 when it starts a
  ///     run, when it played on the companion's Mac (its uptime in nanoseconds), its peak level and
  ///     the milliseconds of sound waiting once it was added.
  init(sampleRate: Int, channels: Int, framesPerPacket: Int, bufferMilliseconds: Int, packetLogPath: String?) throws {
    var description = AudioStreamBasicDescription(
      mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket),
      mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
    guard channels == 2, sampleRate > 0, framesPerPacket > 0, let opus = AVAudioFormat(streamDescription: &description),
      let pcm = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)
    else {
      throw AudioPlayerError.unsupportedFormat(sampleRate: sampleRate, channels: channels, framesPerPacket: framesPerPacket)
    }
    guard let decoder = AVAudioConverter(from: opus, to: pcm), let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(framesPerPacket * 4))
    else {
      throw AudioPlayerError.noDecoder
    }
    self.opus = opus
    self.pcm = pcm
    self.decoder = decoder
    self.output = output
    let target = sampleRate * max(0, bufferMilliseconds) / 1000
    // A fifth of a second more than the delay may wait before sound is dropped to catch up.
    buffer = AudioJitterBuffer(targetFrames: target, maximumFrames: target + sampleRate / 5)
    if let packetLogPath {
      FileManager.default.createFile(atPath: packetLogPath, contents: nil)
      packetLog = FileHandle(forWritingAtPath: packetLogPath)
    } else {
      packetLog = nil
    }
  }

  /// Starts the output. It runs, playing silence, until `stop`: a sound card started when a sound
  /// arrives would play the start of it late.
  func start() throws {
    let buffer = buffer
    let source = AVAudioSourceNode(format: pcm) { _, _, frameCount, audioBufferList in
      let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
      guard buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData else {
        return noErr
      }
      buffer.read(left: left.assumingMemoryBound(to: Float.self), right: right.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
      return noErr
    }
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: pcm)
    try engine.start()
    // Plugging headphones in or out stops the engine; start it again on the new output.
    configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
      guard let self else { return }
      do {
        try self.engine.start()
      } catch {
        log("audio: cannot play on the new output: \(error.localizedDescription)")
      }
    }
  }

  func stop() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    engine.stop()
    let counts = buffer.counts
    if packets > 0 || failures > 0 {
      log(
        "audio: \(packets) packets, \(String(format: "%.1f", Double(counts.played) / pcm.sampleRate)) s played in \(counts.starts) starts, "
          + "\(counts.dropped) frames dropped to catch up, \(failures) packets not decoded")
    }
  }

  /// Takes the next packet of the stream, in order.
  func receive(_ packet: Data, startsRun: Bool, playedAtUptimeNanos: UInt64) {
    guard !packet.isEmpty else {
      return
    }
    let compressed = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
    packet.copyBytes(to: compressed.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
    compressed.byteLength = UInt32(packet.count)
    compressed.packetCount = 1
    compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
    var given = false
    var error: NSError?
    let status = decoder.convert(to: output, error: &error) { _, inputStatus in
      if given {
        inputStatus.pointee = .noDataNow
        return nil
      }
      given = true
      inputStatus.pointee = .haveData
      return compressed
    }
    guard status != .error, let channels = output.floatChannelData else {
      failures += 1
      if failures == 1 {
        log("audio: a packet failed to decode: \(error?.localizedDescription ?? "unknown error")")
      }
      return
    }
    packets += 1
    let frames = Int(output.frameLength)
    let left = UnsafeBufferPointer(start: channels[0], count: frames)
    let right = UnsafeBufferPointer(start: channels[1], count: frames)
    buffer.write(left: left, right: right)
    if let packetLog {
      let peak = max(left.reduce(Float(0)) { max($0, abs($1)) }, right.reduce(Float(0)) { max($0, abs($1)) })
      let line = String(
        format: "%llu %d %d %llu %.4f %.1f\n", DispatchTime.now().uptimeNanoseconds, packet.count, startsRun ? 1 : 0, playedAtUptimeNanos, peak,
        Double(buffer.buffered) / pcm.sampleRate * 1000)
      packetLog.write(Data(line.utf8))
    }
  }
}
