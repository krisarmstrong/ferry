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

  /// Every string, with sample values, so a test can check each has its catalog entry.
  static let all: [LocalizedStringResource] = [
    conflictMarker(attempt: 1), conflictMarker(attempt: 2), disconnected,
  ]
}
