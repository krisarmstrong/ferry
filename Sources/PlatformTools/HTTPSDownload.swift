import Foundation
import os

/// The real download: an ephemeral session over HTTPS, written into the fetcher's staging folder
/// as it arrives and stopped as soon as it passes the pinned size. A redirect is followed only
/// over HTTPS to the hosts Google serves the platform tools from; a refused one, or a final
/// answer that is not a 200 over HTTPS from those hosts, fails without keeping anything.
public enum HTTPSDownload {
  public static func file(from url: URL, limit: Int, into folder: URL)
    async throws(PlatformToolsError) -> URL
  {
    try await file(from: url, limit: limit, into: folder, configuration: .ephemeral)
  }

  /// How long the whole download may take. About 16 MB in five minutes is well under any
  /// working connection; a host that drips bytes, which keeps the idle timeout from firing,
  /// cannot hold the fetch longer than this.
  static let resourceTimeout = Duration.seconds(300)

  static func file(
    from url: URL, limit: Int, into folder: URL, configuration: URLSessionConfiguration,
    resourceTimeout: Duration = resourceTimeout
  ) async throws(PlatformToolsError) -> URL {
    guard !Task.isCancelled else { throw .cancelled }
    let file = folder.appending(path: "download-\(UUID().uuidString).zip")
    guard
      FileManager.default.createFile(
        atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
      let handle = try? FileHandle(forWritingTo: file)
    else { throw .storage }
    let configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
    configuration.timeoutIntervalForResource = resourceTimeout / .seconds(1)
    let transfer = Transfer(handle: handle, limit: limit)
    let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: url)
    let failure: PlatformToolsError? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        transfer.start(task, continuation)
      }
    } onCancel: {
      task.cancel()
    }
    try? handle.close()
    if let failure {
      try? FileManager.default.removeItem(at: file)
      throw failure
    }
    return file
  }

  /// dl.google.com, where the pin points, and the content hosts Google redirects its downloads
  /// to: `*.gvt1.com` (its download redirector) and `*.googleusercontent.com`. HTTPS only.
  static func isAllowed(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else {
      return false
    }
    return host == "dl.google.com" || host.hasSuffix(".gvt1.com")
      || host.hasSuffix(".googleusercontent.com")
  }

  /// No connection is `offline`, which the menu words as needing the internet once.
  static func failure(_ error: URLError) -> PlatformToolsError {
    switch error.code {
    case .cancelled:
      .cancelled
    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed,
      .callIsActive:
      .offline
    case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
      .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
      .serverCertificateHasUnknownRoot, .clientCertificateRejected:
      .insecureAddress
    default:
      .downloadFailed
    }
  }
}

/// One download's session delegate: writes what arrives, counts it against the limit, and
/// reports how the transfer ended, once. The first reason to stop wins: a refused redirect stays
/// `insecureAddress` though the session then delivers the 3xx.
private final class Transfer: NSObject, URLSessionDataDelegate, Sendable {
  private struct State {
    var received = 0
    var failure: PlatformToolsError?
    var continuation: CheckedContinuation<PlatformToolsError?, Never>?
  }

  private let handle: FileHandle
  private let limit: Int
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(handle: FileHandle, limit: Int) {
    self.handle = handle
    self.limit = limit
  }

  func start(
    _ task: URLSessionTask, _ continuation: CheckedContinuation<PlatformToolsError?, Never>
  ) {
    state.withLock { $0.continuation = continuation }
    task.resume()
  }

  /// Records why the transfer stops, unless it already has a reason.
  private func stop(_ task: URLSessionTask, _ failure: PlatformToolsError) {
    state.withLock { if $0.failure == nil { $0.failure = failure } }
    task.cancel()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let url = request.url, HTTPSDownload.isAllowed(url) else {
      stop(task, .insecureAddress)
      return nil
    }
    return request
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
  ) async -> URLSession.ResponseDisposition {
    guard let http = response as? HTTPURLResponse, let url = http.url,
      HTTPSDownload.isAllowed(url)
    else {
      stop(dataTask, .insecureAddress)
      return .cancel
    }
    guard http.statusCode == 200 else {
      stop(dataTask, .downloadFailed)
      return .cancel
    }
    guard http.expectedContentLength <= Int64(limit) else {
      stop(dataTask, .mismatch)
      return .cancel
    }
    return .allow
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let received = state.withLock { state in
      state.received += data.count
      return state.received
    }
    guard received <= limit else { return stop(dataTask, .mismatch) }
    do {
      try handle.write(contentsOf: data)
    } catch {
      stop(dataTask, .storage)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let (continuation, failure) = state.withLock { state in
      defer { state.continuation = nil }
      let failure =
        state.failure ?? (error as? URLError).map(HTTPSDownload.failure)
        ?? (error == nil ? nil : .downloadFailed)
      return (state.continuation, failure)
    }
    continuation?.resume(returning: failure)
  }
}
