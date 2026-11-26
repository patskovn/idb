/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import os

/// Holds decoded stereo sound between the network, which delivers it in bursts, and the sound
/// card, which takes it at a steady rate.
///
/// Sound written while the buffer is empty is preceded by `targetFrames` of silence, so that it
/// starts playing that much later and the packets that follow have that long to arrive. The
/// companion does not send silence, so every sound starts this way, and the delay is set again
/// each time rather than drifting with the two machines' clocks. If packets arrive faster than
/// they are played for long enough to pass `maximumFrames`, the oldest sound is dropped back down
/// to the target: late sound is worse than a skip.
///
/// @unchecked Sendable: everything mutable is behind `lock`, which the sound card's thread holds
/// only to copy.
final class AudioJitterBuffer: @unchecked Sendable {
  struct Counts: Equatable {
    /// Frames of sound taken by the sound card.
    var played = 0
    /// Times sound was written into an empty buffer: the starts of sounds, and underruns.
    var starts = 0
    /// Times sound was dropped because too much was waiting, and how many frames.
    var overflows = 0
    var dropped = 0
  }

  let targetFrames: Int
  let maximumFrames: Int

  private struct State {
    var left: [Float]
    var right: [Float]
    var readIndex = 0
    var count = 0
    var counts = Counts()
  }

  private let lock: OSAllocatedUnfairLock<State>
  private let capacity: Int

  init(targetFrames: Int, maximumFrames: Int) {
    self.targetFrames = max(0, targetFrames)
    self.maximumFrames = max(maximumFrames, self.targetFrames + 1)
    // Room for the most that may wait, the silence before a sound and one write on top.
    capacity = self.maximumFrames + self.targetFrames + 48_000
    lock = OSAllocatedUnfairLock(initialState: State(left: [Float](repeating: 0, count: capacity), right: [Float](repeating: 0, count: capacity)))
  }

  var counts: Counts {
    lock.withLock { $0.counts }
  }

  /// The frames waiting to be played, silence before a sound included.
  var buffered: Int {
    lock.withLock { $0.count }
  }

  /// Adds sound to play after what is waiting.
  func write(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
    let frames = min(left.count, right.count, capacity - targetFrames)
    guard frames > 0 else {
      return
    }
    let capacity = capacity
    let targetFrames = targetFrames
    let maximumFrames = maximumFrames
    lock.withLockUnchecked { state in
      func push(_ value: (Int) -> (Float, Float), count: Int) {
        var index = (state.readIndex + state.count) % capacity
        for offset in 0..<count {
          (state.left[index], state.right[index]) = value(offset)
          index += 1
          if index == capacity {
            index = 0
          }
        }
        state.count += count
      }
      if state.count == 0 {
        state.counts.starts += 1
        push({ _ in (0, 0) }, count: targetFrames)
      }
      push({ (left[$0], right[$0]) }, count: frames)
      if state.count > maximumFrames {
        let excess = state.count - targetFrames
        state.readIndex = (state.readIndex + excess) % capacity
        state.count -= excess
        state.counts.overflows += 1
        state.counts.dropped += excess
      }
    }
  }

  /// Fills `frames` frames for the sound card: what is waiting, then silence.
  func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
    let capacity = capacity
    lock.withLockUnchecked { state in
      let available = min(frames, state.count)
      var index = state.readIndex
      for offset in 0..<available {
        left[offset] = state.left[index]
        right[offset] = state.right[index]
        index += 1
        if index == capacity {
          index = 0
        }
      }
      state.readIndex = index
      state.count -= available
      state.counts.played += available
      for offset in available..<frames {
        left[offset] = 0
        right[offset] = 0
      }
    }
  }
}
