import Foundation

/// The groups of devices that share one set of file-transfer steps. The raw value names the
/// family in help links (`guide:<rawValue>`).
public enum DeviceFamily: String, Sendable, CaseIterable, Hashable {
  /// LinkRunner 10G, LinkRunner 100G and EtherScope nXG, which share one Android 8 board, and
  /// the CyberScope, built on the EtherScope nXG.
  case netAllyAndroid8Board
  /// The AirCheck G3, on a newer Android and another board. No unit has been checked against
  /// its steps yet, so they are Android's own, worded for a tester.
  case airCheckG3
  case otherAndroid8to9
  case otherAndroid10Plus

  /// The name the model picker shows, the testers first, by their model names alone.
  public var title: LocalizedStringResource {
    switch self {
    case .netAllyAndroid8Board:
      LocalizedStringResource(
        "LinkRunner 10G, LinkRunner 100G, EtherScope nXG or CyberScope", bundle: .module)
    case .airCheckG3:
      LocalizedStringResource("AirCheck G3 (Wi-Fi tester)", bundle: .module)
    case .otherAndroid8to9:
      LocalizedStringResource("Other Android phone (Android 8 or 9)", bundle: .module)
    case .otherAndroid10Plus:
      LocalizedStringResource("Other Android phone (Android 10 or newer)", bundle: .module)
    }
  }
}

/// What the setup guide walks through.
public enum GuideTopic: String, Sendable, CaseIterable, Hashable {
  case fileTransfer
  case usbDebugging

  public var title: LocalizedStringResource {
    switch self {
    case .fileTransfer: LocalizedStringResource("File transfer", bundle: .module)
    case .usbDebugging: LocalizedStringResource("USB debugging", bundle: .module)
    }
  }
}

/// How to turn on file transfer and USB debugging, per device family. The NetAlly steps follow
/// each model's AllyWare 3.x user guide ("Using a USB Type-C to USB Cable"); the guides say "PC
/// or tablet", so these name the Mac instead.
public enum GuideSteps {
  /// Model names as the devices report them, lowercased with spaces and punctuation removed.
  private static let netAllyAndroid8Models: Set<String> = [
    "linkrunner10g", "linkrunner100g", "etherscopenxg",
  ]

  /// The family of a reported model name, ignoring case, spaces, hyphens and a leading
  /// "NetAlly". `nil` for a model Ferry has no specific steps for. The CyberScope and AirCheck
  /// G3 are matched by the start of their names, which no unit's report has confirmed yet.
  public static func family(forModel model: String) -> DeviceFamily? {
    var key = String(
      String.UnicodeScalarView(
        model.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    if key.hasPrefix("netally") { key.removeFirst("netally".count) }
    if netAllyAndroid8Models.contains(key) || key.hasPrefix("cyberscope") {
      return .netAllyAndroid8Board
    }
    return key.hasPrefix("aircheckg3") ? .airCheckG3 : nil
  }

  /// The steps for `topic` on `family`: file transfer unless asked for USB debugging.
  public static func steps(
    for family: DeviceFamily, topic: GuideTopic = .fileTransfer
  ) -> [LocalizedStringResource] {
    switch topic {
    case .fileTransfer: transferSteps(for: family)
    case .usbDebugging: debuggingSteps(for: family)
    }
  }

  /// The line under every family's USB debugging steps: a device that already accepts ADB over
  /// the network needs no cable.
  public static let debuggingNote = LocalizedStringResource(
    "If the device accepts ADB over the network, use **Connect by Address…**.", bundle: .module)

  private static func debuggingSteps(for family: DeviceFamily) -> [LocalizedStringResource] {
    switch family {
    case .netAllyAndroid8Board:
      // NetAlly enables ADB on a tester itself; how is NetAlly's to share, so the guide only
      // says to ask.
      [
        LocalizedStringResource("Ask NetAlly to enable ADB on the tester.", bundle: .module),
        LocalizedStringResource(
          """
          After that, on the tester: **Settings** → **System** → **About tester**. Tap \
          **Build number** until developer mode is on.
          """, bundle: .module),
        LocalizedStringResource(
          "Go to **Settings** → **System** → **Developer options** and turn on **USB debugging**.",
          bundle: .module),
        LocalizedStringResource(
          """
          With the USB-C cable connected to the Mac, turn **USB debugging** off and on again. \
          The tester offers ADB only after this.
          """, bundle: .module),
        promptOK,
      ]
    case .airCheckG3: airCheckDebugging
    case .otherAndroid8to9:
      [
        unlockAndConnect,
        LocalizedStringResource(
          """
          Open **Settings** → **System** → **About phone** and tap **Build number** until \
          developer mode is on.
          """, bundle: .module),
        LocalizedStringResource(
          "Open **Settings** → **System** → **Developer options** and turn on **USB debugging**.",
          bundle: .module),
        promptOK,
      ]
    case .otherAndroid10Plus:
      [
        unlockAndConnect,
        LocalizedStringResource(
          """
          Open **Settings** → **About phone** and tap **Build number** until developer mode is \
          on.
          """, bundle: .module),
        LocalizedStringResource(
          "Open **Settings** → **System** → **Developer options** and turn on **USB debugging**.",
          bundle: .module),
        promptAllow,
      ]
    }
  }

  /// Android's own steps, worded for the tester: no unit has been checked against them.
  private static let airCheckDebugging: [LocalizedStringResource] =
    [
      LocalizedStringResource(
        """
        On the tester, open **Settings**, find **Build number** (usually under **About**) and \
        tap it until developer mode is on.
        """, bundle: .module),
      LocalizedStringResource(
        "On the tester, open **Developer options** in **Settings** and turn on **USB debugging**.",
        bundle: .module),
      promptAllow,
    ]

  private static func transferSteps(for family: DeviceFamily) -> [LocalizedStringResource] {
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
    case .airCheckG3:
      [
        LocalizedStringResource("Connect the tester to the Mac with a USB cable.", bundle: .module),
        LocalizedStringResource(
          "On the tester, pull down the notification shade and tap the USB notification.",
          bundle: .module),
        usbPreferences,
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
        usbPreferences,
      ]
    }
  }

  private static let usbPreferences = LocalizedStringResource(
    """
    Under **USB preferences**, choose **File transfer**. Or open **Settings** → \
    **Connected devices** → **USB**.
    """, bundle: .module)

  /// The USB debugging prompt names its button OK on Android 8 and 9, Allow on 10 and newer.
  private static let promptOK = LocalizedStringResource(
    "On the device, tick **Always allow from this computer** and tap **OK**.",
    bundle: .module)

  private static let promptAllow = LocalizedStringResource(
    "On the device, tick **Always allow from this computer** and tap **Allow**.",
    bundle: .module)

  private static let unlockAndConnect = LocalizedStringResource(
    """
    Unlock the phone and connect it to the Mac with a USB cable. Its storage stays hidden while \
    it is locked.
    """, bundle: .module)
}
