import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// What FileProvider hands the extension for a new or changed item.
final class Template: NSObject, NSFileProviderItem {
  let itemIdentifier: NSFileProviderItemIdentifier
  let parentItemIdentifier: NSFileProviderItemIdentifier
  let filename: String
  let contentType: UTType

  init(
    id: String = "new", parent: NSFileProviderItemIdentifier, filename: String,
    contentType: UTType = .data
  ) {
    itemIdentifier = NSFileProviderItemIdentifier(id)
    parentItemIdentifier = parent
    self.filename = filename
    self.contentType = contentType
  }
}

func scratchDirectory() throws -> URL {
  let dir = TestScratch.root.appending(
    path: "FerryProviderCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

func writeContents(_ data: Data, in dir: URL) throws -> URL {
  let url = dir.appending(path: "upload-\(UUID().uuidString)")
  try data.write(to: url)
  return url
}
