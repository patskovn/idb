/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

/// Where the terminal says the mouse is.
enum TerminalMousePosition: Equatable, Sendable {
  /// In pixels from the top left of the terminal's cells (SGR-Pixels, mode 1016).
  case pixels(x: Int, y: Int)
  /// The cell under the pointer, counted from 1 (SGR, mode 1006).
  case cell(column: Int, row: Int)
}

enum TerminalMouseButton: Equatable, Sendable {
  case left, middle, right
}

/// A key that is not text.
enum TerminalKey: Equatable, Sendable {
  case enter, tab, backspace, escape, deleteForward
  case up, down, left, right
  case home, end, pageUp, pageDown
}

/// Something the person at the terminal did, or the terminal's answer to a question.
enum TerminalInputEvent: Equatable, Sendable {
  case press(TerminalMouseButton, at: TerminalMousePosition)
  /// The mouse moved with the button held.
  case drag(TerminalMouseButton, to: TerminalMousePosition)
  case release(TerminalMouseButton, at: TerminalMousePosition)
  /// One step of the wheel or trackpad: `dy` is -1 for up and 1 for down, `dx` -1 for left and 1 for right.
  case scroll(dx: Int, dy: Int, at: TerminalMousePosition)
  case text(String)
  case key(TerminalKey)
  /// Whether the terminal knows a private mode and can turn it on (its answer to DECRQM).
  case modeReport(mode: Int, supported: Bool)
}

/// Turns the bytes a terminal sends into input events: SGR mouse reports, keys and text.
///
/// The bytes arrive in pieces of any size, so a sequence that is cut short is kept until the rest
/// arrives. An escape byte on its own is either the Escape key or the start of a sequence whose rest
/// has not arrived yet; `flush` settles it once the terminal has been quiet for a moment.
struct TerminalInputParser {
  /// Whether mouse reports carry pixels (SGR-Pixels is on) or cells.
  var reportsPixels = false

  private var buffer: [UInt8] = []

  /// Whether bytes are held back that may be the start of a longer sequence.
  var hasPartialSequence: Bool { !buffer.isEmpty }

  mutating func consume(_ bytes: some Sequence<UInt8>) -> [TerminalInputEvent] {
    buffer.append(contentsOf: bytes)
    return parse(final: false)
  }

  /// What the held-back bytes mean when nothing follows them.
  mutating func flush() -> [TerminalInputEvent] {
    parse(final: true)
  }

  private enum Parsed {
    /// A whole sequence of `length` bytes, which may mean nothing to us.
    case complete(TerminalInputEvent?, length: Int)
    case incomplete
  }

  private mutating func parse(final: Bool) -> [TerminalInputEvent] {
    var events: [TerminalInputEvent] = []
    var text: [UInt8] = []
    func flushText() {
      if !text.isEmpty {
        events.append(.text(String(decoding: text, as: UTF8.self)))
        text.removeAll()
      }
    }
    var index = 0
    scan: while index < buffer.count {
      let byte = buffer[index]
      switch byte {
      case 0x1B:
        flushText()
        switch escapeSequence(at: index, final: final) {
        case let .complete(event, length):
          if let event {
            events.append(event)
          }
          index += length
        case .incomplete:
          break scan
        }
      case 0x0D, 0x0A:
        flushText()
        events.append(.key(.enter))
        index += 1
      case 0x09:
        flushText()
        events.append(.key(.tab))
        index += 1
      case 0x7F, 0x08:
        flushText()
        events.append(.key(.backspace))
        index += 1
      case 0x00..<0x20:
        // The other control characters: Ctrl with a letter, which the device has no use for.
        flushText()
        index += 1
      default:
        // A character, of one byte or of several that may not all be here yet.
        let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
        if index + length > buffer.count, !final {
          break scan
        }
        let end = min(index + length, buffer.count)
        text.append(contentsOf: buffer[index..<end])
        index = end
      }
    }
    flushText()
    buffer.removeFirst(index)
    // A sequence that never ends must not hold everything after it back for ever.
    if buffer.count > 4096 {
      buffer.removeAll()
    }
    return events
  }

  private func escapeSequence(at start: Int, final: Bool) -> Parsed {
    guard start + 1 < buffer.count else {
      // Nothing after the escape byte: the Escape key, if nothing follows.
      return final ? .complete(.key(.escape), length: 1) : .incomplete
    }
    switch buffer[start + 1] {
    case UInt8(ascii: "["):
      // CSI: parameter bytes, intermediate bytes, then one final byte.
      var index = start + 2
      while index < buffer.count, (0x30...0x3F).contains(buffer[index]) { index += 1 }
      let parametersEnd = index
      while index < buffer.count, (0x20...0x2F).contains(buffer[index]) { index += 1 }
      guard index < buffer.count else {
        return final ? .complete(nil, length: buffer.count - start) : .incomplete
      }
      let event = controlSequence(
        parameters: String(decoding: buffer[(start + 2)..<parametersEnd], as: UTF8.self),
        intermediates: String(decoding: buffer[parametersEnd..<index], as: UTF8.self),
        final: buffer[index])
      return .complete(event, length: index - start + 1)
    case UInt8(ascii: "O"):
      // SS3: how a terminal in application mode sends the arrow keys.
      guard start + 2 < buffer.count else {
        return final ? .complete(nil, length: 2) : .incomplete
      }
      return .complete(Self.cursorKey(buffer[start + 2]).map { .key($0) }, length: 3)
    case UInt8(ascii: "_"), UInt8(ascii: "P"), UInt8(ascii: "]"), UInt8(ascii: "^"), UInt8(ascii: "X"):
      // A string the terminal sends in answer to something: skipped up to its terminator.
      var index = start + 2
      while index < buffer.count {
        if buffer[index] == 0x07 {
          return .complete(nil, length: index - start + 1)
        }
        if buffer[index] == 0x1B, index + 1 < buffer.count, buffer[index + 1] == UInt8(ascii: "\\") {
          return .complete(nil, length: index - start + 2)
        }
        index += 1
      }
      return final ? .complete(nil, length: buffer.count - start) : .incomplete
    case 0x1B:
      // Escape, then another sequence.
      return .complete(.key(.escape), length: 1)
    default:
      // Escape before a character is how a terminal sends that character with Option held.
      return .complete(nil, length: 1)
    }
  }

  private func controlSequence(parameters: String, intermediates: String, final: UInt8) -> TerminalInputEvent? {
    switch (final, intermediates) {
    case (UInt8(ascii: "M"), ""), (UInt8(ascii: "m"), ""):
      guard parameters.hasPrefix("<") else {
        return nil
      }
      let numbers = parameters.dropFirst().split(separator: ";").compactMap { Int($0) }
      guard numbers.count == 3 else {
        return nil
      }
      return mouseReport(code: numbers[0], x: numbers[1], y: numbers[2], released: final == UInt8(ascii: "m"))
    case (UInt8(ascii: "y"), "$"):
      // DECRPM, `?mode;state`: 0 is a mode the terminal does not know, 4 one it can never turn on.
      guard parameters.hasPrefix("?") else {
        return nil
      }
      let numbers = parameters.dropFirst().split(separator: ";").compactMap { Int($0) }
      guard numbers.count == 2 else {
        return nil
      }
      return .modeReport(mode: numbers[0], supported: (1...3).contains(numbers[1]))
    case (UInt8(ascii: "~"), ""):
      switch parameters.split(separator: ";").first.flatMap({ Int($0) }) {
      case 1, 7: return .key(.home)
      case 3: return .key(.deleteForward)
      case 4, 8: return .key(.end)
      case 5: return .key(.pageUp)
      case 6: return .key(.pageDown)
      default: return nil
      }
    case (_, ""):
      return Self.cursorKey(final).map { .key($0) }
    default:
      return nil
    }
  }

  private static func cursorKey(_ final: UInt8) -> TerminalKey? {
    switch final {
    case UInt8(ascii: "A"): return .up
    case UInt8(ascii: "B"): return .down
    case UInt8(ascii: "C"): return .right
    case UInt8(ascii: "D"): return .left
    case UInt8(ascii: "H"): return .home
    case UInt8(ascii: "F"): return .end
    default: return nil
    }
  }

  /// An SGR mouse report. The code's low two bits are the button, 32 marks motion and 64 the wheel;
  /// the bits between are the modifier keys, which change nothing here.
  private func mouseReport(code: Int, x: Int, y: Int, released: Bool) -> TerminalInputEvent? {
    let position: TerminalMousePosition = reportsPixels ? .pixels(x: x, y: y) : .cell(column: x, row: y)
    if code & 64 != 0 {
      guard !released else {
        return nil
      }
      switch code & 3 {
      case 0: return .scroll(dx: 0, dy: -1, at: position)
      case 1: return .scroll(dx: 0, dy: 1, at: position)
      case 2: return .scroll(dx: -1, dy: 0, at: position)
      default: return .scroll(dx: 1, dy: 0, at: position)
      }
    }
    let button: TerminalMouseButton
    switch code & 3 {
    case 0: button = .left
    case 1: button = .middle
    case 2: button = .right
    default: return nil  // motion with no button held
    }
    if released {
      return .release(button, at: position)
    }
    return code & 32 != 0 ? .drag(button, to: position) : .press(button, at: position)
  }
}

/// Reads what the person does in the terminal: puts it in a mode where every key arrives at once
/// and unechoed, asks it to report the mouse, and hands on the events it parses.
///
/// Mouse positions are asked for in pixels where the terminal can report them (SGR-Pixels), which
/// is what makes a drag smooth; otherwise they come as cells. Ctrl-C still interrupts.
///
/// @unchecked Sendable: `parser` is touched only on the reader thread; everything else is set
/// before it starts.
final class TerminalInput: @unchecked Sendable {
  private static let pixelMouseMode = 1016

  private let write: @Sendable (String) -> Void
  private let handler: @Sendable ([TerminalInputEvent]) -> Void
  private var parser = TerminalInputParser()
  private var wakePipe: (read: Int32, write: Int32) = (-1, -1)
  private var thread: Thread?

  /// `write` sends a control sequence to the terminal; `handler` gets the events, on a thread of
  /// this object's own.
  init(write: @escaping @Sendable (String) -> Void, handler: @escaping @Sendable ([TerminalInputEvent]) -> Void) {
    self.write = write
    self.handler = handler
  }

  /// Returns false, having changed nothing, when stdin is not a terminal.
  func start() -> Bool {
    guard isatty(STDIN_FILENO) == 1, TerminalState.enterInputMode() else {
      return false
    }
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
      TerminalState.restore()
      return false
    }
    wakePipe = (descriptors[0], descriptors[1])
    // Presses, releases and motion while a button is held, in the SGR encoding; then ask whether
    // the terminal can report pixels.
    write("\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?\(Self.pixelMouseMode)$p")
    let thread = Thread { [self] in read() }
    thread.name = "idb-video.terminal-input"
    thread.qualityOfService = .userInteractive
    self.thread = thread
    thread.start()
    return true
  }

  func stop() {
    guard thread != nil else {
      return
    }
    thread = nil
    var byte: UInt8 = 0
    _ = Darwin.write(wakePipe.write, &byte, 1)
    TerminalState.restore()
  }

  private func read() {
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
      var descriptors = [
        pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wakePipe.read, events: Int16(POLLIN), revents: 0),
      ]
      // Bytes held back are waited on only briefly: an escape byte with nothing after it is the Escape key.
      let ready = poll(&descriptors, 2, parser.hasPartialSequence ? 50 : -1)
      if ready < 0 {
        if errno == EINTR { continue }
        return
      }
      if descriptors[1].revents != 0 {
        return
      }
      var events: [TerminalInputEvent]
      if ready == 0 {
        events = parser.flush()
      } else {
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          return
        }
        events = parser.consume(bytes[..<count])
      }
      // The terminal's answer about pixel reports is acted on here and goes no further.
      events.removeAll { event in
        guard case let .modeReport(mode, supported) = event else {
          return false
        }
        if mode == Self.pixelMouseMode, supported, !parser.reportsPixels {
          parser.reportsPixels = true
          write("\u{1b}[?\(Self.pixelMouseMode)h")
        }
        return true
      }
      if !events.isEmpty {
        handler(events)
      }
    }
  }
}

/// The terminal's settings as they were, and their restoration however the process ends.
private enum TerminalState {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var saved: termios?
  nonisolated(unsafe) private static var registered = false
  /// `_POSIX_VDISABLE`, a macro Swift cannot import: the value that turns a control character off.
  private static let disabledCharacter: UInt8 = 0xFF

  /// Every key at once and unechoed. Ctrl-C keeps interrupting; Ctrl-Z arrives as a key, because a
  /// stopped process would leave the terminal reporting the mouse to a shell.
  static func enterInputMode() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    var settings = termios()
    guard tcgetattr(STDIN_FILENO, &settings) == 0 else {
      return false
    }
    if saved == nil {
      saved = settings
    }
    settings.c_lflag &= ~tcflag_t(ICANON | ECHO)
    withUnsafeMutableBytes(of: &settings.c_cc) { characters in
      characters[Int(VMIN)] = 1
      characters[Int(VTIME)] = 0
      characters[Int(VSUSP)] = Self.disabledCharacter
      characters[Int(VDSUSP)] = Self.disabledCharacter
    }
    guard tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0 else {
      return false
    }
    if !registered {
      registered = true
      // Also on the exits that skip the usual clean-up.
      atexit { TerminalState.restore() }
    }
    return true
  }

  static func restore() {
    lock.lock()
    defer { lock.unlock() }
    guard var settings = saved else {
      return
    }
    saved = nil
    let sequence = Array("\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1002l".utf8)
    _ = sequence.withUnsafeBufferPointer { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    tcsetattr(STDIN_FILENO, TCSANOW, &settings)
  }
}
