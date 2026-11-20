// Checks an EdDSA (Ed25519) signature against a public key, as Sparkle does in an installed
// Ferry, using only the public key. The release workflow runs it on the appcast it publishes.
//
// Usage: xcrun swift scripts/verify-ed-signature.swift <public-key> <signature> <file> [length]
// The key and the signature are base64. With `length`, the file is an appcast: its first
// `length` bytes are signed and its signature block must begin exactly there, as Sparkle checks.
// Exits 0 when the signature is valid, 1 when it is not, 2 on unusable arguments.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 3 || arguments.count == 4 else {
  FileHandle.standardError.write(
    Data("usage: verify-ed-signature <key> <signature> <file> [length]\n".utf8))
  exit(2)
}
let values = Array(arguments)
guard let keyData = Data(base64Encoded: values[0]),
  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
  let signature = Data(base64Encoded: values[1]),
  var message = FileManager.default.contents(atPath: values[2])
else {
  FileHandle.standardError.write(Data("error: unreadable key, signature or file\n".utf8))
  exit(2)
}
if values.count == 4 {
  guard let length = Int(values[3]), (0...message.count).contains(length) else { exit(2) }
  let block = Data("<!-- sparkle-signatures:\n".utf8)
  guard let start = message.lastRange(of: block)?.lowerBound, start == length else {
    FileHandle.standardError.write(
      Data("error: the signed length does not end where the signature block begins\n".utf8))
    exit(1)
  }
  message = message.prefix(length)
}
exit(key.isValidSignature(signature, for: message) ? 0 : 1)
