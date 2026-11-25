/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CryptoKit
import Foundation
import Network
import Security

enum QUICSessionIdentityError: Error, LocalizedError {
  case keyImportFailed(String)
  case certificateImportFailed
  case identityCreationFailed

  var errorDescription: String? {
    switch self {
    case let .keyImportFailed(reason):
      return "Failed to import the QUIC session key: \(reason)"
    case .certificateImportFailed:
      return "Failed to import the QUIC session certificate"
    case .identityCreationFailed:
      return "Failed to create the QUIC session identity"
    }
  }
}

/// The TLS identity a QUIC video session presents: a fresh P-256 key and a self-signed certificate
/// for it, made in memory for one session and never written to disk or a keychain.
///
/// Nothing on the network vouches for the certificate. The client learns its SHA-256 fingerprint
/// over the gRPC call that started the session and accepts the QUIC handshake only if the
/// certificate presented hashes to it, so the certificate needs no name, chain or trust settings.
struct QUICSessionIdentity {
  let identity: sec_identity_t
  /// The SHA-256 digest of the certificate's DER encoding.
  let certificateSHA256: Data

  static func make(commonName: String = "idb-companion", lifetime: TimeInterval = 7 * 24 * 60 * 60) throws -> QUICSessionIdentity {
    let privateKey = P256.Signing.PrivateKey()
    let certificateDER = try selfSignedCertificate(for: privateKey, commonName: commonName, lifetime: lifetime)

    var error: Unmanaged<CFError>?
    guard
      let secKey = unsafe SecKeyCreateWithData(
        privateKey.x963Representation as CFData,
        [
          kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
          kSecAttrKeyClass: kSecAttrKeyClassPrivate,
          kSecAttrKeySizeInBits: 256,
        ] as CFDictionary,
        &error)
    else {
      let reason = unsafe error.map { "\($0.takeRetainedValue())" } ?? "unknown error"
      throw QUICSessionIdentityError.keyImportFailed(reason)
    }
    guard let certificate = SecCertificateCreateWithData(nil, Data(certificateDER) as CFData) else {
      throw QUICSessionIdentityError.certificateImportFailed
    }
    guard let secIdentity = SecIdentityCreate(nil, certificate, secKey), let identity = sec_identity_create(secIdentity) else {
      throw QUICSessionIdentityError.identityCreationFailed
    }
    return QUICSessionIdentity(identity: identity, certificateSHA256: Data(SHA256.hash(data: certificateDER)))
  }

  /// A minimal X.509 v3 certificate, self-signed with ECDSA-SHA256, with no extensions.
  static func selfSignedCertificate(for key: P256.Signing.PrivateKey, commonName: String, lifetime: TimeInterval) throws -> [UInt8] {
    let ecdsaWithSHA256 = DER.sequence(DER.objectIdentifier([1, 2, 840, 10045, 4, 3, 2]))
    let name = DER.sequence(DER.set(DER.sequence(DER.objectIdentifier([2, 5, 4, 3]), DER.utf8String(commonName))))
    let now = Date()
    var serial = [UInt8](repeating: 0, count: 16)
    for index in serial.indices {
      serial[index] = UInt8.random(in: 0...255)
    }
    let tbsCertificate = DER.sequence(
      DER.explicit(0, DER.integer([2])),
      DER.integer(serial),
      ecdsaWithSHA256,
      name,
      DER.sequence(DER.utcTime(now.addingTimeInterval(-60 * 60)), DER.utcTime(now.addingTimeInterval(lifetime))),
      name,
      Array(key.publicKey.derRepresentation))
    let signature = try key.signature(for: Data(tbsCertificate)).derRepresentation
    return DER.sequence(tbsCertificate, ecdsaWithSHA256, DER.bitString(Array(signature)))
  }
}

/// Just enough DER to write the certificate above.
enum DER {
  static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
    [tag] + length(content.count) + content
  }

  static func length(_ count: Int) -> [UInt8] {
    if count < 0x80 {
      return [UInt8(count)]
    }
    var bytes: [UInt8] = []
    var remaining = count
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xff), at: 0)
      remaining >>= 8
    }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  static func sequence(_ elements: [UInt8]...) -> [UInt8] {
    tlv(0x30, elements.flatMap { $0 })
  }

  static func set(_ elements: [UInt8]...) -> [UInt8] {
    tlv(0x31, elements.flatMap { $0 })
  }

  static func explicit(_ tagNumber: UInt8, _ content: [UInt8]) -> [UInt8] {
    tlv(0xa0 | tagNumber, content)
  }

  /// A non-negative INTEGER from big-endian magnitude bytes.
  static func integer(_ magnitude: [UInt8]) -> [UInt8] {
    var bytes = Array(magnitude.drop { $0 == 0 })
    if bytes.isEmpty || bytes[0] & 0x80 != 0 {
      bytes.insert(0, at: 0)
    }
    return tlv(0x02, bytes)
  }

  static func objectIdentifier(_ arcs: [UInt64]) -> [UInt8] {
    var bytes = base128(arcs[0] * 40 + arcs[1])
    for arc in arcs.dropFirst(2) {
      bytes += base128(arc)
    }
    return tlv(0x06, bytes)
  }

  static func utf8String(_ string: String) -> [UInt8] {
    tlv(0x0c, Array(string.utf8))
  }

  static func utcTime(_ date: Date) -> [UInt8] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyMMddHHmmss'Z'"
    return tlv(0x17, Array(formatter.string(from: date).utf8))
  }

  static func bitString(_ bytes: [UInt8]) -> [UInt8] {
    tlv(0x03, [0] + bytes)
  }

  private static func base128(_ value: UInt64) -> [UInt8] {
    var bytes = [UInt8(value & 0x7f)]
    var remaining = value >> 7
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0x7f) | 0x80, at: 0)
      remaining >>= 7
    }
    return bytes
  }
}
