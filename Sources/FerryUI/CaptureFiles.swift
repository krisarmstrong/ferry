import DeviceKit
import Foundation

/// Where the app saves screenshots and screen recordings: where macOS saves its own (the
/// `location` the Screenshot app sets in `com.apple.screencapture`), else the Desktop, under
/// names like macOS's own: `Screenshot <model> 2026-11-18 at 17.09.27.png`.
///
/// The app creates a hidden temporary file in the folder and sends it to the agent as a writable
/// descriptor; once the agent has filled it, the file is given the first free name (`… 2.png`,
/// `… 3.png`) in one step that fails rather than replace a file. A failed capture removes the
/// temporary file, so no partial file is ever left under a real name, nor at all. The agent, a
/// background process, never touches the user's folders.
enum CaptureFiles {
  enum Kind {
    case screenshot
    case recording
    case logcat

    var prefix: String {
      switch self {
      case .screenshot: "Screenshot"
      case .recording: "Screen Recording"
      case .logcat: "Logcat"
      }
    }

    var fileExtension: String {
      switch self {
      case .screenshot: "png"
      case .recording: "mp4"
      case .logcat: "txt"
      }
    }
  }

  static let temporaryPrefix = ".ferry-capture-"

  /// Where macOS saves screenshots now. Read from the preferences, never by running `defaults`.
  static func current() -> URL {
    let location =
      CFPreferencesCopyAppValue(
        "location" as CFString, "com.apple.screencapture" as CFString) as? String
    return folder(location: location, home: FileManager.default.homeDirectoryForCurrentUser)
  }

  static func desktop(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appending(path: "Desktop", directoryHint: .isDirectory)
  }

  /// `location` with `~` expanded, if it is an absolute path to a folder the agent can write;
  /// otherwise the Desktop.
  static func folder(
    location: String?, home: URL, usable: (URL) -> Bool = isWritableFolder
  ) -> URL {
    guard var path = location, !path.isEmpty else { return desktop(home: home) }
    if path == "~" || path.hasPrefix("~/") { path = home.path + path.dropFirst() }
    guard path.hasPrefix("/") else { return desktop(home: home) }
    let url = URL(filePath: path, directoryHint: .isDirectory)
    return usable(url) ? url : desktop(home: home)
  }

  static func isWritableFolder(_ url: URL) -> Bool {
    var isFolder: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
      && isFolder.boolValue && access(url.path, W_OK) == 0
  }

  /// Whether a new file can be created in `folder`: one is created and removed. Unlike a
  /// permission check, this sees a folder macOS denies Ferry (Desktop, Documents, Downloads
  /// without consent). Blocks while macOS asks the user, so never call it on the main thread.
  static func takesNewFiles(_ folder: URL) -> Bool {
    guard let (url, handle) = temporary(in: folder) else { return false }
    try? handle.close()
    unlink(url.path)
    return true
  }

  /// The name before any ` 2` and the extension, dated in `timeZone` as macOS dates its own.
  static func baseName(
    _ kind: Kind, model: String, at date: Date, timeZone: TimeZone = .current
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    func two(_ value: Int?) -> String {
      let text = String(value ?? 0)
      return text.count < 2 ? "0" + text : text
    }
    let day = "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))"
    let time = "\(two(parts.hour)).\(two(parts.minute)).\(two(parts.second))"
    return "\(kind.prefix) \(fileSafe(model)) \(day) at \(time)"
  }

  /// The device's model (which the device chose) as one path component: no `/` or `:`, no
  /// control or format characters (bidi overrides among them), no leading dot, at most 64
  /// characters.
  static func fileSafe(_ model: String) -> String {
    var safe = String.UnicodeScalarView()
    for scalar in model.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse,
        .unassigned:
        continue
      default:
        safe.append(scalar == "/" || scalar == ":" ? "-" : scalar)
      }
    }
    var text = String(safe).trimmingCharacters(in: .whitespaces)
    while text.hasPrefix(".") { text.removeFirst() }
    text = String(text.prefix(64)).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? "Android" : text
  }

  /// Deletes the hidden capture files older than `age` in `folders`: ones an app that quit or
  /// crashed mid-save left behind (a recording can be hundreds of MB). A capture under way is
  /// younger than any save takes.
  static func sweep(_ folders: [URL], olderThan age: TimeInterval = 3600, now: Date = Date()) {
    let manager = FileManager.default
    for folder in Set(folders) {
      guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
      for name in names where name.hasPrefix(temporaryPrefix) {
        let file = folder.appending(path: name)
        guard
          let modified = (try? manager.attributesOfItem(atPath: file.path))?[.modificationDate]
            as? Date,
          now.timeIntervalSince(modified) > age
        else { continue }
        unlink(file.path)
      }
    }
  }

  /// A new hidden file in `folder`, open for writing; `nil` if the folder cannot take one (it is
  /// gone, read-only, or macOS denies Ferry access to it).
  static func temporary(in folder: URL) -> (url: URL, handle: FileHandle)? {
    let url = folder.appending(path: temporaryPrefix + UUID().uuidString)
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { return nil }
    return (url, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
  }

  /// Gives the finished temporary file at `url` the first free name for `base` in its folder.
  /// Never replaces a file.
  static func place(_ url: URL, base: String, fileExtension: String) throws(TransportError)
    -> URL
  {
    let folder = url.deletingLastPathComponent()
    for number in 1...999 {
      let name = number == 1 ? "\(base).\(fileExtension)" : "\(base) \(number).\(fileExtension)"
      let target = folder.appending(path: name)
      if renamex_np(url.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
      guard errno == EEXIST else {
        throw .io("cannot name the file: \(String(cString: strerror(errno)))")
      }
    }
    throw .io("no free name for \(base)")
  }
}
