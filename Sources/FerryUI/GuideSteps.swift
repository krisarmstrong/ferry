import Foundation

/// The groups of devices that share one set of file-transfer steps. The raw value names the
/// family in help links (`guide:<rawValue>`).
public enum DeviceFamily: String, Sendable, CaseIterable, Hashable {
  /// LinkRunner 10G, LinkRunner 100G and EtherScope nXG, which share one Android 8 board.
  /// AirCheck G3 runs on a different board with different steps, and gets its own case later.
  case netAllyAndroid8Board
  case otherAndroid8to9
  case otherAndroid10Plus

  /// The name the model picker shows, NetAlly models first.
  public var title: LocalizedStringResource {
    switch self {
    case .netAllyAndroid8Board:
      LocalizedStringResource(
        "NetAlly LinkRunner 10G, LinkRunner 100G or EtherScope nXG", bundle: .module)
    case .otherAndroid8to9:
      LocalizedStringResource("Other Android phone (Android 8 or 9)", bundle: .module)
    case .otherAndroid10Plus:
      LocalizedStringResource("Other Android phone (Android 10 or newer)", bundle: .module)
    }
  }
}

/// How to turn on file transfer, per device family. The NetAlly steps follow each model's
/// AllyWare 3.x user guide ("Using a USB Type-C to USB Cable"); the guides say "PC or tablet",
/// so these name the Mac instead.
public enum GuideSteps {
  /// Model names as the devices report them, lowercased with spaces and punctuation removed.
  private static let netAllyAndroid8Models: Set<String> = [
    "linkrunner10g", "linkrunner100g", "etherscopenxg",
  ]

  /// The family of a reported model name, ignoring case, spaces, hyphens and a leading
  /// "NetAlly". `nil` for a model Ferry has no specific steps for.
  public static func family(forModel model: String) -> DeviceFamily? {
    var key = String(
      String.UnicodeScalarView(
        model.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    if key.hasPrefix("netally") { key.removeFirst("netally".count) }
    return netAllyAndroid8Models.contains(key) ? .netAllyAndroid8Board : nil
  }

  public static func steps(for family: DeviceFamily) -> [LocalizedStringResource] {
    switch family {
    case .netAllyAndroid8Board:
      [
        LocalizedStringResource(
          """
          Connect a USB-C cable to the **USB-C port on the left side** of the unit and to the \
          Mac.
          """, bundle: .module),
        LocalizedStringResource(
          """
          On the unit: **Settings** (bottom of the Home screen) → **Connected devices** → \
          **USB**.
          """, bundle: .module),
        LocalizedStringResource("Tap **Transfer files**.", bundle: .module),
      ]
    case .otherAndroid8to9:
      [
        unlockAndConnect,
        LocalizedStringResource(
          "Pull down the notification shade and tap **USB charging this device**.",
          bundle: .module),
        LocalizedStringResource("Tap **Transfer files**.", bundle: .module),
      ]
    case .otherAndroid10Plus:
      [
        unlockAndConnect,
        LocalizedStringResource(
          "Pull down the notification shade and tap **Charging this device via USB**.",
          bundle: .module),
        LocalizedStringResource(
          """
          Under **USB preferences**, choose **File transfer**. Or open **Settings** → \
          **Connected devices** → **USB**.
          """, bundle: .module),
      ]
    }
  }

  private static let unlockAndConnect = LocalizedStringResource(
    """
    Unlock the phone and connect it to the Mac with a USB cable. Its storage stays hidden while \
    it is locked.
    """, bundle: .module)
}
