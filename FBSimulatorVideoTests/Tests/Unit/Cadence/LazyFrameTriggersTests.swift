/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
@testable import FBSimulatorVideo
import XCTest

/// How the lazy cadence paces the triggers its signals produce. Timed where the pacing happens, as
/// each trigger is handed out, so the push work that follows a trigger does not blur the interval.
final class LazyFrameTriggersTests: XCTestCase {

  // The pacing waits on the uptime clock, which is what `SuspendingClock` reads.
  private let clock = SuspendingClock()

  func testAFirstSignalIsNotHeld() async throws {
    let triggers = LazyFrameTriggers(maximumFramesPerSecond: 10)
    var iterator = triggers.makeAsyncIterator()
    triggers.signalFrameRendered()

    let started = clock.now
    let next = await iterator.next()

    XCTAssertNotNil(next)
    // Well inside the 100 ms interval.
    XCTAssertLessThan(clock.now - started, .milliseconds(50))
  }

  func testASignalSoonerThanTheIntervalIsHeldUntilTheIntervalHasPassed() async throws {
    let triggers = LazyFrameTriggers(maximumFramesPerSecond: 10)
    var iterator = triggers.makeAsyncIterator()
    triggers.signalFrameRendered()
    _ = await iterator.next()
    let first = clock.now

    triggers.signalFrameRendered()
    let next = await iterator.next()

    XCTAssertNotNil(next, "a held signal is still delivered")
    // `first` is read just after the iterator recorded the trigger, so the gap measured from it
    // can fall short of the interval by that instant; a millisecond covers it.
    XCTAssertGreaterThanOrEqual(clock.now - first, .milliseconds(99))
  }

  func testASignalThatComesAlmostAnIntervalAfterTheLastIsNotHeld() async throws {
    // A display that presents at the pace is never exactly on it. A frame that is a little early must be pushed
    // when it is presented, not held until the pacer's own deadline.
    let triggers = LazyFrameTriggers(maximumFramesPerSecond: 2)
    var iterator = triggers.makeAsyncIterator()
    triggers.signalFrameRendered()
    _ = await iterator.next()
    // 400 ms into a 500 ms interval: within the quarter of an interval a signal may be early by.
    try await Task.sleep(for: .milliseconds(400))

    triggers.signalFrameRendered()
    let started = clock.now
    let next = await iterator.next()

    XCTAssertNotNil(next)
    // Held, it would wait for the 625 ms mark: 225 ms more.
    XCTAssertLessThan(clock.now - started, .milliseconds(100))
  }

  func testAnEarlySignalIsReportedByTheOneThatIsDue() async throws {
    // A Simulator that presents twice within one interval: the second frame is too soon to push, and the frame
    // after it is on time. That one is pushed when it comes, and nothing is pushed for the early one afterwards.
    // A one-second interval, so that a sleep that overruns by a few hundred milliseconds changes nothing: a
    // signal is early before 750 ms, due from then on, and an early one is released late at 1250 ms.
    let triggers = LazyFrameTriggers(maximumFramesPerSecond: 1)
    var iterator = triggers.makeAsyncIterator()
    triggers.signalFrameRendered()
    _ = await iterator.next()
    let first = clock.now

    try await Task.sleep(for: .milliseconds(100))
    triggers.signalFrameRendered()
    try await clock.sleep(until: first + .milliseconds(850))
    triggers.signalFrameRendered()
    let due = await iterator.next()
    let dueAfter = clock.now - first

    XCTAssertEqual(due?.overlayOnly, false)
    XCTAssertLessThan(dueAfter, .milliseconds(1200), "the frame that is due is pushed when it comes, not at the early one's late release")
    // The early signal's late release, at 1250 ms, finds nothing left to report.
    try await clock.sleep(until: first + .milliseconds(1450))
    triggers.finish()
    let afterFinish = await iterator.next()
    XCTAssertNil(afterFinish, "the early signal must not produce a trigger of its own")
  }

  func testAnEarlySignalWithNothingAfterItIsStillReleased() async throws {
    // Half-second intervals: a signal is early before 375 ms and is then released at 625 ms.
    let triggers = LazyFrameTriggers(maximumFramesPerSecond: 2)
    var iterator = triggers.makeAsyncIterator()
    triggers.signalFrameRendered()
    _ = await iterator.next()
    let first = clock.now

    try await Task.sleep(for: .milliseconds(50))
    triggers.signalFrameRendered()
    let late = await iterator.next()

    XCTAssertEqual(late?.overlayOnly, false, "the last frame of a burst must be pushed even though it came too soon")
    XCTAssertGreaterThanOrEqual(clock.now - first, .milliseconds(600))
    XCTAssertLessThan(clock.now - first, .milliseconds(900))
  }

  func testSignalsWithinOneIntervalCoalesceIntoOneTrigger() async throws {
    let triggers = LazyFrameTriggers(maximumFramesPerSecond: 10)
    var iterator = triggers.makeAsyncIterator()
    triggers.signalFrameRendered()
    _ = await iterator.next()

    triggers.signalFrameRendered()
    triggers.signalFrameRendered()
    triggers.signalFrameRendered()
    let held = await iterator.next()
    // A finished stream still hands out whatever it buffered before ending.
    triggers.finish()
    let afterFinish = await iterator.next()

    XCTAssertNotNil(held)
    XCTAssertNil(afterFinish, "three signals within one interval must produce one trigger")
  }

  func testASignalAfterTheIntervalIsNotHeld() async throws {
    let triggers = LazyFrameTriggers(maximumFramesPerSecond: 10)
    var iterator = triggers.makeAsyncIterator()
    triggers.signalFrameRendered()
    _ = await iterator.next()
    try await Task.sleep(for: .milliseconds(150))

    triggers.signalFrameRendered()
    let started = clock.now
    _ = await iterator.next()

    XCTAssertLessThan(clock.now - started, .milliseconds(50))
  }

  func testATriggerIsOverlayOnlyUnlessAFrameWasRenderedSinceThePreviousOne() async throws {
    let triggers = LazyFrameTriggers(maximumFramesPerSecond: 1000)
    var iterator = triggers.makeAsyncIterator()

    triggers.signalOverlayChanged()
    triggers.signalFrameRendered()
    let coalesced = await iterator.next()
    triggers.signalKeyFrame()
    let swap = await iterator.next()

    XCTAssertEqual(coalesced?.overlayOnly, false, "a rendered frame coalesced with an overlay change is not overlay-only")
    XCTAssertEqual(swap?.overlayOnly, true)
    XCTAssertEqual(swap?.forceKeyFrame, true)
  }
}
