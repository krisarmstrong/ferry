import Foundation

/// The words the agent shows the user, from this target's String Catalog: in a conflict copy's
/// name on the device, and in Finder for a device that is away.
public enum AgentText {
  /// The marker in a conflict copy's name, without its brackets: `attempt` 1 has no number.
  static func conflictMarker(attempt: Int) -> LocalizedStringResource {
    attempt == 1
      ? LocalizedStringResource("conflict from Mac", bundle: .module)
      : LocalizedStringResource("conflict from Mac \(attempt)", bundle: .module)
  }

  /// Why a device's Finder location is disconnected, which Finder shows in the location.
  public static let disconnected = LocalizedStringResource(
    "Connect the device and choose Transfer files to see its files.", bundle: .module)

  /// A request the agent cannot read, or one without the file it needs.
  static let badRequest = LocalizedStringResource(
    "Ferry's helper couldn't read the request.", bundle: .module)

  /// A request the client's role may not send.
  static let notAllowed = LocalizedStringResource(
    "Ferry's helper doesn't take this request from here.", bundle: .module)

  /// The agent could not make the file it copies a recording into before the app gets it.
  static let recordingNotStaged = LocalizedStringResource(
    "Ferry's helper couldn't start copying the recording.", bundle: .module)

  /// Every string, with sample values, so a test can check each has its catalog entry.
  static let all: [LocalizedStringResource] = [
    conflictMarker(attempt: 1), conflictMarker(attempt: 2), disconnected, badRequest,
    notAllowed, recordingNotStaged,
  ]
}
