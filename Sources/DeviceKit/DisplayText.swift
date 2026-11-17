/// Makes device-supplied text safe to print: a hostile phone can name a file with terminal
/// escape sequences or bidi overrides, so those become visible `\u{XX}` escapes.
public enum DisplayText {
  public static func escaped(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      if isUnsafe(scalar) {
        result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
    default: scalar.properties.generalCategory == .control
    }
  }
}
