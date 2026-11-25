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
/// are skipped rather than queued. A frame is handed to the terminal through a POSIX shared memory
/// object (`t=s`), which the terminal reads and unlinks, and is scaled to fit the terminal with
/// `c=`/`r=`. This needs a terminal on the same machine that supports shared memory transfers,
/// such as kitty, Ghostty or Rex.
///
/// @unchecked Sendable: decoder state is confined to `decodeQueue`, drawing state to
/// `presentQueue`, and the hand-off between them to `lock`.
final class KittyTerminalOutput: FrameOutput, @unchecked Sendable {
  private let isHEVC: Bool
  private let decodeQueue = DispatchQueue(label: "idb-video.kitty.decode")
  private let presentQueue = DispatchQueue(label: "idb-video.kitty.present")

  // decodeQueue
  private var parameterSets: [UInt8: Data] = [:]
  private var formatDescription: CMVideoFormatDescription?
  private var session: VTDecompressionSession?
  private var decodeFailures = 0

  // lock
  private let lock = NSLock()
  private var pending: CVPixelBuffer?
  private var presentScheduled = false

  // presentQueue
  private var lastPresented: CVPixelBuffer?
  private var shmCounter = 0
  private var placement: (columns: Int, rows: Int)?
  private var resizeSource: (any DispatchSourceSignal)?

  private(set) var presentedFrames = 0

  init(isHEVC: Bool) {
    self.isHEVC = isHEVC
  }

  /// Takes over the terminal: clears it, hides the cursor, and redraws the last frame when the
  /// terminal is resized.
  func start() {
    writeToTerminal(Data("\u{1b}[2J\u{1b}[H\u{1b}[?25l".utf8))
    signal(SIGWINCH, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: presentQueue)
    source.setEventHandler { [weak self] in
      guard let self, let frame = self.lastPresented else { return }
      self.placement = nil
      self.present(frame)
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
    decodeQueue.async { self.decode(data) }
  }

  // MARK: Decoding (decodeQueue)

  private func decode(_ accessUnit: Data) {
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
      self.enqueue(imageBuffer)
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
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    var newSession: VTDecompressionSession?
    let created = VTDecompressionSessionCreate(
      allocator: nil, formatDescription: description, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &newSession)
    guard created == noErr, let newSession else {
      log("kitty: cannot create a decoder (\(created))")
      return
    }
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

  private func enqueue(_ frame: CVPixelBuffer) {
    lock.lock()
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
    lock.unlock()
    if let frame {
      present(frame)
    }
  }

  private func present(_ frame: CVPixelBuffer) {
    lastPresented = frame
    let width = CVPixelBufferGetWidth(frame)
    let height = CVPixelBufferGetHeight(frame)
    let size = width * height * 4
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
    CVPixelBufferLockBaseAddress(frame, .readOnly)
    var source = vImage_Buffer(
      data: CVPixelBufferGetBaseAddress(frame), height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: CVPixelBufferGetBytesPerRow(frame))
    var destination = vImage_Buffer(
      data: mapped, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
    // BGRA to RGBA: the kitty protocol has no BGRA format.
    let permuted = vImagePermuteChannels_ARGB8888(&source, &destination, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
    CVPixelBufferUnlockBaseAddress(frame, .readOnly)
    munmap(mapped, size)
    guard permuted == kvImageNoError else {
      shm_unlink(name)
      return
    }
    let (columns, rows) = fit(width: width, height: height)
    // The first frame also clears what the connection logged to the terminal.
    let clear = presentedFrames == 0 ? "\u{1b}[2J" : ""
    let command =
      clear + "\u{1b}[H\u{1b}_Ga=T,f=32,s=\(width),v=\(height),t=s,S=\(size),i=1,p=1,c=\(columns),r=\(rows),C=1,q=2;"
      + Data(name.utf8).base64EncodedString() + "\u{1b}\\"
    writeToTerminal(Data(command.utf8))
    presentedFrames += 1
  }

  /// The largest box of terminal cells with the frame's aspect ratio that fits the terminal.
  private func fit(width: Int, height: Int) -> (Int, Int) {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
      return placement ?? (80, 24)
    }
    let cellWidth = size.ws_xpixel > 0 ? Double(size.ws_xpixel) / Double(size.ws_col) : 8
    let cellHeight = size.ws_ypixel > 0 ? Double(size.ws_ypixel) / Double(size.ws_row) : 16
    let scale = min(Double(size.ws_col) * cellWidth / Double(width), Double(size.ws_row) * cellHeight / Double(height))
    let fitted = (max(1, Int(Double(width) * scale / cellWidth)), max(1, Int(Double(height) * scale / cellHeight)))
    placement = fitted
    return fitted
  }

  private func writeToTerminal(_ data: Data) {
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
