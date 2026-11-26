/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Accelerate
import CoreMedia
import Darwin
import Foundation
import IDBVideoShm
import SwiftUI
import VideoToolbox

/// Where the receiver writes each Annex-B access unit, in order.
protocol FrameOutput: AnyObject, Sendable {
  func writeFrame(_ data: Data) throws
}

extension FileHandle: FrameOutput {
  func writeFrame(_ data: Data) throws {
    try write(contentsOf: data)
  }
}

/// Decodes the stream with VideoToolbox and draws it in the terminal on stdout with the kitty
/// graphics protocol.
///
/// Every access unit is decoded, in order, because each frame refers to the ones before it. Only
/// the newest decoded frame is drawn: if the terminal is slower than the stream, frames in between
/// are skipped rather than queued. A frame is converted to RGB, written to a POSIX shared memory
/// object and handed to the terminal by name (`t=s`); the terminal reads and unlinks it. This needs
/// a terminal on the same machine that supports shared memory transfers, such as kitty, Ghostty or
/// Rex.
///
/// The terminal is given the picture at exactly the size it is shown, and draws it pixel for pixel:
/// a frame that fits the terminal is shown as it is, and a larger one is scaled down here first.
/// Asking the terminal to stretch the picture over a box of cells instead (`c=`/`r=`) resamples it,
/// usually by a few percent because the box is a whole number of cells, and that is enough to blur
/// every line of text in it.
///
/// @unchecked Sendable: decoder state is confined to `decodeQueue`, conversion and drawing state to
/// `presentQueue`, and the hand-off between them to `lock`.
final class KittyTerminalOutput: FrameOutput, @unchecked Sendable {
  /// A decoded frame on its way to the terminal.
  private struct DecodedFrame {
    let image: CVPixelBuffer
    /// When its access unit arrived and how long decoding took, for the log.
    let receivedAt: UInt64
    let decodeNanos: UInt64
  }

  /// Where a frame goes in the terminal and at what size.
  private struct Layout {
    /// The size the frame is converted to and shown at, in pixels.
    var pixelWidth: Int
    var pixelHeight: Int
    /// The cell the picture starts in (1-based) and its offset inside that cell, which centre it.
    var column = 1
    var offsetX = 0
    /// A box of cells for the terminal to stretch the picture over, for a terminal that does not
    /// say how many pixels it has. nil draws the picture at its own size.
    var cells: (columns: Int, rows: Int)?
    /// One cell of the terminal in pixels, where it says.
    var cellWidth = 1.0
    var cellHeight = 1.0
    /// The device's buttons drawn around the picture as text.
    var buttons: [ButtonPlacement] = []
    /// The Home button drawn as a picture under the screen: its top left corner and size in the
    /// terminal's pixels. nil where the terminal does not say how many pixels it has.
    var homeImage: (x: Int, y: Int, diameter: Int)?
    /// The volume buttons drawn as one upright capsule left of the screen, where a phone has them:
    /// its top left corner and size in the terminal's pixels.
    var volumeImage: (x: Int, y: Int, width: Int, height: Int)?
    /// The lock button drawn as a capsule right of the screen, likewise.
    var lockImage: (x: Int, y: Int, width: Int, height: Int)?
    /// The viewer's button for the screen's corners, a disc right above the lock button.
    var cornersImage: (x: Int, y: Int, diameter: Int)?
    /// The radius the picture's corners are rounded to, in its pixels; 0 for the whole rectangle.
    var cornerRadius = 0

    /// Everything that decides what is on the terminal besides the frame itself. When it changes,
    /// what was drawn for the old one is cleared.
    var signature: String {
      "\(pixelWidth)x\(pixelHeight)@\(column)+\(offsetX) \(cells.map { "\($0.columns)x\($0.rows)" } ?? "-") "
        + buttons.map { "\($0.button.label):\($0.column),\($0.row),\($0.width),\($0.height)" }.joined(separator: " ")
        + (homeImage.map { " home:\($0.x),\($0.y),\($0.diameter)" } ?? "")
        + (volumeImage.map { " volume:\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "")
        + (lockImage.map { " lock:\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "")
        + (cornersImage.map { " corners:\($0.x),\($0.y),\($0.diameter)" } ?? "")
    }
  }

  /// A button drawn in the terminal: its first cell, counted from 1, and its size in cells.
  private struct ButtonPlacement {
    let button: DeviceButton
    let column: Int
    let row: Int
    let width: Int
    let height: Int
  }

  private let isHEVC: Bool
  private let showsButtons: Bool
  private let frameLog: FileHandle?
  private let decodeQueue = DispatchQueue(label: "idb-video.kitty.decode", qos: .userInteractive)
  private let presentQueue = DispatchQueue(label: "idb-video.kitty.present", qos: .userInteractive)

  // decodeQueue
  private var parameterSets: [UInt8: Data] = [:]
  private var formatDescription: CMVideoFormatDescription?
  private var session: VTDecompressionSession?
  private var decodeFailures = 0

  // lock
  private let lock = NSLock()
  private var pending: DecodedFrame?
  private var presentScheduled = false
  private var skippedFrames = 0

  // geometryLock
  private let geometryLock = NSLock()
  private var geometry: PictureGeometry?

  // terminalLock: what is written to the terminal, by the drawing and by whoever reads its input
  private let terminalLock = NSLock()

  // presentQueue
  private var lastPresented: CVPixelBuffer?
  private var transferSession: VTPixelTransferSession?
  private var convertedPool: CVPixelBufferPool?
  private var convertedSize: (width: Int, height: Int)?
  private var conversionFailures = 0
  private var shmCounter = 0
  private var drawnFrames = 0
  private var drawnSignature: String?
  private var drawnLayout: Layout?
  private var pressedButtons: Set<DeviceButton> = []
  private var bodyButtons = DeviceBodyButtons()
  /// Whether the picture is shown with the screen's rounded corners.
  private var roundsCorners = false
  private var cornerMask: CornerMask?
  private var resizeSource: (any DispatchSourceSignal)?

  /// `showsButtons` draws the device's buttons beside the picture, for a terminal whose mouse
  /// drives the device. `frameLogPath` gets a line per frame drawn, for measuring.
  init(isHEVC: Bool, showsButtons: Bool = false, frameLogPath: String? = nil) throws {
    self.isHEVC = isHEVC
    self.showsButtons = showsButtons
    if let frameLogPath {
      guard FileManager.default.createFile(atPath: frameLogPath, contents: nil), let handle = FileHandle(forWritingAtPath: frameLogPath) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: frameLogPath])
      }
      frameLog = handle
    } else {
      frameLog = nil
    }
  }

  /// Where the picture drawn last is in the terminal; nil before the first frame.
  var pictureGeometry: PictureGeometry? {
    geometryLock.withLock { geometry }
  }

  /// Puts the drawn buttons where they are on the device's body, once the companion has said.
  func setBodyButtons(_ buttons: DeviceBodyButtons) {
    presentQueue.async {
      guard buttons != self.bodyButtons else {
        return
      }
      self.bodyButtons = buttons
      // Drawn again now: a still screen brings no frame to do it.
      if let image = self.lastPresented {
        self.present(DecodedFrame(image: image, receivedAt: DispatchTime.now().uptimeNanoseconds, decodeNanos: 0), afterResize: false)
      }
    }
  }

  /// Shows a drawn button as pressed, or as let go.
  func setPressed(_ button: DeviceButton, _ pressed: Bool) {
    presentQueue.async {
      if pressed {
        self.pressedButtons.insert(button)
      } else {
        self.pressedButtons.remove(button)
      }
      guard let layout = self.drawnLayout else {
        return
      }
      if button == .corners, pressed {
        // The viewer's own: pressing it switches the corners, and the frame is drawn again to show it.
        self.roundsCorners.toggle()
        if let image = self.lastPresented {
          self.present(DecodedFrame(image: image, receivedAt: DispatchTime.now().uptimeNanoseconds, decodeNanos: 0), afterResize: false)
        }
      }
      let command: String?
      switch button {
      case .home: command = self.homeImageCommand(for: layout)
      case .volumeUp, .volumeDown: command = self.volumeImageCommand(for: layout)
      case .lock: command = self.lockImageCommand(for: layout)
      case .corners: command = self.cornersImageCommand(for: layout)
      }
      if let command {
        self.writeToTerminal(Data(command.utf8))
      }
    }
  }

  /// Writes a control sequence to the terminal, whole, between the frames.
  func writeControl(_ sequence: String) {
    writeToTerminal(Data(sequence.utf8))
  }

  /// Takes over the terminal: clears it, hides the cursor, and redraws the last frame when the
  /// terminal is resized.
  func start() {
    writeToTerminal(Data("\u{1b}[2J\u{1b}[H\u{1b}[?25l".utf8))
    signal(SIGWINCH, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: presentQueue)
    source.setEventHandler { [weak self] in
      // The last frame again, laid out for the terminal's new size.
      guard let self, let image = self.lastPresented else { return }
      self.present(DecodedFrame(image: image, receivedAt: DispatchTime.now().uptimeNanoseconds, decodeNanos: 0), afterResize: true)
    }
    source.resume()
    resizeSource = source
  }

  /// Removes the image and shows the cursor again.
  func finish() {
    decodeQueue.sync {}
    presentQueue.sync {
      resizeSource?.cancel()
      writeToTerminal(Data("\u{1b}_Ga=d,d=I,i=1,q=2\u{1b}\\\u{1b}[?25h\u{1b}[2J\u{1b}[H".utf8))
    }
  }

  func writeFrame(_ data: Data) throws {
    let receivedAt = DispatchTime.now().uptimeNanoseconds
    decodeQueue.async { self.decode(data, receivedAt: receivedAt) }
  }

  // MARK: Decoding (decodeQueue)

  private func decode(_ accessUnit: Data, receivedAt: UInt64) {
    var slices = Data()
    var parametersChanged = false
    for nal in Self.nalUnits(in: accessUnit) {
      guard let header = nal.first else { continue }
      let type = isHEVC ? (header >> 1) & 0x3F : header & 0x1F
      if isParameterSet(type) {
        if parameterSets[type] != nal {
          parameterSets[type] = nal
          parametersChanged = true
        }
      } else if isSlice(type) {
        var length = UInt32(nal.count).bigEndian
        slices.append(Data(bytes: &length, count: 4))
        slices.append(nal)
      }
    }
    if parametersChanged || session == nil {
      makeSession()
    }
    guard let session, let formatDescription, !slices.isEmpty else {
      return
    }
    guard let sample = Self.sampleBuffer(slices, formatDescription: formatDescription) else {
      return
    }
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
      [weak self] status, _, imageBuffer, _, _ in
      guard let self else { return }
      guard status == noErr, let imageBuffer else {
        self.logDecodeFailure(status)
        return
      }
      self.enqueue(DecodedFrame(image: imageBuffer, receivedAt: receivedAt, decodeNanos: DispatchTime.now().uptimeNanoseconds - receivedAt))
    }
    if status != noErr {
      logDecodeFailure(status)
    }
  }

  private func isParameterSet(_ type: UInt8) -> Bool {
    isHEVC ? (32...34).contains(type) : type == 7 || type == 8
  }

  private func isSlice(_ type: UInt8) -> Bool {
    isHEVC ? type <= 31 : (1...5).contains(type)
  }

  private func makeSession() {
    if let session {
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    formatDescription = nil
    let order: [UInt8] = isHEVC ? [32, 33, 34] : [7, 8]
    let sets = order.compactMap { parameterSets[$0] }
    guard sets.count == order.count else {
      return
    }
    var description: CMFormatDescription?
    let status = Self.withPointers(to: sets) { pointers, sizes in
      isHEVC
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
          allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
          nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
          nalUnitHeaderLength: 4, formatDescriptionOut: &description)
    }
    guard status == noErr, let description else {
      log("kitty: cannot read the stream's parameter sets (\(status))")
      return
    }
    // No pixel format is asked for: the decoder hands out frames as it holds them (4:2:0 or 4:4:4
    // YCbCr), and one conversion then takes them to RGB at the size the terminal shows.
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
    var newSession: VTDecompressionSession?
    let created = VTDecompressionSessionCreate(
      allocator: nil, formatDescription: description, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &newSession)
    guard created == noErr, let newSession else {
      log("kitty: cannot create a decoder for this stream (\(created)); if it is 4:4:4, try --chroma 420")
      return
    }
    VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    log("kitty: decoding \(isHEVC ? "HEVC" : "H.264") \(dimensions.width)x\(dimensions.height) with VideoToolbox")
    formatDescription = description
    session = newSession
  }

  private func logDecodeFailure(_ status: OSStatus) {
    decodeFailures += 1
    if decodeFailures <= 3 {
      log("kitty: a frame failed to decode (\(status))")
    }
  }

  /// Splits an Annex-B access unit at its start codes.
  static func nalUnits(in data: Data) -> [Data] {
    let bytes = [UInt8](data)
    var units: [Data] = []
    var start: Int?
    var i = 0
    while i + 2 < bytes.count {
      if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
        if let start {
          var end = i
          if end > start, bytes[end - 1] == 0 { end -= 1 }  // the leading zero of a 4-byte start code
          units.append(Data(bytes[start..<end]))
        }
        i += 3
        start = i
      } else {
        i += 1
      }
    }
    if let start, start < bytes.count {
      units.append(Data(bytes[start...]))
    }
    return units
  }

  private static func withPointers<R>(
    to sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R
  ) -> R {
    let buffers = sets.map { [UInt8]($0) }
    let pointers = buffers.map { buffer -> UnsafeMutablePointer<UInt8> in
      let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: buffer.count)
      pointer.initialize(from: buffer, count: buffer.count)
      return pointer
    }
    defer { pointers.forEach { $0.deallocate() } }
    let constant = pointers.map { UnsafePointer($0) }
    let sizes = buffers.map(\.count)
    return constant.withUnsafeBufferPointer { p in
      sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
    }
  }

  private static func sampleBuffer(_ data: Data, formatDescription: CMFormatDescription) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
      let block
    else {
      return nil
    }
    let copied = data.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
    }
    guard copied == noErr else { return nil }
    var sample: CMSampleBuffer?
    var size = data.count
    guard
      CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 0,
        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
    else {
      return nil
    }
    return sample
  }

  // MARK: Hand-off

  private func enqueue(_ frame: DecodedFrame) {
    lock.lock()
    if pending != nil {
      skippedFrames += 1
    }
    pending = frame
    let schedule = !presentScheduled
    presentScheduled = true
    lock.unlock()
    if schedule {
      presentQueue.async { self.presentPending() }
    }
  }

  // MARK: Drawing (presentQueue)

  private func presentPending() {
    lock.lock()
    let frame = pending
    pending = nil
    presentScheduled = false
    let skipped = skippedFrames
    skippedFrames = 0
    lock.unlock()
    if skipped > 0 {
      frameLog?.write(Data("skipped \(skipped)\n".utf8))
    }
    if let frame {
      present(frame, afterResize: false)
    }
  }

  private func present(_ frame: DecodedFrame, afterResize: Bool) {
    let started = DispatchTime.now().uptimeNanoseconds
    lastPresented = frame.image
    let layout = layout(width: CVPixelBufferGetWidth(frame.image), height: CVPixelBufferGetHeight(frame.image))
    let width = layout.pixelWidth
    let height = layout.pixelHeight
    guard let converted = convert(frame.image, width: width, height: height) else {
      return
    }
    // Three bytes a pixel while the picture is opaque: a quarter less for the terminal to take in.
    // With the corners rounded it needs the fourth, to be clear outside them.
    let radius = roundsCorners ? min(layout.cornerRadius, width / 2, height / 2) : 0
    let bytesPerPixel = radius > 0 ? 4 : 3
    let size = width * height * bytesPerPixel
    shmCounter += 1
    let name = "/idbv\(getpid())-\(shmCounter % 100_000)"
    let fd = idbv_shm_create(name, UInt(size))
    guard fd >= 0 else {
      log("kitty: cannot create shared memory: \(String(cString: strerror(errno)))")
      return
    }
    defer { close(fd) }
    guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else {
      shm_unlink(name)
      return
    }
    CVPixelBufferLockBaseAddress(converted, .readOnly)
    var source = vImage_Buffer(
      data: CVPixelBufferGetBaseAddress(converted), height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: CVPixelBufferGetBytesPerRow(converted))
    var destination = vImage_Buffer(
      data: mapped, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * bytesPerPixel)
    // BGRA to RGB or RGBA: the kitty protocol has no BGRA format.
    let reordered: vImage_Error
    if radius > 0 {
      reordered = vImagePermuteChannels_ARGB8888(&source, &destination, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
      if cornerMask?.width != width || cornerMask?.height != height || cornerMask?.radius != radius {
        cornerMask = CornerMask(width: width, height: height, radius: radius)
      }
      cornerMask?.apply(to: mapped)
    } else {
      reordered = vImageConvert_BGRA8888toRGB888(&source, &destination, vImage_Flags(kvImageNoFlags))
    }
    CVPixelBufferUnlockBaseAddress(converted, .readOnly)
    munmap(mapped, size)
    guard reordered == kvImageNoError else {
      shm_unlink(name)
      return
    }
    // The first frame also clears what the connection logged to the terminal, and a change of
    // layout clears the picture and the buttons where they were, which the new ones need not cover.
    let signature = layout.signature
    let redraw = drawnFrames == 0 || afterResize || signature != drawnSignature
    drawnSignature = signature
    drawnLayout = layout
    // The buttons are drawn once for a layout: nothing a frame draws touches them.
    let clear =
      redraw
      ? "\u{1b}[2J" + Self.drawing(of: layout.buttons) + (homeImageCommand(for: layout) ?? "") + (volumeImageCommand(for: layout) ?? "")
        + (lockImageCommand(for: layout) ?? "") + (cornersImageCommand(for: layout) ?? "") : ""
    var keys = "a=T,f=\(bytesPerPixel * 8),s=\(width),v=\(height),t=s,S=\(size),i=1,p=1,C=1,q=2"
    if let cells = layout.cells {
      keys += ",c=\(cells.columns),r=\(cells.rows)"
    }
    if layout.offsetX > 0 {
      keys += ",X=\(layout.offsetX)"
    }
    let command = clear + "\u{1b}[1;\(layout.column)H\u{1b}_G\(keys);" + Data(name.utf8).base64EncodedString() + "\u{1b}\\"
    publishGeometry(of: layout, sourceWidth: CVPixelBufferGetWidth(frame.image), sourceHeight: CVPixelBufferGetHeight(frame.image))
    let converted_ = DispatchTime.now().uptimeNanoseconds
    writeToTerminal(Data(command.utf8))
    drawnFrames += 1
    if let frameLog {
      let written = DispatchTime.now().uptimeNanoseconds
      // decode, convert and terminal write in ms; ms from arrival to handed over; a spare column; the size
      // drawn; when it was handed over (host uptime in nanoseconds).
      let line = String(
        format: "f %.2f %.2f %.2f %.2f 0 %dx%d %llu\n", Double(frame.decodeNanos) / 1e6, Double(converted_ - started) / 1e6,
        Double(written - converted_) / 1e6, Double(written - frame.receivedAt) / 1e6, width, height, written)
      frameLog.write(Data(line.utf8))
    }
  }

  /// The command that draws the Home button's picture where the layout puts it, as its own image
  /// beside the screen's.
  private func homeImageCommand(for layout: Layout) -> String? {
    guard let home = layout.homeImage,
      let pixels = DeviceButtonArt.homeButton(diameter: home.diameter, pressed: pressedButtons.contains(.home))
    else {
      return nil
    }
    return imageCommand(pixels, width: home.diameter, height: home.diameter, id: Self.homeImageID, x: home.x, y: home.y, layout: layout)
  }

  /// The same for the volume capsule, with the half that is held shown so.
  private func volumeImageCommand(for layout: Layout) -> String? {
    let pressed: DeviceButton? = pressedButtons.contains(.volumeUp) ? .volumeUp : pressedButtons.contains(.volumeDown) ? .volumeDown : nil
    guard let volume = layout.volumeImage,
      let pixels = DeviceButtonArt.volumeCapsule(width: volume.width, height: volume.height, pressed: pressed)
    else {
      return nil
    }
    return imageCommand(pixels, width: volume.width, height: volume.height, id: Self.volumeImageID, x: volume.x, y: volume.y, layout: layout)
  }

  /// And for the lock button.
  private func lockImageCommand(for layout: Layout) -> String? {
    guard let lock = layout.lockImage,
      let pixels = DeviceButtonArt.lockCapsule(width: lock.width, height: lock.height, pressed: pressedButtons.contains(.lock))
    else {
      return nil
    }
    return imageCommand(pixels, width: lock.width, height: lock.height, id: Self.lockImageID, x: lock.x, y: lock.y, layout: layout)
  }

  /// And for the viewer's corners button.
  private func cornersImageCommand(for layout: Layout) -> String? {
    guard let corners = layout.cornersImage,
      let pixels = DeviceButtonArt.cornersButton(diameter: corners.diameter, pressed: pressedButtons.contains(.corners))
    else {
      return nil
    }
    return imageCommand(pixels, width: corners.diameter, height: corners.diameter, id: Self.cornersImageID, x: corners.x, y: corners.y, layout: layout)
  }

  /// The command that hands the terminal an RGBA picture through shared memory and places it with
  /// its top left corner at a pixel of the terminal, as image `id`, replacing what that image was.
  private func imageCommand(_ pixels: [UInt8], width: Int, height: Int, id: Int, x: Int, y: Int, layout: Layout) -> String? {
    shmCounter += 1
    let name = "/idbv\(getpid())-\(shmCounter % 100_000)"
    let fd = idbv_shm_create(name, UInt(pixels.count))
    guard fd >= 0 else {
      return nil
    }
    defer { close(fd) }
    guard let mapped = mmap(nil, pixels.count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else {
      shm_unlink(name)
      return nil
    }
    pixels.withUnsafeBytes { _ = memcpy(mapped, $0.baseAddress!, pixels.count) }
    munmap(mapped, pixels.count)
    // The cell its corner falls in, and how far into that cell.
    let column = Int(Double(x) / layout.cellWidth)
    let row = Int(Double(y) / layout.cellHeight)
    let offsetX = max(0, x - Int((Double(column) * layout.cellWidth).rounded(.up)))
    let offsetY = max(0, y - Int((Double(row) * layout.cellHeight).rounded(.up)))
    return "\u{1b}[\(row + 1);\(column + 1)H\u{1b}_Ga=T,f=32,s=\(width),v=\(height),t=s,S=\(pixels.count),i=\(id),p=1,C=1,q=2,X=\(offsetX),Y=\(offsetY);"
      + Data(name.utf8).base64EncodedString() + "\u{1b}\\"
  }

  /// Where the picture is from now on, for whoever maps the mouse onto it.
  private func publishGeometry(of layout: Layout, sourceWidth: Int, sourceHeight: Int) {
    var published: PictureGeometry
    defer {
      published.buttons = layout.buttons.map { placement in
        PictureGeometry.ButtonArea(
          button: placement.button, x: Double(placement.column - 1) * published.cellWidth, y: Double(placement.row - 1) * published.cellHeight,
          width: Double(placement.width) * published.cellWidth, height: Double(placement.height) * published.cellHeight)
      }
      if let home = layout.homeImage {
        published.buttons.append(
          PictureGeometry.ButtonArea(button: .home, x: Double(home.x), y: Double(home.y), width: Double(home.diameter), height: Double(home.diameter)))
      }
      if let volume = layout.volumeImage {
        // The capsule's top half turns the volume up and its bottom half down.
        let half = Double(volume.height) / 2
        published.buttons.append(
          PictureGeometry.ButtonArea(button: .volumeUp, x: Double(volume.x), y: Double(volume.y), width: Double(volume.width), height: half))
        published.buttons.append(
          PictureGeometry.ButtonArea(button: .volumeDown, x: Double(volume.x), y: Double(volume.y) + half, width: Double(volume.width), height: half))
      }
      if let lock = layout.lockImage {
        published.buttons.append(
          PictureGeometry.ButtonArea(button: .lock, x: Double(lock.x), y: Double(lock.y), width: Double(lock.width), height: Double(lock.height)))
      }
      if let corners = layout.cornersImage {
        published.buttons.append(
          PictureGeometry.ButtonArea(
            button: .corners, x: Double(corners.x), y: Double(corners.y), width: Double(corners.diameter), height: Double(corners.diameter)))
      }
      geometryLock.withLock { geometry = published }
    }
    if let cells = layout.cells {
      // Without pixels the only unit is the cell.
      published = PictureGeometry(
        originX: 0, originY: 0, width: Double(cells.columns), height: Double(cells.rows), cellWidth: 1, cellHeight: 1,
        sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    } else {
      published = PictureGeometry(
        originX: Double(layout.column - 1) * layout.cellWidth + Double(layout.offsetX), originY: 0,
        width: Double(layout.pixelWidth), height: Double(layout.pixelHeight), cellWidth: layout.cellWidth, cellHeight: layout.cellHeight,
        sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
  }

  /// The frame as BGRA at `width` by `height`, in one pass that takes the decoder's YCbCr to RGB and
  /// scales it if the size differs.
  private func convert(_ frame: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
    if transferSession == nil {
      var created: VTPixelTransferSession?
      guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr, let created else {
        return nil
      }
      VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
      transferSession = created
    }
    if convertedPool == nil || convertedSize?.width != width || convertedSize?.height != height {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
      ]
      var pool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
      convertedPool = pool
      convertedSize = (width, height)
    }
    guard let transferSession, let convertedPool else {
      return nil
    }
    var converted: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, convertedPool, &converted) == kCVReturnSuccess, let converted else {
      return nil
    }
    let status = VTPixelTransferSessionTransferImage(transferSession, from: frame, to: converted)
    guard status == noErr else {
      conversionFailures += 1
      if conversionFailures <= 3 {
        log("kitty: cannot convert a decoded frame to RGB (\(status))")
      }
      return nil
    }
    return converted
  }

  /// A frame that fits the terminal is drawn at its own size, centred; a larger one is scaled down to
  /// the largest size of its shape that fits. A terminal that does not report its size in pixels
  /// gets the frame as it is and a box of cells to stretch it over.
  private func layout(width: Int, height: Int) -> Layout {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
      return Layout(pixelWidth: width, pixelHeight: height, cells: (80, 24))
    }
    let columns = Int(size.ws_col)
    let rows = Int(size.ws_row)
    guard size.ws_xpixel > 0, size.ws_ypixel > 0 else {
      // Without pixels to place pictures by, the buttons are text: a row under the picture for Home
      // and a strip of columns to its right for the rest.
      let buttonColumns = showsButtons && columns > 2 * Self.buttonColumns ? Self.buttonColumns : 0
      let buttonRows = showsButtons && rows > 4 ? 1 : 0
      let scale = min(Double(columns - buttonColumns) * 8 / Double(width), Double(rows - buttonRows) * 16 / Double(height))
      let cells = (columns: max(1, Int(Double(width) * scale / 8)), rows: max(1, Int(Double(height) * scale / 16)))
      var layout = Layout(pixelWidth: width, pixelHeight: height, cells: cells)
      if showsButtons {
        layout.buttons = Self.buttons(left: 1, right: cells.columns, pictureRows: cells.rows, columns: columns, rows: rows)
      }
      return layout
    }
    let cellWidth = Double(size.ws_xpixel) / Double(columns)
    let cellHeight = Double(size.ws_ypixel) / Double(rows)
    let buttonRows = showsButtons && rows > 2 * Self.homeButtonRows ? Self.homeButtonRows : 0
    // The volume capsule stands in a strip of its own left of the picture and the lock button in
    // one right of it, each no wider than it needs. The capsules are a whole, even number of pixels
    // wide, so that their outlines and the marks down their middles fall on pixels.
    let capsuleWidth = showsButtons && columns > Self.sideButtonsMinimumColumns ? 2 * Int((Self.capsuleWidthInCells * cellWidth / 2).rounded()) : 0
    let sideStrip = capsuleWidth > 0 ? capsuleWidth + Self.capsuleGap + 2 : 0
    let available = (width: Int(size.ws_xpixel) - 2 * sideStrip, height: Int(Double(rows - buttonRows) * cellHeight))
    let scale = min(1, Double(available.width) / Double(width), Double(available.height) / Double(height))
    var layout = Layout(pixelWidth: max(1, Int(Double(width) * scale)), pixelHeight: max(1, Int(Double(height) * scale)))
    let wholeCellWidth = max(1, Int(cellWidth))
    let margin = sideStrip + max(0, (available.width - layout.pixelWidth) / 2)
    layout.column = min(columns, margin / wholeCellWidth + 1)
    layout.offsetX = margin % wholeCellWidth
    // The terminal puts the picture at whole cells of its own width, which need not be a whole number of pixels.
    layout.cellWidth = cellWidth
    layout.cellHeight = cellHeight
    if showsButtons {
      let left = Int(Double(layout.column - 1) * cellWidth) + layout.offsetX
      // The Home button, a disc as tall as the rows kept for it less a little air, centred under the screen.
      let diameter = min(layout.pixelWidth, Int(Double(buttonRows) * cellHeight) - 2 * Self.homeButtonGap)
      if buttonRows > 0, diameter >= 16 {
        layout.homeImage = (left + (layout.pixelWidth - diameter) / 2, layout.pixelHeight + Self.homeButtonGap, diameter)
      }
      /// Where a capsule of `height` goes for its middle to be `middle` of the way down the screen.
      func top(height: Int, middle: Double) -> Int {
        min(max(0, Int(Double(layout.pixelHeight) * middle) - height / 2), layout.pixelHeight - height)
      }
      // The volume capsule: two and a half times as tall as it is wide, on the screen's left side
      // with its middle where the middle of the device's two volume buttons is.
      let volumeHeight = min(capsuleWidth * 5 / 2, layout.pixelHeight)
      let volumeX = left - Self.capsuleGap - capsuleWidth
      if capsuleWidth > 0, volumeX >= 0, volumeHeight >= 2 * capsuleWidth {
        layout.volumeImage = (volumeX, top(height: volumeHeight, middle: bodyButtons.volumeMiddle ?? Self.volumeMiddle), capsuleWidth, volumeHeight)
      }
      // The lock button: a capsule of the same width on the right side, where the device's is. On a
      // phone that button is about half as long again as one volume button, and so is this.
      let lockHeight = min(2 * Int((Double(capsuleWidth) * 0.9).rounded()), layout.pixelHeight)
      if capsuleWidth > 0, lockHeight >= capsuleWidth * 3 / 2 {
        let lock = (
          x: left + layout.pixelWidth + Self.capsuleGap, y: top(height: lockHeight, middle: bodyButtons.lockMiddle ?? Self.lockMiddle),
          width: capsuleWidth, height: lockHeight
        )
        layout.lockImage = lock
        // The viewer's corners button right above it, a disc as wide, for a screen that has rounded
        // corners to show.
        if let cornerRadius = bodyButtons.cornerRadius, lock.y - Self.cornersButtonGap - capsuleWidth >= 0 {
          layout.cornerRadius = Int((cornerRadius * Double(layout.pixelWidth)).rounded())
          layout.cornersImage = (lock.x, lock.y - Self.cornersButtonGap - capsuleWidth, capsuleWidth)
        }
      }
    }
    return layout
  }

  // MARK: Buttons

  /// The rows under the picture kept for the Home button's picture, the pixels of air above and
  /// below it, and the kitty image it is (the screen is image 1).
  private static let homeButtonRows = 3
  private static let homeButtonGap = 4
  private static let homeImageID = 2
  /// How many cells wide the capsules beside the screen are, the pixels between them and the
  /// screen, how many columns a terminal needs for there to be any, and the kitty images they are.
  private static let capsuleWidthInCells = 5.1
  private static let capsuleGap = 6
  private static let sideButtonsMinimumColumns = 36
  private static let volumeImageID = 3
  private static let lockImageID = 4
  private static let cornersImageID = 5
  /// The pixels between the corners button and the lock button under it.
  private static let cornersButtonGap = 10
  /// How far down the screen the middles of the volume buttons and of the lock button are, as
  /// fractions of its height, until the companion says where they are on this device, and for one
  /// that cannot say. About where the phones without a Home button have them.
  private static let volumeMiddle = 0.315
  private static let lockMiddle = 0.338
  /// The columns to the picture's right that the side buttons take: a gap, then the buttons.
  private static let sideButtonWidth = 5
  private static let buttonColumns = sideButtonWidth + 1

  /// Where the buttons go as text, for a terminal that cannot place pictures by the pixel, around a
  /// picture that covers the cells from `left` to `right` and `pictureRows` rows: Home under it,
  /// and the volume and lock buttons down its right side. A button that has no room is left out.
  private static func buttons(left: Int, right: Int, pictureRows: Int, columns: Int, rows: Int) -> [ButtonPlacement] {
    var placed: [ButtonPlacement] = []
    let pictureColumns = right - left + 1
    if pictureRows + 1 <= rows {
      let width = min(pictureColumns, max(10, pictureColumns / 3))
      placed.append(ButtonPlacement(button: .home, column: left + (pictureColumns - width) / 2, row: pictureRows + 1, width: width, height: 1))
    }
    let column = right + 2
    guard column + sideButtonWidth - 1 <= columns else {
      return placed
    }
    // Tall enough to hit easily where the picture is tall enough to stand them beside.
    let height = pictureRows >= 20 ? 3 : 1
    var row = max(1, pictureRows / 6)
    for button in [DeviceButton.volumeUp, .volumeDown, .lock] {
      // The lock button stands apart from the two that belong together.
      if button == .lock {
        row += height
      }
      guard row + height - 1 <= min(rows, pictureRows) else {
        break
      }
      placed.append(ButtonPlacement(button: button, column: column, row: row, width: sideButtonWidth, height: height))
      row += height + 1
    }
    return placed
  }

  /// The text that draws the buttons: each a block in reverse video with its name in the middle.
  private static func drawing(of buttons: [ButtonPlacement]) -> String {
    var text = ""
    for placement in buttons {
      let label = placement.button.label
      let before = max(0, (placement.width - label.count) / 2)
      let after = max(0, placement.width - label.count - before)
      for line in 0..<placement.height {
        let content =
          line == placement.height / 2
          ? String(repeating: " ", count: before) + label + String(repeating: " ", count: after)
          : String(repeating: " ", count: placement.width)
        text += "\u{1b}[\(placement.row + line);\(placement.column)H\u{1b}[7m\(content)\u{1b}[0m"
      }
    }
    return text
  }

  private func writeToTerminal(_ data: Data) {
    terminalLock.lock()
    defer { terminalLock.unlock() }
    data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = Darwin.write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
        if written < 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          return
        }
        offset += written
      }
    }
  }
}

/// What of a picture lies outside the rounded corners of a screen, to make it clear there.
///
/// The corners are Apple's continuous ones, the shape a device's screen has: not a quarter circle
/// but a curve that leaves the straight side early and bends gradually, so it reaches further
/// along each side than its radius. The shape is taken from the system (`RoundedRectangle` in the
/// `.continuous` style) rather than approximated here.
struct CornerMask {
  let width: Int
  let height: Int
  let radius: Int
  /// The side of the square at each corner that the curve stays within.
  let side: Int
  /// How much of each pixel of the top left square is inside the shape, row by row from the top;
  /// the other three corners are its mirror images.
  let coverage: [UInt8]

  /// nil when there is nothing to round.
  init?(width: Int, height: Int, radius: Int) {
    guard radius > 0, width > 0, height > 0 else {
      return nil
    }
    // A continuous corner runs about half as far again along the sides as its radius.
    let side = min(min(width, height) / 2, radius * 2)
    guard side > 0 else {
      return nil
    }
    var coverage = [UInt8](repeating: 0, count: side * side)
    let drawn = coverage.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
      else {
        return false
      }
      // Core Graphics counts rows from the bottom and the bitmap's first row is its top one, so the
      // whole rectangle is placed with its top left corner at the top left of the square.
      let screen = CGRect(x: 0, y: CGFloat(side - height), width: CGFloat(width), height: CGFloat(height))
      context.addPath(Path(roundedRect: screen, cornerRadius: CGFloat(radius), style: .continuous).cgPath)
      context.fillPath()
      return true
    }
    guard drawn else {
      return nil
    }
    self.width = width
    self.height = height
    self.radius = radius
    self.side = side
    self.coverage = coverage
  }

  /// Sets the alpha of an RGBA picture of this mask's size to what the shape covers, in its four corners.
  func apply(to pixels: UnsafeMutableRawPointer) {
    let bytes = pixels.assumingMemoryBound(to: UInt8.self)
    for row in 0..<side {
      for column in 0..<side {
        let alpha = coverage[row * side + column]
        guard alpha < 255 else {
          continue
        }
        for y in [row, height - 1 - row] {
          for x in [column, width - 1 - column] {
            bytes[(y * width + x) * 4 + 3] = alpha
          }
        }
      }
    }
  }
}
