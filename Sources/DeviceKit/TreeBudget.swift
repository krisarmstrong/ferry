/// How much of a folder tree (a package, a bundle) Ferry will walk and copy in one go.
///
/// The tree can come from the device, which Ferry does not trust: one that is deeper, holds more
/// entries or more bytes than this is refused with `.packageTooLarge` before it can exhaust the
/// stack, the disk or the user's patience.
public struct TreeBudget: Sendable, Equatable {
  public let maxDepth: Int
  public let maxEntries: Int
  public let maxBytes: UInt64

  /// Folders 32 deep, 100,000 entries, 8 GiB.
  public static let standard = TreeBudget(maxDepth: 32, maxEntries: 100_000, maxBytes: 8 << 30)

  public init(maxDepth: Int, maxEntries: Int, maxBytes: UInt64) {
    self.maxDepth = maxDepth
    self.maxEntries = maxEntries
    self.maxBytes = maxBytes
  }

  /// What a walk has used of a budget so far.
  public struct Usage: Sendable {
    public let budget: TreeBudget
    public private(set) var entries = 0
    public private(set) var bytes: UInt64 = 0

    public init(_ budget: TreeBudget) {
      self.budget = budget
    }

    /// Counts one entry `depth` folders below the tree's root, of `size` bytes.
    public mutating func add(depth: Int, size: UInt64 = 0) throws(TransportError) {
      entries += 1
      let (total, overflow) = bytes.addingReportingOverflow(size)
      bytes = total
      guard depth <= budget.maxDepth, entries <= budget.maxEntries, !overflow,
        total <= budget.maxBytes
      else { throw .packageTooLarge }
    }
  }
}
