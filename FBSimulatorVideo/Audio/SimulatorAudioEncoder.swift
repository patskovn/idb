/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFAudio
import Foundation

/// One Opus packet of what a simulator played.
public struct SimulatorAudioPacket: Sendable, Equatable {
  public let data: Data
  /// The Mac's uptime, in nanoseconds, at which the packet's first frame played: the clock a video
  /// frame's capture time is on.
  public let playedAtUptimeNanos: UInt64
  /// True when the packet does not continue the one before it: the first one, and the first after
  /// a silence that was not sent.
  public let startsRun: Bool
}

/// Sends sound and leaves silence out.
///
/// A simulator is silent most of the time, and a tap delivers that silence as zeros at the full
/// rate. A run of packets starts with the first block that holds sound and ends once there has been
/// none for `hangover` blocks, long enough that the codec's tail and a pause inside a sound are
/// sent whole.
struct AudioSilenceGate {
  /// Below this peak a block is silence: -100 dBFS, under the noise of 16-bit audio.
  static let silencePeak: Float = 0.00001

  let hangover: Int
  private var quietBlocks: Int?

  init(hangover: Int) {
    self.hangover = hangover
  }

  /// Whether to send a block with this peak, and whether it starts a run.
  mutating func admit(peak: Float) -> (send: Bool, startsRun: Bool) {
    if peak >= Self.silencePeak {
      defer { quietBlocks = 0 }
      return (true, quietBlocks == nil)
    }
    guard let quiet = quietBlocks else {
      return (false, false)
    }
    if quiet >= hangover {
      quietBlocks = nil
      return (false, false)
    }
    quietBlocks = quiet + 1
    return (true, false)
  }
}

enum SimulatorAudioEncoderError: Error, LocalizedError {
  case unsupportedChannels(Int)
  case noOpusEncoder
  case noResampler(from: Double)

  var errorDescription: String? {
    switch self {
    case let .unsupportedChannels(channels):
      return "The simulator's audio has \(channels) channels; only stereo is encoded"
    case .noOpusEncoder:
      return "This Mac has no Opus encoder"
    case let .noResampler(rate):
      return "Cannot convert the simulator's audio from \(rate) Hz to 48000 Hz"
    }
  }
}

/// Turns the blocks a tap delivers into Opus packets of 10 ms, 48 kHz stereo.
///
/// Not Sendable: the stream uses it on its audio queue only.
final class SimulatorAudioEncoder {
  static let sampleRate = 48_000.0
  static let channels = 2
  static let framesPerPacket = 480
  /// Near transparent for Opus in stereo, and a twentieth of what the video takes.
  static let bitRate = 96_000
  /// Half a second of silence ends a run.
  static let hangoverPackets = 50

  private let encoder: AVAudioConverter
  private let input: AVAudioPCMBuffer
  private let opus: AVAudioFormat
  private let resampler: (converter: AVAudioConverter, from: AVAudioFormat, to: AVAudioFormat)?
  private var gate = AudioSilenceGate(hangover: SimulatorAudioEncoder.hangoverPackets)
  /// Interleaved 48 kHz samples not yet a whole packet, and when the first of them played.
  private var pending: [Float] = []
  private var pendingPlayedAt: UInt64 = 0

  /// - Parameter sampleRate: The rate of the samples `append` is given.
  init(sampleRate: Double, channels: Int) throws {
    guard channels == Self.channels else {
      throw SimulatorAudioEncoderError.unsupportedChannels(channels)
    }
    var description = AudioStreamBasicDescription(
      mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.framesPerPacket),
      mBytesPerFrame: 0, mChannelsPerFrame: UInt32(Self.channels), mBitsPerChannel: 0, mReserved: 0)
    guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: AVAudioChannelCount(Self.channels), interleaved: true),
      let opus = unsafe AVAudioFormat(streamDescription: &description), let encoder = AVAudioConverter(from: pcm, to: opus),
      let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(Self.framesPerPacket))
    else {
      throw SimulatorAudioEncoderError.noOpusEncoder
    }
    encoder.bitRate = Self.bitRate
    self.encoder = encoder
    self.opus = opus
    self.input = input
    if sampleRate == Self.sampleRate {
      resampler = nil
    } else {
      guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true),
        let converter = AVAudioConverter(from: source, to: pcm)
      else {
        throw SimulatorAudioEncoderError.noResampler(from: sampleRate)
      }
      resampler = (converter, source, pcm)
    }
  }

  /// Takes a block of interleaved samples whose first frame played at `playedAtUptimeNanos`, and
  /// returns the packets it completes: none while the simulator is silent.
  func append(_ samples: [Float], playedAtUptimeNanos: UInt64) -> [SimulatorAudioPacket] {
    let samples = resampler == nil ? samples : resample(samples)
    if pending.isEmpty {
      pendingPlayedAt = playedAtUptimeNanos
    } else {
      // Anchored again on every block, so the audio clock's drift from the host clock never adds up.
      let heldNanos = UInt64(Double(pending.count / Self.channels) / Self.sampleRate * 1e9)
      pendingPlayedAt = playedAtUptimeNanos > heldNanos ? playedAtUptimeNanos - heldNanos : 0
    }
    pending.append(contentsOf: samples)

    let packetSamples = Self.framesPerPacket * Self.channels
    let packetNanos = UInt64(Double(Self.framesPerPacket) / Self.sampleRate * 1e9)
    var packets: [SimulatorAudioPacket] = []
    var consumed = 0
    while pending.count - consumed >= packetSamples {
      let block = pending[consumed..<(consumed + packetSamples)]
      let playedAt = pendingPlayedAt
      consumed += packetSamples
      pendingPlayedAt += packetNanos
      let peak = block.reduce(Float(0)) { max($0, abs($1)) }
      let (send, startsRun) = gate.admit(peak: peak)
      guard send, let data = encode(block) else {
        continue
      }
      packets.append(SimulatorAudioPacket(data: data, playedAtUptimeNanos: playedAt, startsRun: startsRun))
    }
    pending.removeFirst(consumed)
    return packets
  }

  private func encode(_ block: ArraySlice<Float>) -> Data? {
    guard let destination = unsafe input.floatChannelData?[0] else {
      return nil
    }
    block.withUnsafeBufferPointer { source in
      unsafe destination.update(from: source.baseAddress!, count: source.count)
    }
    input.frameLength = AVAudioFrameCount(Self.framesPerPacket)
    let packet = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: encoder.maximumOutputPacketSize)
    var given = false
    var error: NSError?
    let status = unsafe encoder.convert(to: packet, error: &error) { [input] _, inputStatus in
      if given {
        unsafe inputStatus.pointee = .noDataNow
        return nil
      }
      given = true
      unsafe inputStatus.pointee = .haveData
      return input
    }
    guard status != .error, packet.packetCount == 1, packet.byteLength > 0 else {
      return nil
    }
    return unsafe Data(bytes: packet.data, count: Int(packet.byteLength))
  }

  private func resample(_ samples: [Float]) -> [Float] {
    guard let resampler, !samples.isEmpty else {
      return samples
    }
    let frames = samples.count / Self.channels
    let capacity = AVAudioFrameCount(Double(frames) * Self.sampleRate / resampler.from.sampleRate) + 64
    guard let source = AVAudioPCMBuffer(pcmFormat: resampler.from, frameCapacity: AVAudioFrameCount(frames)),
      let output = AVAudioPCMBuffer(pcmFormat: resampler.to, frameCapacity: capacity), let sourceData = unsafe source.floatChannelData?[0]
    else {
      return []
    }
    samples.withUnsafeBufferPointer { buffer in
      unsafe sourceData.update(from: buffer.baseAddress!, count: frames * Self.channels)
    }
    source.frameLength = AVAudioFrameCount(frames)
    var given = false
    var error: NSError?
    let status = unsafe resampler.converter.convert(to: output, error: &error) { _, inputStatus in
      if given {
        unsafe inputStatus.pointee = .noDataNow
        return nil
      }
      given = true
      unsafe inputStatus.pointee = .haveData
      return source
    }
    guard status != .error, let outputData = unsafe output.floatChannelData?[0] else {
      return []
    }
    return unsafe Array(UnsafeBufferPointer(start: outputData, count: Int(output.frameLength) * Self.channels))
  }
}
