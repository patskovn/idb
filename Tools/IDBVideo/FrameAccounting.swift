/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Appends a line per frame written, for measuring delivery offline. Columns: write time, bytes,
/// keyframe (1/0), sequence, capture time, receive time. Times are host uptime in nanoseconds
/// (`DispatchTime.now().uptimeNanoseconds`). The capture time is the companion's, from the QUIC frame
/// header (0 over gRPC), so `receive - capture` is the latency only when both run on one host.
final class FrameLog: @unchecked Sendable {
  private let handle: FileHandle
  private let lock = NSLock()

  init(path: String) throws {
    guard FileManager.default.createFile(atPath: path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }
    handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
  }

  func record(bytes: Int, isKeyFrame: Bool, sequence: UInt64, capturedAt: UInt64, receivedAt: UInt64) {
    let line = "\(DispatchTime.now().uptimeNanoseconds) \(bytes) \(isKeyFrame ? 1 : 0) \(sequence) \(capturedAt) \(receivedAt)\n"
    lock.withLock {
      handle.write(Data(line.utf8))
    }
  }
}

/// Statistics lines for frames that arrive on the gRPC call, matching the QUIC receiver's.
struct PayloadStats {
  private let interval: Double
  private var windowStart = DispatchTime.now().uptimeNanoseconds
  private var frames = 0
  private var keyFrames = 0
  private var bytes = 0

  init(interval: Double) {
    self.interval = interval
  }

  mutating func record(bytes: Int, isKeyFrame: Bool) {
    frames += 1
    self.bytes += bytes
    if isKeyFrame {
      keyFrames += 1
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsed = Double(now - windowStart) / 1e9
    guard interval > 0, elapsed >= interval else {
      return
    }
    log(String(format: "%.1f fps written, %.0f kbit/s, %d received (%d key) over gRPC", Double(frames) / elapsed, Double(self.bytes) * 8 / elapsed / 1000, frames, keyFrames))
    windowStart = now
    frames = 0
    keyFrames = 0
    self.bytes = 0
  }
}

/// The client's copy of the companion's `AnnexBKeyFrameDetector`: whether an Annex-B access unit
/// carries parameter sets or an IDR/IRAP slice.
enum AnnexBKeyFrameDetector {
  static func isKeyFrame(_ data: Data, codec: IDBVideo.Codec) -> Bool {
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
