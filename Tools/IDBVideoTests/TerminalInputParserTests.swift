/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Testing

@testable import idb_video

/// What the bytes a terminal sends are read as: mouse reports, keys and text, however they are cut up.
@Suite
struct TerminalInputParserTests {

  private func events(_ chunks: String..., pixels: Bool = false, flush: Bool = false) -> [TerminalInputEvent] {
    var parser = TerminalInputParser()
    parser.reportsPixels = pixels
    var events: [TerminalInputEvent] = []
    for chunk in chunks {
      events += parser.consume(Array(chunk.utf8))
    }
    if flush {
      events += parser.flush()
    }
    return events
  }

  // MARK: - Mouse

  @Test
  func aPressAndReleaseAreReadWithTheirCell() {
    #expect(events("\u{1b}[<0;12;34M\u{1b}[<0;12;34m") == [.press(.left, at: .cell(column: 12, row: 34)), .release(.left, at: .cell(column: 12, row: 34))])
  }

  @Test
  func positionsArePixelsOnceTheTerminalReportsPixels() {
    #expect(events("\u{1b}[<0;1226;1272M", pixels: true) == [.press(.left, at: .pixels(x: 1226, y: 1272))])
  }

  @Test
  func motionWithAButtonHeldIsADrag() {
    #expect(events("\u{1b}[<32;5;6M") == [.drag(.left, to: .cell(column: 5, row: 6))])
  }

  @Test
  func motionWithNoButtonHeldIsNothing() {
    #expect(events("\u{1b}[<35;5;6M").isEmpty)
  }

  @Test
  func theOtherButtonsAreTold() {
    #expect(events("\u{1b}[<2;1;1M\u{1b}[<1;1;1M") == [.press(.right, at: .cell(column: 1, row: 1)), .press(.middle, at: .cell(column: 1, row: 1))])
  }

  @Test
  func modifierKeysDoNotChangeTheButton() {
    // Shift is 4, Option 8, Control 16.
    #expect(events("\u{1b}[<4;1;1M\u{1b}[<24;1;1M") == [.press(.left, at: .cell(column: 1, row: 1)), .press(.left, at: .cell(column: 1, row: 1))])
  }

  @Test
  func theWheelIsAStepInItsDirection() {
    let position = TerminalMousePosition.cell(column: 3, row: 4)
    #expect(
      events("\u{1b}[<64;3;4M\u{1b}[<65;3;4M\u{1b}[<66;3;4M\u{1b}[<67;3;4M") == [
        .scroll(dx: 0, dy: -1, at: position), .scroll(dx: 0, dy: 1, at: position), .scroll(dx: -1, dy: 0, at: position),
        .scroll(dx: 1, dy: 0, at: position),
      ])
  }

  @Test
  func aReportCutAnywhereIsReadOnceWhole() {
    let report = "\u{1b}[<0;12;34M"
    for cut in 1..<report.utf8.count {
      let bytes = Array(report.utf8)
      var parser = TerminalInputParser()
      var events = parser.consume(bytes[..<cut])
      #expect(events.isEmpty, "nothing is read from the first \(cut) bytes")
      events += parser.consume(bytes[cut...])
      #expect(events == [.press(.left, at: .cell(column: 12, row: 34))])
      #expect(!parser.hasPartialSequence)
    }
  }

  // MARK: - Keys

  @Test
  func theKeysThatAreNotTextAreRead() {
    #expect(events("\r\t\u{7f}") == [.key(.enter), .key(.tab), .key(.backspace)])
    #expect(events("\u{1b}[A\u{1b}[B\u{1b}[C\u{1b}[D") == [.key(.up), .key(.down), .key(.right), .key(.left)])
    #expect(events("\u{1b}OA\u{1b}OD") == [.key(.up), .key(.left)])
    #expect(events("\u{1b}[H\u{1b}[F\u{1b}[3~\u{1b}[5~\u{1b}[6~") == [.key(.home), .key(.end), .key(.deleteForward), .key(.pageUp), .key(.pageDown)])
  }

  @Test
  func aKeyWithAModifierIsTheKey() {
    #expect(events("\u{1b}[1;5C") == [.key(.right)])
  }

  @Test
  func anEscapeByteOnItsOwnIsTheEscapeKeyOnlyOnceNothingFollows() {
    var parser = TerminalInputParser()
    #expect(parser.consume([0x1B]).isEmpty)
    #expect(parser.hasPartialSequence)
    #expect(parser.flush() == [.key(.escape)])
    #expect(!parser.hasPartialSequence)
  }

  @Test
  func anEscapeByteBeforeTheRestOfASequenceIsNotTheEscapeKey() {
    #expect(events("\u{1b}", "[A") == [.key(.up)])
  }

  @Test
  func controlCharactersTheDeviceHasNoUseForAreDropped() {
    #expect(events("a\u{01}\u{1a}b") == [.text("a"), .text("b")])
  }

  // MARK: - Text

  @Test
  func textIsReadInOnePiece() {
    #expect(events("wallpaper") == [.text("wallpaper")])
  }

  @Test
  func aCharacterOfSeveralBytesCutInTwoIsReadWhole() {
    let bytes = Array("né".utf8)
    var parser = TerminalInputParser()
    var events = parser.consume(bytes[..<2])
    events += parser.consume(bytes[2...])
    #expect(events == [.text("n"), .text("é")])
  }

  @Test
  func textAndReportsKeepTheirOrder() {
    #expect(
      events("ab\u{1b}[<0;1;1Mcd\r") == [.text("ab"), .press(.left, at: .cell(column: 1, row: 1)), .text("cd"), .key(.enter)])
  }

  @Test
  func aCharacterTypedWithOptionIsTheCharacter() {
    #expect(events("\u{1b}x") == [.text("x")])
  }

  // MARK: - What the terminal says of itself

  @Test
  func aModeTheTerminalKnowsIsSupported() {
    #expect(events("\u{1b}[?1016;2$y") == [.modeReport(mode: 1016, supported: true)])
    #expect(events("\u{1b}[?1016;1$y") == [.modeReport(mode: 1016, supported: true)])
  }

  @Test
  func aModeTheTerminalDoesNotKnowOrCannotSetIsNot() {
    #expect(events("\u{1b}[?1016;0$y") == [.modeReport(mode: 1016, supported: false)])
    #expect(events("\u{1b}[?1016;4$y") == [.modeReport(mode: 1016, supported: false)])
  }

  @Test
  func answersNobodyAskedForAreSkipped() {
    // Device attributes, and a graphics reply with its string terminator.
    #expect(events("\u{1b}[?62;22c\u{1b}_Gi=1;OK\u{1b}\\a") == [.text("a")])
  }
}
