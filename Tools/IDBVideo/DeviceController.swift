/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import IDBGRPCSwift

/// A button drawn beside the picture for the mouse to press: one on the device's body, or one of
/// the viewer's own.
enum DeviceButton: Equatable, Sendable, CaseIterable {
  case home, volumeUp, volumeDown, lock
  /// Not the device's: switches the picture between the screen's rounded corners and the whole
  /// rectangle of the frame.
  case corners

  var label: String {
    switch self {
    case .home: return "Home"
    case .volumeUp: return "Vol +"
    case .volumeDown: return "Vol -"
    case .lock: return "Lock"
    case .corners: return "Round"
    }
  }

  /// The button it presses on the device; nil for one of the viewer's own.
  var hidButton: Idb_HIDEvent.HIDButtonType? {
    switch self {
    case .home: return .home
    case .volumeUp: return .volumeUp
    case .volumeDown: return .volumeDown
    case .lock: return .lock
    case .corners: return nil
    }
  }
}

/// Where the buttons drawn beside the picture belong, from where they are on the device's body as
/// the companion tells it: how far down the screen the middle of each is, as a fraction of the
/// screen's height. nil for one the body does not have on a side.
struct DeviceBodyButtons: Equatable, Sendable {
  var volumeMiddle: Double?
  var lockMiddle: Double?
  /// The radius of the screen's corners as a fraction of the screen's width; nil for square ones.
  var cornerRadius: Double?

  init(volumeMiddle: Double? = nil, lockMiddle: Double? = nil, cornerRadius: Double? = nil) {
    self.volumeMiddle = volumeMiddle
    self.lockMiddle = lockMiddle
    self.cornerRadius = cornerRadius
  }

  init(chrome: Idb_DeviceChromeResponse) {
    let height = chrome.screenHeightPoints
    let sides = chrome.buttons.filter { $0.edge == .left || $0.edge == .right }
    func middle(of names: Set<String>) -> Double? {
      let named = sides.filter { names.contains($0.name) }
      guard height > 0, let top = named.map(\.start).min(), let bottom = named.map({ $0.start + $0.length }).max() else {
        return nil
      }
      return min(max((top + bottom) / 2 / height, 0), 1)
    }
    // The two volume buttons are drawn as one, in the middle of the pair.
    volumeMiddle = middle(of: ["volume-up", "volume-down"])
    lockMiddle = middle(of: ["power"]) ?? middle(of: ["side-button"])
    if chrome.screenCornerRadius > 0, chrome.screenWidthPoints > 0 {
      cornerRadius = min(chrome.screenCornerRadius / chrome.screenWidthPoints, 0.5)
    }
  }
}

/// Where the picture is in the terminal and what it shows, for telling which point of the device's
/// screen the mouse is over.
struct PictureGeometry: Equatable, Sendable {
  /// Where a drawn button is, in the unit of the picture's own position.
  struct ButtonArea: Equatable, Sendable {
    var button: DeviceButton
    var x: Double
    var y: Double
    var width: Double
    var height: Double
  }

  /// The picture's top left corner and size, in the terminal's pixels, or in cells for a terminal
  /// that does not say how many pixels it has.
  var originX: Double
  var originY: Double
  var width: Double
  var height: Double
  /// One cell, in the same unit.
  var cellWidth: Double
  var cellHeight: Double
  /// The frame the picture shows, in the device's pixels.
  var sourceWidth: Int
  var sourceHeight: Int
  /// The buttons drawn beside the picture.
  var buttons: [ButtonArea] = []

  /// A mouse position in the unit the picture's own position is in.
  private func location(of position: TerminalMousePosition) -> (x: Double, y: Double) {
    switch position {
    case let .pixels(pixelX, pixelY):
      return (Double(pixelX), Double(pixelY))
    case let .cell(column, row):
      // The middle of the cell, which is all a cell report says about where in it the pointer is.
      return ((Double(column) - 0.5) * cellWidth, (Double(row) - 0.5) * cellHeight)
    }
  }

  /// A mouse position as a fraction of the picture: from 0 to 1 each way while it is on the picture.
  func fraction(at position: TerminalMousePosition) -> (x: Double, y: Double) {
    let location = location(of: position)
    return ((location.x - originX) / width, (location.y - originY) / height)
  }

  /// The drawn button under a mouse position, if there is one.
  func button(at position: TerminalMousePosition) -> DeviceButton? {
    let location = location(of: position)
    return buttons.first { area in
      (area.x..<(area.x + area.width)).contains(location.x) && (area.y..<(area.y + area.height)).contains(location.y)
    }?.button
  }
}

/// Turns what the person does in the terminal into input on the device: the mouse is a finger on
/// the screen, the wheel or trackpad scrolls, a right click is the Home button, the buttons drawn
/// beside the picture are the ones on the device's body, and what is typed is typed on the
/// device's hardware keyboard.
///
/// Input goes to the companion on a `hid` call that is opened when the person starts doing
/// something and closed once they have done nothing for a second. The companion gives a call the
/// device's input to itself for as long as it is open, so one held open for the whole session
/// would keep everything else that drives the device waiting. One per gesture would be the other
/// extreme, and too slow: the companion ends every call with a wait of a fifth of a second for the
/// device to take its events in, which the next call queues behind, so a double tap or a burst of
/// typing would arrive late. A call that spans a burst of input has neither problem.
///
/// @unchecked Sendable: all state is confined to `queue`.
final class DeviceController: @unchecked Sendable {
  /// Sends one call's events to the companion as they come, returning once the call has ended.
  typealias Send = @Sendable (AsyncStream<Idb_HIDEvent>) async throws -> Void

  /// An open call to the companion.
  private struct Call {
    let id: Int
    let events: AsyncStream<Idb_HIDEvent>.Continuation
  }

  /// A point on the device's screen, in points.
  struct Point: Equatable, Sendable {
    var x: Double
    var y: Double
  }

  private enum GestureKind {
    /// The mouse button is down.
    case touch
    /// The wheel is turning; the finger comes up when it stops.
    case scroll
  }

  private struct Gesture {
    let kind: GestureKind
    /// Where the finger is, as last sent.
    var point: Point
    /// Where it has moved to since, not sent yet.
    var pending: Point?
    var lastMoveAt: UInt64
  }

  /// How long the call to the companion stays open after the last input, by default. Other things
  /// that drive the device wait this long at most once the person stops.
  static let defaultCallIdleDelay: DispatchTimeInterval = .seconds(1)
  /// A finger's moves are sent at most this often. A mouse reports far more positions than the
  /// device samples a touch.
  private static let moveIntervalNanos: UInt64 = 8_000_000
  /// How long after the last step of the wheel the finger comes up. Long enough to span the gaps
  /// in a trackpad's coasting, so the scroll ends at rest rather than as a flick.
  private static let scrollEndDelay: DispatchTimeInterval = .milliseconds(150)
  /// Steps of the wheel that must come within `scrollStartWindowNanos` before the finger goes
  /// down. A touch that moves less than a tap's slop is a tap on whatever is under the pointer.
  private static let scrollStartSteps = 2
  private static let scrollStartWindowNanos: UInt64 = 200_000_000
  /// How close to the edge of the screen a scrolling finger goes before it is lifted and put down
  /// again under the pointer.
  private static let scrollEdgeMargin = 2.0

  private let geometry: @Sendable () -> PictureGeometry?
  private let buttonChanged: @Sendable (DeviceButton, Bool) -> Void
  private let callIdleDelay: DispatchTimeInterval
  private let queue = DispatchQueue(label: "idb-video.control", qos: .userInteractive)
  private let calls: AsyncStream<(id: Int, events: AsyncStream<Idb_HIDEvent>)>
  private let callsContinuation: AsyncStream<(id: Int, events: AsyncStream<Idb_HIDEvent>)>.Continuation

  // queue
  private var screen: (width: Double, height: Double)?
  private var call: Call?
  private var lastCallID = 0
  private var callEnd: DispatchWorkItem?
  private var gesture: Gesture?
  /// The drawn button the mouse is holding down.
  private var heldButton: DeviceButton?
  private var moveFlush: DispatchWorkItem?
  private var scrollEnd: DispatchWorkItem?
  private var scrollBacklog: (dx: Int, dy: Int, since: UInt64)?
  private var failures = 0

  /// `geometry` says where the picture is in the terminal right now, nil before the first frame.
  /// `buttonChanged` is told when a drawn button goes down and when it comes up, to show it so.
  init(
    geometry: @escaping @Sendable () -> PictureGeometry?,
    callIdleDelay: DispatchTimeInterval = DeviceController.defaultCallIdleDelay,
    buttonChanged: @escaping @Sendable (DeviceButton, Bool) -> Void = { _, _ in }
  ) {
    self.geometry = geometry
    self.buttonChanged = buttonChanged
    self.callIdleDelay = callIdleDelay
    (calls, callsContinuation) = AsyncStream.makeStream()
  }

  /// The size of the device's screen in points, upright. Nothing is sent before it is known.
  func setScreen(widthPoints: Double, heightPoints: Double) {
    queue.async {
      self.screen = (widthPoints, heightPoints)
      // A call with nothing in it: the companion sets up its connection to the device's input on
      // the first call it gets, which takes it half a second that the first tap need not wait for.
      self.send([])
    }
  }

  func handle(_ events: [TerminalInputEvent]) {
    queue.async {
      for event in events {
        self.handle(event)
      }
    }
  }

  /// Makes the calls to the companion, one after another, until `finish`.
  func run(send: Send) async {
    for await call in calls {
      do {
        try await send(call.events)
      } catch {
        failed(call.id, error)
      }
    }
  }

  /// Lifts a finger that is down and ends `run`.
  func finish() {
    queue.sync {
      endGesture()
      releaseButton()
      endCall()
      callsContinuation.finish()
    }
  }

  /// The companion ended a call with an error. What was sent on it since is lost, and a finger it
  /// held down the companion has lifted.
  private func failed(_ id: Int, _ error: any Error) {
    queue.async {
      if self.call?.id == id {
        self.call = nil
        self.gesture = nil
        if let button = self.heldButton {
          self.heldButton = nil
          self.buttonChanged(button, false)
        }
        self.moveFlush?.cancel()
        self.moveFlush = nil
        self.scrollEnd?.cancel()
        self.scrollEnd = nil
      }
      self.failures += 1
      // Without end, a companion that refuses every event would fill the terminal.
      if self.failures <= 3 {
        log("the companion did not take the input: \(error)")
      }
    }
  }

  // MARK: Events (queue)

  private func handle(_ event: TerminalInputEvent) {
    switch event {
    case let .press(.left, position):
      endGesture()
      releaseButton()
      if let button = geometry()?.button(at: position) {
        // Held for as long as the mouse button is, as a finger would hold it.
        heldButton = button
        buttonChanged(button, true)
        if let hidButton = button.hidButton {
          send([Self.button(hidButton, .down)])
        }
      } else if let (point, inside) = devicePoint(at: position), inside {
        beginGesture(.touch, at: point)
      }
    case let .drag(.left, position):
      if gesture?.kind == .touch, let (point, _) = devicePoint(at: position) {
        move(to: point)
      }
    case let .release(.left, position):
      if heldButton != nil {
        releaseButton()
      } else if gesture?.kind == .touch {
        endGesture(at: devicePoint(at: position)?.point)
      }
    case let .press(.right, position):
      endGesture()
      if let (_, inside) = devicePoint(at: position), inside {
        send([Self.button(.home, .down), Self.button(.home, .up)])
      }
    case let .scroll(dx, dy, position):
      scroll(dx: dx, dy: dy, at: position)
    case let .text(text):
      endGesture()
      send([.with { $0.text = .with { $0.text = text } }])
    case let .key(key):
      endGesture()
      send([Self.key(key, .down), Self.key(key, .up)])
    case .press, .drag, .release, .modeReport:
      break
    }
  }

  /// The point of the device's screen under a mouse position, held to the screen, and whether the
  /// position is on the picture. nil until there is a picture and the screen's size is known.
  private func devicePoint(at position: TerminalMousePosition) -> (point: Point, inside: Bool)? {
    guard let geometry = geometry(), let screen = orientedScreen(for: geometry) else {
      return nil
    }
    let fraction = geometry.fraction(at: position)
    let inside = (0...1).contains(fraction.x) && (0...1).contains(fraction.y)
    return (Point(x: min(max(fraction.x, 0), 1) * screen.width, y: min(max(fraction.y, 0), 1) * screen.height), inside)
  }

  /// The screen's size in points as the picture shows it. The companion reports the screen
  /// upright; a frame wider than it is tall shows it turned.
  private func orientedScreen(for geometry: PictureGeometry) -> (width: Double, height: Double)? {
    guard let screen else {
      return nil
    }
    let frameIsWide = geometry.sourceWidth > geometry.sourceHeight
    return frameIsWide == (screen.width > screen.height) ? screen : (screen.height, screen.width)
  }

  // MARK: Gestures (queue)

  // MARK: The call to the companion (queue)

  /// Sends events on the open call, opening one if there is none, and keeps it open a while longer.
  private func send(_ events: [Idb_HIDEvent]) {
    if call == nil {
      let (stream, continuation) = AsyncStream<Idb_HIDEvent>.makeStream()
      lastCallID += 1
      call = Call(id: lastCallID, events: continuation)
      callsContinuation.yield((lastCallID, stream))
    }
    for event in events {
      call?.events.yield(event)
    }
    callEnd?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.callEnd = nil
      // A finger that is down, or a button held, keeps the call open for as long as it lasts; its
      // lifting is sent through here and starts the wait again.
      if self.gesture == nil, self.heldButton == nil {
        self.endCall()
      }
    }
    callEnd = work
    queue.asyncAfter(deadline: .now() + callIdleDelay, execute: work)
  }

  private func endCall() {
    callEnd?.cancel()
    callEnd = nil
    call?.events.finish()
    call = nil
  }

  private func releaseButton() {
    if let button = heldButton {
      heldButton = nil
      buttonChanged(button, false)
      if let hidButton = button.hidButton {
        send([Self.button(hidButton, .up)])
      }
    }
  }

  private func beginGesture(_ kind: GestureKind, at point: Point) {
    gesture = Gesture(kind: kind, point: point, pending: nil, lastMoveAt: DispatchTime.now().uptimeNanoseconds)
    send([Self.touch(.down, point)])
  }

  private func move(to point: Point) {
    guard var current = gesture else {
      return
    }
    current.pending = point
    gesture = current
    let now = DispatchTime.now().uptimeNanoseconds
    let due = current.lastMoveAt + Self.moveIntervalNanos
    if now >= due {
      flushMove()
    } else if moveFlush == nil {
      let work = DispatchWorkItem { [weak self] in
        self?.moveFlush = nil
        self?.flushMove()
      }
      moveFlush = work
      queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due), execute: work)
    }
  }

  private func flushMove() {
    guard var current = gesture, let point = current.pending else {
      return
    }
    current.pending = nil
    let moved = point != current.point
    if moved {
      current.point = point
      current.lastMoveAt = DispatchTime.now().uptimeNanoseconds
    }
    gesture = current
    if moved {
      // The device reads a finger that is down somewhere new as having moved there.
      send([Self.touch(.down, point)])
    }
  }

  /// Lifts the finger, at `point` if given.
  private func endGesture(at point: Point? = nil) {
    moveFlush?.cancel()
    moveFlush = nil
    scrollEnd?.cancel()
    scrollEnd = nil
    scrollBacklog = nil
    guard gesture != nil else {
      return
    }
    if let point {
      gesture?.pending = point
    }
    flushMove()
    if let current = gesture {
      gesture = nil
      send([Self.touch(.up, current.point)])
    }
  }

  /// A step of the wheel moves a finger by one line of the terminal, the way the terminal's own
  /// text would move, so the device's content follows the fingers on a trackpad as that text does.
  private func scroll(dx: Int, dy: Int, at position: TerminalMousePosition) {
    guard gesture?.kind != .touch, let geometry = geometry(), let screen = orientedScreen(for: geometry),
      let (pointer, inside) = devicePoint(at: position)
    else {
      return
    }
    let step = geometry.cellHeight / geometry.height * screen.height
    var steps = (dx: dx, dy: dy)
    if gesture == nil {
      guard inside else {
        return
      }
      let now = DispatchTime.now().uptimeNanoseconds
      if let backlog = scrollBacklog, now - backlog.since < Self.scrollStartWindowNanos {
        steps = (backlog.dx + dx, backlog.dy + dy)
        scrollBacklog = (steps.dx, steps.dy, backlog.since)
      } else {
        scrollBacklog = (dx, dy, now)
      }
      guard abs(steps.dx) + abs(steps.dy) >= Self.scrollStartSteps else {
        return
      }
      scrollBacklog = nil
      beginGesture(.scroll, at: pointer)
    }
    guard let current = gesture else {
      return
    }
    // The wheel turning up moves the content down, as a finger moving down does.
    let from = current.pending ?? current.point
    var target = Point(x: from.x - Double(steps.dx) * step, y: from.y - Double(steps.dy) * step)
    let bounds = (x: Self.scrollEdgeMargin...(screen.width - Self.scrollEdgeMargin), y: Self.scrollEdgeMargin...(screen.height - Self.scrollEdgeMargin))
    if !bounds.x.contains(target.x) || !bounds.y.contains(target.y) {
      // The finger has run out of screen: lift it and carry on from under the pointer.
      endGesture()
      beginGesture(.scroll, at: pointer)
      target = Point(x: pointer.x - Double(steps.dx) * step, y: pointer.y - Double(steps.dy) * step)
      target.x = min(max(target.x, bounds.x.lowerBound), bounds.x.upperBound)
      target.y = min(max(target.y, bounds.y.lowerBound), bounds.y.upperBound)
    }
    move(to: target)
    scrollEnd?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.gesture?.kind == .scroll else { return }
      self.scrollEnd = nil
      self.endGesture()
    }
    scrollEnd = work
    queue.asyncAfter(deadline: .now() + Self.scrollEndDelay, execute: work)
  }

  // MARK: Events for the companion

  private static func touch(_ direction: Idb_HIDEvent.HIDDirection, _ point: Point) -> Idb_HIDEvent {
    .with {
      $0.press = .with {
        $0.direction = direction
        $0.action = .with {
          $0.touch = .with {
            $0.point = .with {
              $0.x = point.x
              $0.y = point.y
            }
          }
        }
      }
    }
  }

  private static func button(_ button: Idb_HIDEvent.HIDButtonType, _ direction: Idb_HIDEvent.HIDDirection) -> Idb_HIDEvent {
    .with {
      $0.press = .with {
        $0.direction = direction
        $0.action = .with { $0.button = .with { $0.button = button } }
      }
    }
  }

  private static func key(_ key: TerminalKey, _ direction: Idb_HIDEvent.HIDDirection) -> Idb_HIDEvent {
    .with {
      $0.press = .with {
        $0.direction = direction
        $0.action = .with { $0.key = .with { $0.keycode = keyCode(key) } }
      }
    }
  }

  /// The key's usage on the USB HID keyboard page, which is what the companion's key events carry.
  static func keyCode(_ key: TerminalKey) -> UInt64 {
    switch key {
    case .enter: return 0x28
    case .escape: return 0x29
    case .backspace: return 0x2A
    case .tab: return 0x2B
    case .home: return 0x4A
    case .pageUp: return 0x4B
    case .deleteForward: return 0x4C
    case .end: return 0x4D
    case .pageDown: return 0x4E
    case .right: return 0x4F
    case .left: return 0x50
    case .down: return 0x51
    case .up: return 0x52
    }
  }
}
