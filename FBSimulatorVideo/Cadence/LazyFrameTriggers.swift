/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation
import os

/// A stimulus to push one frame, produced by either cadence: the `FrameCadence` clock (eager) or
/// `LazyFrameTriggers` (lazy, fed by damage/overlay callbacks). Modelling both as the same element
/// lets a single push loop serve both modes.
struct FrameTrigger {
  /// Whether this push should force a keyframe — e.g. a `.lazy` overlay change, so consumers that
  /// need a keyframe can decode it immediately. Cadence-clock ticks never force one.
  let forceKeyFrame: Bool
  /// True when the previous push overshot its deadline (eager cadence only — always false for VFR).
  let overran: Bool
  /// True when no rendered frame was signaled since the previous `.lazy` trigger, so the push only redraws the overlay
  /// over the screen the Simulator last presented. Always false for the eager clock.
  let overlayOnly: Bool
}

/// The `.lazy` (VFR) stimulus: an `AsyncSequence` of `FrameTrigger`s poked by rendered frames and overlay changes.
/// A trigger reports every keyframe request and rendered frame signaled since the previous one.
///
/// Triggers are paced to at most `maximumFramesPerSecond`, so a display that presents more often than a viewer
/// shows (120 Hz, or a Simulator that presents twice within one 60 Hz interval) does not cost an encode per frame.
/// The pacing never holds a signal that is due:
///
/// - A signal that comes about an interval or more after the last trigger (within a quarter of an interval of
///   it) is released at once, so the push reads the surface the moment the Simulator has presented the frame.
///   That is when the surface is still. A push held until the pacer's own deadline would read it at an arbitrary
///   moment of the Simulator's next frame, and would drift across it, because the two clocks never agree exactly.
/// - A signal that comes sooner is not released. If one that is due follows, that one is released and reports
///   both. If none does, the early one is released a quarter of an interval after it was due, so the last state
///   of the screen is always pushed.
final class LazyFrameTriggers: AsyncSequence, Sendable {
  typealias Element = FrameTrigger

  /// The default pace: one push per 60 Hz display interval.
  static let defaultMaximumFramesPerSecond: UInt = 60

  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  /// What the next trigger reports, held beside the stream rather than in its elements, which coalescing drops
  fileprivate struct Pending {
    var keyFrame = false
    var frameRendered = false
    /// Whether anything at all was signaled since the last trigger was handed out.
    var signaled = false
  }

  private struct State {
    var pending = Pending()
    /// When the last trigger was released, as host uptime in nanoseconds.
    var lastReleaseNanos: UInt64 = 0
    /// Whether a release is scheduled for signals that came too soon to be released at once.
    var lateReleaseScheduled = false
    var finished = false
  }

  private enum Release {
    case now
    case later(atUptimeNanos: UInt64)
    case alreadyScheduled
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let intervalNanos: UInt64
  /// How much sooner than the interval a signal may come and still be released at once, and how long after the
  /// interval a signal that came too soon waits for one that is due.
  private let toleranceNanos: UInt64

  init(maximumFramesPerSecond: UInt = LazyFrameTriggers.defaultMaximumFramesPerSecond) {
    self.intervalNanos = NSEC_PER_SEC / UInt64(maximumFramesPerSecond)
    self.toleranceNanos = intervalNanos / 4
    // The builder hands back the continuation synchronously, so the IUO is assigned before use.
    // swiftlint:disable:next implicitly_unwrapped_optional
    var continuation: AsyncStream<Void>.Continuation!
    self.stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    self.continuation = continuation
  }

  /// Signal that a new frame was rendered — enqueue a push of the latest state.
  func signalFrameRendered() {
    signal { $0.frameRendered = true }
  }

  /// Signal that the overlay's contents changed in place, enqueueing a push that redraws it
  func signalOverlayChanged() {
    signal { _ in }
  }

  /// Signal that the overlay changed — mark the next push a keyframe so consumers that need a keyframe
  /// can decode the change immediately, then enqueue a push.
  func signalKeyFrame() {
    signal { $0.keyFrame = true }
  }

  /// End the stream, completing the push loop's `for await`.
  func finish() {
    state.withLock { $0.finished = true }
    continuation.finish()
  }

  private func signal(_ mark: @Sendable (inout Pending) -> Void) {
    let now = DispatchTime.now().uptimeNanoseconds
    let release = state.withLock { state -> Release in
      mark(&state.pending)
      state.pending.signaled = true
      return release(&state, now: now)
    }
    perform(release)
  }

  /// Decides what a pending signal gets at `now`: a trigger, or a later look.
  private func release(_ state: inout State, now: UInt64) -> Release {
    if now + toleranceNanos >= state.lastReleaseNanos + intervalNanos {
      state.lastReleaseNanos = now
      return .now
    }
    if state.lateReleaseScheduled {
      return .alreadyScheduled
    }
    state.lateReleaseScheduled = true
    return .later(atUptimeNanos: state.lastReleaseNanos + intervalNanos + toleranceNanos)
  }

  private func perform(_ release: Release) {
    switch release {
    case .now:
      continuation.yield(())
    case let .later(deadline):
      Task { [weak self] in
        guard (try? await StrictTimer.wait(untilUptimeNanoseconds: deadline)) != nil else {
          return
        }
        self?.releaseLate()
      }
    case .alreadyScheduled:
      break
    }
  }

  /// Releases what was signaled too soon, unless a trigger since then has reported it. A trigger that was
  /// released in the meantime moves the moment a later signal is due, so the look is taken again from there.
  private func releaseLate() {
    let now = DispatchTime.now().uptimeNanoseconds
    let release = state.withLock { state -> Release in
      state.lateReleaseScheduled = false
      guard state.pending.signaled, !state.finished else {
        return .alreadyScheduled
      }
      return release(&state, now: now)
    }
    perform(release)
  }

  fileprivate func takePending() -> Pending {
    state.withLock { state in
      defer { state.pending = Pending() }
      return state.pending
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(base: stream.makeAsyncIterator(), source: self)
  }

  struct AsyncIterator: nonisolated AsyncIteratorProtocol {
    var base: AsyncStream<Void>.Iterator
    let source: LazyFrameTriggers

    init(base: AsyncStream<Void>.Iterator, source: LazyFrameTriggers) {
      self.base = base
      self.source = source
    }

    mutating func next() async -> FrameTrigger? {
      while await base.next() != nil {
        let pending = source.takePending()
        // A release whose signals the previous trigger already reported has nothing to push.
        guard pending.signaled else {
          continue
        }
        return FrameTrigger(forceKeyFrame: pending.keyFrame, overran: false, overlayOnly: !pending.frameRendered)
      }
      return nil
    }
  }
}
