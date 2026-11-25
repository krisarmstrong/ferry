import Foundation

/// Changes the system saved aside when a location was removed before they reached the device.
extension AppModel {
  /// Whether a location the system saved unsent changes to has anything in it: it can name a
  /// folder it left empty, or one already gone.
  static func holdsSomething(_ location: URL) -> Bool {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isFolder) else {
      return false
    }
    guard isFolder.boolValue else { return true }
    let contents = try? FileManager.default.contentsOfDirectory(atPath: location.path)
    return !(contents ?? []).isEmpty
  }

  /// Adds `saved` to the locations shown and drops any that no longer hold anything (the user
  /// moved the files back, or deleted them). A later action never hides one that still does:
  /// the files there reached no device.
  func keepPreservedChanges(adding saved: [URL] = []) {
    var kept: [URL] = []
    for location in preservedChanges + saved where !kept.contains(location) {
      if Self.holdsSomething(location) { kept.append(location) }
    }
    preservedChanges = kept
  }

  public func revealPreservedChanges() {
    services.reveal(preservedChanges)
  }
}
