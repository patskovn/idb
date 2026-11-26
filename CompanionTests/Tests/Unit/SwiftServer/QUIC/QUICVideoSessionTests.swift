/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import CryptoKit
import FBVideoCore
import Foundation
import Security
import Testing

@Suite
struct QUICSessionIdentityTests {

  @Test
  func theCertificateParsesAndIsSignedByItsOwnKey() throws {
    let key = P256.Signing.PrivateKey()
    let der = try QUICSessionIdentity.selfSignedCertificate(for: key, commonName: "idb-companion", lifetime: 3600)
    let certificate = try #require(SecCertificateCreateWithData(nil, Data(der) as CFData))
    #expect(SecCertificateCopySubjectSummary(certificate) as String? == "idb-companion")

    let publicKey = try #require(SecCertificateCopyKey(certificate))
    var error: Unmanaged<CFError>?
    let exported = try #require(unsafe SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)
    #expect(exported == key.publicKey.x963Representation)
  }

  @Test
  func eachIdentityIsNewAndReportsItsFingerprint() throws {
    let first = try QUICSessionIdentity.make()
    let second = try QUICSessionIdentity.make()
    #expect(first.certificateSHA256.count == 32)
    #expect(first.certificateSHA256 != second.certificateSHA256)
  }

  @Test
  func derLengthsUseTheLongFormFrom128Bytes() {
    #expect(DER.length(127) == [0x7f])
    #expect(DER.length(128) == [0x81, 0x80])
    #expect(DER.length(300) == [0x82, 0x01, 0x2c])
  }

  @Test
  func derObjectIdentifiersEncodeMultiByteArcs() {
    // ecdsa-with-SHA256
    #expect(DER.objectIdentifier([1, 2, 840, 10045, 4, 3, 2]) == [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])
  }

  @Test
  func derIntegersStayPositive() {
    #expect(DER.integer([0x80]) == [0x02, 0x02, 0x00, 0x80])
    #expect(DER.integer([0x00, 0x00, 0x05]) == [0x02, 0x01, 0x05])
  }
}

@Suite
struct QUICVideoWireTests {

  @Test
  func theFrameHeaderIsTwentyBigEndianBytes() {
    let header = QUICVideoWire.frameHeader(sequence: 0x0102, isKeyFrame: true, capturedAtUptimeNanos: 0x0a0b)
    #expect(header.count == QUICVideoWire.frameHeaderLength)
    #expect(Array(header) == [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0x0a, 0x0b])
    #expect(QUICVideoWire.uint64(bigEndian: Array(header)[4..<12]) == 0x0102)
  }

  @Test
  func aDeltaFrameHasNoKeyFrameFlag() {
    #expect(QUICVideoWire.frameHeader(sequence: 1, isKeyFrame: false, capturedAtUptimeNanos: 0)[1] == 0)
  }
}

@Suite
struct AnnexBKeyFrameDetectorTests {

  private func accessUnit(_ nalHeaders: [UInt8]) -> Data {
    Data(nalHeaders.flatMap { [0, 0, 0, 1, $0, 0xaa, 0xbb] })
  }

  @Test
  func hevcParameterSetsAndIRAPSlicesAreKeyFrames() {
    // VPS (32) first, as the Annex-B writer puts the parameter sets ahead of a keyframe.
    #expect(AnnexBKeyFrameDetector.isKeyFrame(accessUnit([32 << 1, 33 << 1, 34 << 1, 19 << 1]), codec: .hevc))
    // IDR_W_RADL on its own.
    #expect(AnnexBKeyFrameDetector.isKeyFrame(accessUnit([19 << 1]), codec: .hevc))
  }

  @Test
  func hevcTrailingSlicesAreNotKeyFrames() {
    #expect(!AnnexBKeyFrameDetector.isKeyFrame(accessUnit([1 << 1]), codec: .hevc))
    // A prefix SEI (39) before the slice does not change that.
    #expect(!AnnexBKeyFrameDetector.isKeyFrame(accessUnit([39 << 1, 1 << 1]), codec: .hevc))
  }

  @Test
  func h264SPSAndIDRAreKeyFramesAndOtherSlicesAreNot() {
    #expect(AnnexBKeyFrameDetector.isKeyFrame(accessUnit([0x67, 0x68, 0x65]), codec: .h264))
    #expect(!AnnexBKeyFrameDetector.isKeyFrame(accessUnit([0x06, 0x41]), codec: .h264))
  }
}

@Suite
struct QUICStreamFramingTests {

  @Test
  func theStreamHeaderCarriesTheLengthInTwentyFourBytes() {
    let header = QUICVideoWire.streamFrameHeader(length: 0x01_0203, sequence: 7, isKeyFrame: false, capturedAtUptimeNanos: 9)
    #expect(header.count == QUICVideoWire.streamFrameHeaderLength)
    #expect(Array(header.prefix(8)) == [2, 0, 0, 0, 0x00, 0x01, 0x02, 0x03])
    #expect(QUICVideoWire.uint64(bigEndian: Array(header)[8..<16]) == 7)
    #expect(QUICVideoWire.uint64(bigEndian: Array(header)[16..<24]) == 9)
  }
}

@Suite
struct QUICAudioFramingTests {

  @Test
  func anAudioPacketHeaderCarriesItsLengthSequenceAndWhenItPlayed() {
    let header = QUICVideoWire.audioPacketHeader(length: 0x0141, sequence: 7, startsRun: true, playedAtUptimeNanos: 0x0a0b)
    #expect(header.count == QUICVideoWire.audioPacketHeaderLength)
    #expect(Array(header.prefix(8)) == [3, 1, 0, 0, 0, 0, 0x01, 0x41])
    #expect(QUICVideoWire.uint64(bigEndian: Array(header)[8..<16]) == 7)
    #expect(QUICVideoWire.uint64(bigEndian: Array(header)[16..<24]) == 0x0a0b)
  }

  @Test
  func aPacketThatContinuesARunHasNoFlag() {
    #expect(QUICVideoWire.audioPacketHeader(length: 1, sequence: 1, startsRun: false, playedAtUptimeNanos: 0)[1] == 0)
  }

  @Test
  func theFirstByteTellsAnAudioStreamFromAFrame() {
    let audio = QUICVideoWire.audioPacketHeader(length: 1, sequence: 0, startsRun: true, playedAtUptimeNanos: 0)
    #expect(audio[0] != QUICVideoWire.frameHeader(sequence: 0, isKeyFrame: true, capturedAtUptimeNanos: 0)[0])
    #expect(audio[0] != QUICVideoWire.streamFrameHeader(length: 1, sequence: 0, isKeyFrame: true, capturedAtUptimeNanos: 0)[0])
  }
}

@Suite
struct QUICBackpressurePolicyTests {

  @Test
  func unsetOrUnparseableMeansTheStreamsOwnThreshold() {
    #expect(QUICBackpressurePolicy.parse(nil) == .default)
    #expect(QUICBackpressurePolicy.parse("nonsense") == .default)
    // The default reports the real count, so the stream's "more than two" rule applies unchanged.
    #expect(QUICBackpressurePolicy.default.reportedQueue(outstanding: 3, oldestSentAt: nil, now: 0) == 3)
  }

  @Test
  func aFrameCapDropsOnlyAboveTheCap() {
    let policy = QUICBackpressurePolicy.parse("frames=8")
    #expect(policy.maxFrames == 8 && policy.maxAgeNanos == nil)
    #expect(policy.reportedQueue(outstanding: 5, oldestSentAt: nil, now: 0) <= 2)
    #expect(policy.reportedQueue(outstanding: 9, oldestSentAt: nil, now: 0) > 2)
  }

  @Test
  func anAgeLimitDropsWhileTheOldestFrameWaitsTooLong() {
    let policy = QUICBackpressurePolicy.parse("frames=8,age=150")
    #expect(policy.maxAgeNanos == 150_000_000)
    #expect(policy.reportedQueue(outstanding: 1, oldestSentAt: 1_000_000_000, now: 1_100_000_000) <= 2)
    #expect(policy.reportedQueue(outstanding: 1, oldestSentAt: 1_000_000_000, now: 1_200_000_000) > 2)
  }
}

@Suite
struct QUICAdaptiveBitRateTests {

  private let config = QUICAdaptiveBitRate.parse("start=3000000,min=400000,max=8000000")!

  @Test
  func itIsOffUnlessConfigured() {
    #expect(QUICAdaptiveBitRate.parse(nil) == nil)
    #expect(QUICAdaptiveBitRate.parse("0") == nil)
  }

  @Test
  func queueingAboveTheHighMarkCutsTheRate() {
    #expect(config.next(current: 3_000_000, queueDelays: [60_000_000, 70_000_000, 80_000_000], drops: 0) == 2_100_000)
  }

  @Test
  func aClearPathRaisesTheRateUpToTheMaximum() {
    #expect(config.next(current: 3_000_000, queueDelays: [1_000_000, 2_000_000], drops: 0) == 3_150_000)
    #expect(config.next(current: 7_990_000, queueDelays: [1_000_000], drops: 0) == 8_000_000)
  }

  @Test
  func dropsWithModerateQueueingCutTheRateAndNothingObservedKeepsIt() {
    #expect(config.next(current: 1_000_000, queueDelays: [30_000_000], drops: 2) == 700_000)
    #expect(config.next(current: 1_000_000, queueDelays: [], drops: 0) == nil)
    #expect(config.next(current: 500_000, queueDelays: [90_000_000], drops: 0) == 400_000)
  }
}
