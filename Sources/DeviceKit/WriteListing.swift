import Synchronization

/// One write's listing of its destination folder, shared by the checks the write makes.
///
/// `SafeWriter.write` lists the folder to find what the new file would collide with; the
/// session's upload and rename then check the same names again. Each listing reads every item
/// in the folder from the device, which on MTP is one request per object, so a write sets this
/// for its task: a session records the listing it takes, serves the write's later checks from
/// it, and keeps it up to date with the write's own changes. Nothing outside the write uses it:
/// every other request lists afresh. A session drops its entry whenever an operation in the
/// folder fails, so a later check lists again.
public final class WriteListing: Sendable {
  /// The listing scope of the write the current task is running; `nil` outside one.
  @TaskLocal public static var current: WriteListing?

  private let listings = Mutex<[String: any Sendable]>([:])

  public init() {}

  /// What the session recorded for `key`, if it is a `T`.
  public func value<T: Sendable>(for key: String, as type: T.Type) -> T? {
    listings.withLock { $0[key] as? T }
  }

  public func record(_ value: some Sendable, for key: String) {
    listings.withLock { $0[key] = value }
  }

  /// Runs `body` with this as the current write's listing.
  public func run<T: Sendable>(_ body: () async throws(TransportError) -> T)
    async throws(TransportError) -> T
  {
    let result = await Self.$current.withValue(self) { () async -> Result<T, TransportError> in
      do throws(TransportError) {
        return .success(try await body())
      } catch {
        return .failure(error)
      }
    }
    return try result.get()
  }

  public func forget(_ key: String) {
    _ = listings.withLock { $0.removeValue(forKey: key) }
  }
}
