import CryptoKit
import Foundation
import Testing

/// scripts/verify-ed-signature.swift, which the release workflow runs on the appcast it is about
/// to publish, accepts only what an installed Ferry (Sparkle) accepts: the signed length must end
/// exactly where the feed's signature block begins.
struct FeedSignatureScriptTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let marker = "<!-- sparkle-signatures:\n"

  /// A feed as generate_appcast writes it: the content, then its signature and length.
  private struct SignedFeed {
    let feed: String
    let signature: String
    let length: Int

    init(_ content: String, with key: Curve25519.Signing.PrivateKey) throws {
      let signed = Data(content.utf8)
      signature = try key.signature(for: signed).base64EncodedString()
      length = signed.count
      feed =
        content
        + "\(FeedSignatureScriptTests.marker)edSignature: \(signature)\nlength: \(length)\n-->\n"
    }
  }

  /// The script's exit status. Compiling it takes seconds, so the wait is a termination
  /// callback, which keeps the shared pool's threads free for the other tests.
  private static func verify(_ feed: String, key: String, signature: String, length: Int)
    async throws -> Int32
  {
    let file = FileManager.default.temporaryDirectory
      .appending(path: "feed-\(UUID().uuidString).xml")
    try Data(feed.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = [
      "swift", root.appending(path: "scripts/verify-ed-signature.swift").path, key, signature,
      file.path, String(length),
    ]
    process.standardError = FileHandle.nullDevice
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }

  @Test func aFeedWhoseLengthEndsAtItsSignatureBlockVerifies() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let signed = try SignedFeed("<rss>one release</rss>", with: key)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    #expect(
      try await Self.verify(
        signed.feed, key: publicKey, signature: signed.signature, length: signed.length) == 0)
  }

  /// The signature still covers the first `length` bytes, but Sparkle checks the bytes before
  /// the block and refuses the feed: so must the script.
  @Test func bytesInsertedBeforeTheSignatureBlockAreRefused() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let signed = try SignedFeed("<rss>one release</rss>", with: key)
    let inserted = signed.feed.replacingOccurrences(
      of: Self.marker, with: "<!-- extra -->\n\(Self.marker)")
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    #expect(
      try await Self.verify(
        inserted, key: publicKey, signature: signed.signature, length: signed.length) == 1)
  }
}
