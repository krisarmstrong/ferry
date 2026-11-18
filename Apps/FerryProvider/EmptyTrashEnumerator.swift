import FileProvider

/// The trash, which is always empty: MTP has no trash, and domains are added without trash
/// syncing. A domain added before that still asks for it, and an error here would be retried
/// for as long as the domain exists.
final class EmptyTrashEnumerator: NSObject, NSFileProviderEnumerator {
  private static let anchor = NSFileProviderSyncAnchor(Data("empty".utf8))

  func invalidate() {}

  func enumerateItems(
    for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
  ) {
    observer.finishEnumerating(upTo: nil)
  }

  func enumerateChanges(
    for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
  ) {
    observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    completionHandler(Self.anchor)
  }
}
