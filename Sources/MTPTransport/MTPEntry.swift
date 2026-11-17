import Foundation

/// One object as libmtp reports it, before it is placed at a `RemotePath`.
struct MTPEntry: Sendable, Equatable {
  let objectID: UInt32
  let name: String
  let isFolder: Bool
  let size: UInt64
  let modified: Date
}
