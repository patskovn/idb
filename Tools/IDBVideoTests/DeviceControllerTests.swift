/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import IDBGRPCSwift
import Testing

@testable import idb_video

/// What the companion is sent for what is done in the terminal, observed through a `send` that
/// records each call's events.
@Suite
struct DeviceControllerTests {

  /// The calls made to the companion and the events of each, as they arrive.
  private actor Recorder {
    private(set) var calls: [[Idb_HIDEvent]] = []

    func begin() -> Int {
      calls.append([])
      return calls.count - 1
    }

    func add(_ event: Idb_HIDEvent, to call: Int) {
      calls[call].append(event)
    }

    var events: [Idb_HIDEvent] { calls.flatMap { $0 } }
  }

  /// What the controller said of the drawn buttons, in order.
  private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [(DeviceButton, Bool)] = []

    func add(_ button: DeviceButton, _ pressed: Bool) {
      lock.withLock { changes.append((button, pressed)) }
    }

    var all: [(DeviceButton, Bool)] { lock.withLock { changes } }
  }

  /// A 402 by 874 point screen drawn pixel for pixel, 1206 by 2622, 209 pixels in from the left of a
  /// terminal of 14 by 28 pixel cells.
  private static let geometry = PictureGeometry(
    originX: 209, originY: 0, width: 1206, height: 2622, cellWidth: 14, cellHeight: 28, sourceWidth: 1206, sourceHeight: 2622)

  private struct Started {
    let controller: DeviceController
    let recorder: Recorder
    let running: Task<Void, Never>
  }

  private func start(geometry: PictureGeometry? = DeviceControllerTests.geometry, screen: (Double, Double)? = (402, 874), callIdleDelay: DispatchTimeInterval = .seconds(1)) -> Started {
    let controller = DeviceController(geometry: { geometry }, callIdleDelay: callIdleDelay)
    let recorder = Recorder()
    let running = Task {
      await controller.run { events in
        let call = await recorder.begin()
        for await event in events {
          await recorder.add(event, to: call)
        }
      }
    }
    if let screen {
      controller.setScreen(widthPoints: screen.0, heightPoints: screen.1)
    }
    return Started(controller: controller, recorder: recorder, running: running)
  }

  /// Waits until `count` events have been sent, or two seconds.
  private func events(_ started: Started, count: Int) async -> [Idb_HIDEvent] {
    for _ in 0..<200 {
      let events = await started.recorder.events
      if events.count >= count {
        return events
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await started.recorder.events
  }

  private func stop(_ started: Started) async {
    started.controller.finish()
    await started.running.value
  }

  private func touch(_ direction: Idb_HIDEvent.HIDDirection, _ x: Double, _ y: Double) -> Idb_HIDEvent {
    .with {
      $0.press = .with {
        $0.direction = direction
        $0.action = .with { $0.touch = .with { $0.point = .with { $0.x = x; $0.y = y } } }
      }
    }
  }

  private func isClose(_ event: Idb_HIDEvent, to expected: Idb_HIDEvent) -> Bool {
    event.press.direction == expected.press.direction && abs(event.press.action.touch.point.x - expected.press.action.touch.point.x) < 0.01
      && abs(event.press.action.touch.point.y - expected.press.action.touch.point.y) < 0.01
  }

  // MARK: - Touches

  @Test
  func aClickIsAFingerDownAndUpAtThePointUnderThePointer() async {
    let started = start()
    // 1017 pixels into the picture and 1272 down it, at three pixels a point.
    started.controller.handle([.press(.left, at: .pixels(x: 1226, y: 1272)), .release(.left, at: .pixels(x: 1226, y: 1272))])

    let events = await events(started, count: 2)

    #expect(events.count == 2)
    #expect(isClose(events[0], to: touch(.down, 339, 424)))
    #expect(isClose(events[1], to: touch(.up, 339, 424)))
    await stop(started)
  }

  @Test
  func aCellReportIsTheMiddleOfItsCell() async {
    let started = start()
    // Column 16 spans pixels 210 to 224 and row 2 pixels 28 to 56: the middle is 8 pixels into the picture, 42 down.
    started.controller.handle([.press(.left, at: .cell(column: 16, row: 2)), .release(.left, at: .cell(column: 16, row: 2))])

    let events = await events(started, count: 2)

    #expect(events.count == 2)
    #expect(isClose(events[0], to: touch(.down, 8.0 / 3, 14)))
    await stop(started)
  }

  @Test
  func aClickBesideThePictureIsNothing() async {
    let started = start()
    started.controller.handle([.press(.left, at: .pixels(x: 100, y: 500)), .release(.left, at: .pixels(x: 100, y: 500))])
    // Something that is sent, to wait on.
    started.controller.handle([.key(.enter)])

    let events = await events(started, count: 2)

    #expect(events.map(\.press.action.key.keycode) == [0x28, 0x28], "only the key press is sent")
    await stop(started)
  }

  @Test
  func aDragMovesTheFingerAndLiftsItWhereTheButtonCameUp() async throws {
    let started = start()
    started.controller.handle([.press(.left, at: .pixels(x: 809, y: 2100))])
    for step in 1...5 {
      started.controller.handle([.drag(.left, to: .pixels(x: 809, y: 2100 - step * 90))])
      try await Task.sleep(for: .milliseconds(12))
    }
    // The button comes up beside the picture: the finger stays on the screen's edge.
    started.controller.handle([.release(.left, at: .pixels(x: 2000, y: 1650))])

    let events = await events(started, count: 8)

    #expect(events.count == 8, "down, five moves, the move to where it lifts, up: \(events.count)")
    #expect(isClose(events[0], to: touch(.down, 200, 700)))
    #expect(isClose(events[5], to: touch(.down, 200, 550)), "a move is a finger down somewhere new")
    #expect(isClose(events[6], to: touch(.down, 402, 550)))
    #expect(isClose(events[7], to: touch(.up, 402, 550)))
    await stop(started)
  }

  @Test
  func movesThatComeFasterThanTheDeviceSamplesAreMerged() async {
    let started = start()
    var burst: [TerminalInputEvent] = [.press(.left, at: .pixels(x: 809, y: 2100))]
    burst += (1...50).map { .drag(.left, to: .pixels(x: 809, y: 2100 - $0 * 3)) }
    burst.append(.release(.left, at: .pixels(x: 809, y: 1950)))
    started.controller.handle(burst)

    let events = await events(started, count: 3)

    #expect(events.count < 10, "fifty positions at once are not fifty moves: \(events.count)")
    #expect(isClose(events[0], to: touch(.down, 200, 700)))
    #expect(isClose(events[events.count - 1], to: touch(.up, 200, 650)), "the finger still ends where the pointer did")
    await stop(started)
  }

  @Test
  func nothingIsSentBeforeTheScreenSizeIsKnown() async {
    let started = start(screen: nil)
    started.controller.handle([.press(.left, at: .pixels(x: 1226, y: 1272)), .release(.left, at: .pixels(x: 1226, y: 1272))])
    started.controller.setScreen(widthPoints: 402, heightPoints: 874)
    started.controller.handle([.press(.left, at: .pixels(x: 1226, y: 1272)), .release(.left, at: .pixels(x: 1226, y: 1272))])

    let events = await events(started, count: 2)

    #expect(events.count == 2, "only the click made once the screen was known")
    await stop(started)
  }

  @Test
  func aPictureOfTheScreenTurnedOnItsSideIsReadTurned() async {
    // The companion reports the screen upright; the frame is the interface as it is turned.
    let turned = PictureGeometry(originX: 0, originY: 0, width: 2622, height: 1206, cellWidth: 14, cellHeight: 28, sourceWidth: 2622, sourceHeight: 1206)
    let started = start(geometry: turned)
    started.controller.handle([.press(.left, at: .pixels(x: 1311, y: 603)), .release(.left, at: .pixels(x: 1311, y: 603))])

    let events = await events(started, count: 2)

    #expect(events.count == 2)
    #expect(isClose(events[0], to: touch(.down, 437, 201)))
    await stop(started)
  }

  // MARK: - The wheel

  @Test
  func oneStepOfTheWheelIsNotEnoughToTouchTheScreen() async throws {
    // A finger that goes down and moves less than a tap's slop is a tap on what is under the pointer.
    let started = start()
    started.controller.handle([.scroll(dx: 0, dy: 1, at: .pixels(x: 809, y: 1500))])
    try await Task.sleep(for: .milliseconds(300))

    let events = await started.recorder.events

    #expect(events.isEmpty)
    await stop(started)
  }

  @Test
  func theWheelTurningDownMovesAFingerUpALineAStepAndThenLiftsIt() async {
    let started = start()
    let pointer = TerminalMousePosition.pixels(x: 809, y: 1500)
    started.controller.handle([.scroll(dx: 0, dy: 1, at: pointer), .scroll(dx: 0, dy: 1, at: pointer), .scroll(dx: 0, dy: 1, at: pointer)])

    let events = await events(started, count: 3)

    #expect(isClose(events[0], to: touch(.down, 200, 500)), "the finger goes down under the pointer")
    // A line of the terminal is 28 pixels, and the picture has three pixels to a point.
    let lifted = events[events.count - 1]
    #expect(isClose(lifted, to: touch(.up, 200, 500 - 3 * 28.0 / 3)), "three lines up: \(lifted)")
    await stop(started)
  }

  @Test
  func theWheelTurningUpMovesTheFingerDown() async {
    let started = start()
    let pointer = TerminalMousePosition.pixels(x: 809, y: 1500)
    started.controller.handle([.scroll(dx: 0, dy: -1, at: pointer), .scroll(dx: 0, dy: -1, at: pointer)])

    let events = await events(started, count: 3)

    #expect(isClose(events[events.count - 1], to: touch(.up, 200, 500 + 2 * 28.0 / 3)))
    await stop(started)
  }

  // MARK: - Buttons and keys

  @Test
  func aRightClickOnThePictureIsTheHomeButton() async {
    let started = start()
    started.controller.handle([.press(.right, at: .pixels(x: 809, y: 1200)), .release(.right, at: .pixels(x: 809, y: 1200))])

    let events = await events(started, count: 2)

    #expect(events.map(\.press.action.button.button) == [.home, .home])
    #expect(events.map(\.press.direction) == [.down, .up])
    await stop(started)
  }

  @Test
  func whatIsTypedIsSentAsText() async {
    let started = start()
    started.controller.handle([.text("wallpaper")])

    let events = await events(started, count: 1)

    #expect(events.map(\.text.text) == ["wallpaper"])
    await stop(started)
  }

  @Test
  func aKeyIsPressedAndReleasedByItsUsage() async {
    let started = start()
    started.controller.handle([.key(.backspace), .key(.left)])

    let events = await events(started, count: 4)

    #expect(events.map(\.press.action.key.keycode) == [0x2A, 0x2A, 0x50, 0x50])
    #expect(events.map(\.press.direction) == [.down, .up, .down, .up])
    await stop(started)
  }

  @Test
  func aDrawnButtonIsHeldForAsLongAsTheMouseButtonIs() async throws {
    // The lock button drawn right of the picture, seven cells wide and three high.
    var geometry = DeviceControllerTests.geometry
    geometry.buttons = [PictureGeometry.ButtonArea(button: .lock, x: 1442, y: 420, width: 98, height: 84)]
    let started = start(geometry: geometry, callIdleDelay: .milliseconds(60))
    started.controller.handle([.press(.left, at: .pixels(x: 1500, y: 450))])
    // Held far longer than a call stays open with nothing happening, as to turn the device off.
    try await Task.sleep(for: .milliseconds(300))
    started.controller.handle([.release(.left, at: .pixels(x: 1700, y: 900))])

    let events = await events(started, count: 2)
    let calls = await started.recorder.calls

    #expect(events.map(\.press.action.button.button) == [.lock, .lock])
    #expect(events.map(\.press.direction) == [.down, .up], "it comes up wherever the mouse button does")
    #expect(calls.count == 1, "the held button keeps the call open")
    await stop(started)
  }

  @Test
  func everyDrawnButtonPressesItsOwn() async {
    var geometry = DeviceControllerTests.geometry
    let deviceButtons = DeviceButton.allCases.filter { $0.hidButton != nil }
    geometry.buttons = deviceButtons.enumerated().map { index, button in
      PictureGeometry.ButtonArea(button: button, x: 1442, y: Double(index) * 100, width: 98, height: 84)
    }
    let started = start(geometry: geometry)
    for index in deviceButtons.indices {
      started.controller.handle([.press(.left, at: .pixels(x: 1450, y: index * 100 + 10)), .release(.left, at: .pixels(x: 1450, y: index * 100 + 10))])
    }

    let events = await events(started, count: 8)

    #expect(events.map(\.press.action.button.button) == [.home, .home, .volumeUp, .volumeUp, .volumeDown, .volumeDown, .lock, .lock])
    await stop(started)
  }

  @Test
  func theViewerSOwnButtonIsToldButSendsTheDeviceNothing() async {
    var withButton = DeviceControllerTests.geometry
    withButton.buttons = [PictureGeometry.ButtonArea(button: .corners, x: 1340, y: 2626, width: 76, height: 76)]
    let geometry = withButton
    let changes = Changes()
    let controller = DeviceController(geometry: { geometry }, buttonChanged: { button, pressed in changes.add(button, pressed) })
    let recorder = Recorder()
    let running = Task {
      await controller.run { events in
        let call = await recorder.begin()
        for await event in events {
          await recorder.add(event, to: call)
        }
      }
    }
    let started = Started(controller: controller, recorder: recorder, running: running)
    controller.setScreen(widthPoints: 402, heightPoints: 874)
    controller.handle([.press(.left, at: .pixels(x: 1370, y: 2660)), .release(.left, at: .pixels(x: 1370, y: 2660))])
    controller.handle([.key(.enter)])

    let events = await events(started, count: 2)

    #expect(events.map(\.press.action.key.keycode) == [0x28, 0x28], "only the key press reaches the device")
    #expect(changes.all.map(\.0) == [.corners, .corners])
    #expect(changes.all.map(\.1) == [true, false])
    await stop(started)
  }

  @Test
  func theScreenSCornerRadiusIsKeptAsAFractionOfItsWidth() {
    var response = chrome([("power", .right, 245, 101)])
    response.screenWidthPoints = 402
    response.screenCornerRadius = 62
    #expect(DeviceBodyButtons(chrome: response).cornerRadius == 62.0 / 402)

    response.screenCornerRadius = 0
    #expect(DeviceBodyButtons(chrome: response).cornerRadius == nil, "a screen with square corners has none to show")
  }

  @Test
  func aClickBetweenTheButtonsIsNothing() async {
    var geometry = DeviceControllerTests.geometry
    geometry.buttons = [PictureGeometry.ButtonArea(button: .lock, x: 1442, y: 420, width: 98, height: 84)]
    let started = start(geometry: geometry)
    started.controller.handle([.press(.left, at: .pixels(x: 1500, y: 510)), .release(.left, at: .pixels(x: 1500, y: 510))])
    started.controller.handle([.key(.enter)])

    let events = await events(started, count: 2)

    #expect(events.map(\.press.action.key.keycode) == [0x28, 0x28], "only the key press is sent")
    await stop(started)
  }

  // MARK: - Where the buttons are on the body

  private func chrome(_ buttons: [(String, Idb_DeviceChromeResponse.Edge, Double, Double)], height: Double = 874) -> Idb_DeviceChromeResponse {
    .with {
      $0.screenHeightPoints = height
      $0.buttons = buttons.map { button in
        .with {
          $0.name = button.0
          $0.edge = button.1
          $0.start = button.2
          $0.length = button.3
        }
      }
    }
  }

  @Test
  func theVolumeCapsuleBelongsInTheMiddleOfTheTwoVolumeButtons() {
    // A phone's: up from 204 to 268 points down the screen, down from 283 to 347.
    let buttons = DeviceBodyButtons(
      chrome: chrome([("action", .left, 143, 34), ("volume-up", .left, 204, 64), ("volume-down", .left, 283, 64), ("power", .right, 245, 101)]))

    #expect(abs((buttons.volumeMiddle ?? 0) - 275.5 / 874) < 0.0001)
    #expect(abs((buttons.lockMiddle ?? 0) - 295.5 / 874) < 0.0001)
  }

  @Test
  func aButtonTheBodyHasNotOnASideHasNoPlace() {
    // A tablet with its power button on top, and a body with no volume buttons at all.
    let buttons = DeviceBodyButtons(chrome: chrome([("power", .top, 600, 70), ("home", .bottom, 354, 60)]))

    #expect(buttons.volumeMiddle == nil)
    #expect(buttons.lockMiddle == nil)
  }

  @Test
  func aWatchSSideButtonIsItsLockButton() {
    let buttons = DeviceBodyButtons(chrome: chrome([("digital-crown", .right, 60, 40), ("side-button", .right, 140, 60)], height: 240))

    #expect(buttons.lockMiddle == 170.0 / 240)
  }

  // MARK: - Calls

  @Test
  func inputThatFollowsCloselyGoesOnTheSameCall() async {
    let started = start()
    started.controller.handle([.key(.enter)])
    started.controller.handle([.text("a")])
    _ = await events(started, count: 3)

    let calls = await started.recorder.calls

    #expect(calls.count == 1, "one call for the burst, the one opened when the screen size came")
    await stop(started)
  }

  @Test
  func theCallEndsOnceNothingHasBeenDoneForAWhileAndTheNextInputOpensAnother() async throws {
    let started = start(callIdleDelay: .milliseconds(60))
    started.controller.handle([.key(.enter)])
    _ = await events(started, count: 2)
    try await Task.sleep(for: .milliseconds(300))
    started.controller.handle([.key(.tab)])
    _ = await events(started, count: 4)

    let calls = await started.recorder.calls

    #expect(calls.count == 2)
    #expect(calls.last?.map(\.press.action.key.keycode) == [0x2B, 0x2B])
    await stop(started)
  }

  @Test
  func aFingerHeldDownKeepsTheCallOpen() async throws {
    let started = start(callIdleDelay: .milliseconds(60))
    started.controller.handle([.press(.left, at: .pixels(x: 809, y: 1200))])
    // A long press: far longer than the call stays open with nothing happening.
    try await Task.sleep(for: .milliseconds(300))
    started.controller.handle([.release(.left, at: .pixels(x: 809, y: 1200))])
    _ = await events(started, count: 2)

    let calls = await started.recorder.calls

    #expect(calls.count == 1)
    #expect(calls[0].map(\.press.direction) == [.down, .up])
    await stop(started)
  }
}
