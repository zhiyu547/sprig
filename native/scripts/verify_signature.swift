// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
import Foundation
import CryptoKit

// Only public data appears on the command line. Never accepts a private key.
guard CommandLine.arguments.count == 4,
      let rawKey = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64 else {
    fputs("Usage: verify_signature.swift file public-key signature\n", stderr); exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard key.isValidSignature(signature, for: data) else {
        fputs("Signature verification failed\n", stderr); exit(1)
    }
    print("Signature verified")
} catch { fputs("Signature verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
