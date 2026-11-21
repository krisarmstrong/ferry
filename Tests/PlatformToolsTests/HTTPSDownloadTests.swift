import Foundation
import Testing
import os

@testable import PlatformTools

/// Serves what each test path asks for, in place of the network: a session given this protocol
/// never leaves the process.
final class StubServer: URLProtocol, @unchecked Sendable {
  /// Each request a stub starts, by path, for a test waiting on it.
  static let started = OSAllocatedUnfairLock<[String: AsyncStream<Void>.Continuation]>(
    initialState: [:])

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  private func respond(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
  }

  override func startLoading() {
    guard let url = request.url, let client else { return }
    switch url.path {
    case "/ok":
      client.urlProtocol(self, didReceive: respond(200), cacheStoragePolicy: .notAllowed)
      client.urlProtocol(self, didLoad: Data(repeating: 7, count: 1000))
      client.urlProtocolDidFinishLoading(self)
    case "/missing":
      client.urlProtocol(self, didReceive: respond(404), cacheStoragePolicy: .notAllowed)
      client.urlProtocolDidFinishLoading(self)
    case "/to-http", "/to-elsewhere", "/to-gvt1", "/to-googleusercontent":
      let target = [
        "/to-http": "http://dl.google.com/ok", "/to-elsewhere": "https://downloads.example.com/ok",
        "/to-gvt1": "https://redirector.gvt1.com/ok",
        "/to-googleusercontent": "https://storage.googleusercontent.com/ok",
      ][url.path]!
      let redirect = URLRequest(url: URL(string: target)!)
      client.urlProtocol(
        self, wasRedirectedTo: redirect, redirectResponse: respond(302, ["Location": target]))
    case "/too-big":
      client.urlProtocol(self, didReceive: respond(200), cacheStoragePolicy: .notAllowed)
      for _ in 0..<10 { client.urlProtocol(self, didLoad: Data(repeating: 1, count: 200)) }
      client.urlProtocolDidFinishLoading(self)
    case "/drip":
      client.urlProtocol(self, didReceive: respond(200), cacheStoragePolicy: .notAllowed)
      client.urlProtocol(self, didLoad: Data(repeating: 1, count: 10))
    case "/stall":
      client.urlProtocol(self, didReceive: respond(200), cacheStoragePolicy: .notAllowed)
      client.urlProtocol(self, didLoad: Data(repeating: 1, count: 10))
      _ = Self.started.withLock { $0.removeValue(forKey: "/stall") }?.yield()
    default:
      client.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
  }

  override func stopLoading() {}
}

final class HTTPSDownloadTests: Sendable {
  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "ferry-download-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  private static var configuration: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubServer.self]
    return configuration
  }

  private func download(
    _ path: String, limit: Int = 1000,
    resourceTimeout: Duration = HTTPSDownload.resourceTimeout
  ) async throws(PlatformToolsError) -> URL {
    try await HTTPSDownload.file(
      from: URL(string: "https://dl.google.com\(path)")!, limit: limit, into: folder,
      configuration: Self.configuration, resourceTimeout: resourceTimeout)
  }

  /// What the download left in its folder.
  private func leftovers() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
  }

  @Test func aFileIsDownloadedIntoTheFolder() async throws {
    let file = try await download("/ok")
    #expect(file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    #expect(try Data(contentsOf: file) == Data(repeating: 7, count: 1000))
  }

  @Test func aStatusOtherThan200FailsAndLeavesNothing() async {
    await #expect(throws: PlatformToolsError.downloadFailed) { _ = try await download("/missing") }
    #expect(leftovers() == [])
  }

  /// A redirect is followed only over HTTPS to the hosts Google serves the archive from; a
  /// refused one is worded as an insecure address.
  @Test(arguments: ["/to-http", "/to-elsewhere"])
  func aRedirectOffGooglesHostsIsRefused(path: String) async {
    await #expect(throws: PlatformToolsError.insecureAddress) { _ = try await download(path) }
    #expect(leftovers() == [])
  }

  @Test(arguments: ["/to-gvt1", "/to-googleusercontent"])
  func aRedirectToGooglesDownloadHostsIsFollowed(path: String) async throws {
    let file = try await download(path)
    #expect(try Data(contentsOf: file).count == 1000)
  }

  /// More bytes than the pinned size are refused as they arrive, not after.
  @Test func aDownloadLargerThanThePinIsStopped() async {
    await #expect(throws: PlatformToolsError.mismatch) {
      _ = try await download("/too-big", limit: 1000)
    }
    #expect(leftovers() == [])
  }

  @Test func cancellingStopsTheDownloadAndLeavesNothing() async throws {
    let (started, signal) = AsyncStream<Void>.makeStream()
    StubServer.started.withLock { $0["/stall"] = signal }
    let task = Task { () async throws(PlatformToolsError) -> URL in try await download("/stall") }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    task.cancel()
    await #expect(throws: PlatformToolsError.cancelled) { _ = try await task.value }
    #expect(leftovers() == [])
  }

  /// A body that stops arriving ends at the resource timeout, worded as a download that could
  /// not finish (`offline`: "Couldn't download adb. Ferry needs an internet connection once.").
  /// Without it only the 60 s idle timeout would end it, and a host that drips bytes keeps that
  /// from ever firing.
  @Test func aStalledBodyTimesOut() async {
    let started = ContinuousClock.now
    await #expect(throws: PlatformToolsError.offline) {
      _ = try await download("/drip", resourceTimeout: .milliseconds(300))
    }
    #expect(started.duration(to: .now) < .seconds(30))
    #expect(leftovers() == [])
  }

  /// The real download gives up after a few minutes, not URLSession's default of seven days.
  @Test func theResourceTimeoutIsMinutes() {
    #expect(HTTPSDownload.resourceTimeout == .seconds(300))
  }

  @Test(arguments: [
    ("dl.google.com", true), ("redirector.gvt1.com", true), ("r1---sn-a.gvt1.com", true),
    ("storage.googleusercontent.com", true), ("gvt1.com.example.com", false),
    ("evilgvt1.com", false), ("google.com", false), ("dl.google.com.example.com", false),
  ])
  func onlyGooglesDownloadHostsAreAllowed(host: String, allowed: Bool) {
    #expect(HTTPSDownload.isAllowed(URL(string: "https://\(host)/x")!) == allowed)
    #expect(!HTTPSDownload.isAllowed(URL(string: "http://\(host)/x")!))
  }

  /// No connection is what the menu words as needing the internet once.
  @Test(arguments: [
    (URLError.Code.notConnectedToInternet, PlatformToolsError.offline), (.timedOut, .offline),
    (.cannotFindHost, .offline), (.networkConnectionLost, .offline), (.cancelled, .cancelled),
    (.serverCertificateUntrusted, .insecureAddress),
    (.appTransportSecurityRequiresSecureConnection, .insecureAddress),
    (.badServerResponse, .downloadFailed),
  ])
  func classifiesFailures(code: URLError.Code, expected: PlatformToolsError) {
    #expect(HTTPSDownload.failure(URLError(code)) == expected)
  }
}
