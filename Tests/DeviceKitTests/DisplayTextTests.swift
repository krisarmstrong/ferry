import Testing

@testable import DeviceKit

struct DisplayTextTests {
  @Test func plainTextIsUnchanged() {
    #expect(DisplayText.escaped("IMG_0001 café 写真.jpg") == "IMG_0001 café 写真.jpg")
  }

  static let ascii: [(String, String)] = [("a\u{1B}[2Jb", "a\\u{1B}[2Jb"), ("a\rb", "a\\u{D}b")]
  static let more: [(String, String)] = [("a\nb", "a\\u{A}b"), ("a\tb", "a\\u{9}b")]
  static let del: [(String, String)] = [("a\u{7F}b", "a\\u{7F}b"), ("a\u{0}b", "a\\u{0}b")]
  static let c1Control: [(String, String)] = [("a\u{9B}b", "a\\u{9B}b")]
  static let bidi: [(String, String)] = [("a\u{202E}b", "a\\u{202E}b")]
  static let isolates: [(String, String)] = [("\u{2066}b\u{2069}", "\\u{2066}b\\u{2069}")]
  static let marks: [(String, String)] = [("a\u{200E}\u{200F}", "a\\u{200E}\\u{200F}")]
  static let separators: [(String, String)] = [("a\u{2028}b", "a\\u{2028}b")]
  static let paragraph: [(String, String)] = [("a\u{2029}b", "a\\u{2029}b")]
  static let arabicMark: [(String, String)] = [("a\u{61C}b", "a\\u{61C}b")]
  static let backslash: [(String, String)] = [("a\\b", "a\\\\b")]
  static let literalEscape: [(String, String)] = [("\\u{1B}", "\\\\u{1B}")]
  static let cases =
    ascii + separators + paragraph + arabicMark + backslash + literalEscape
    + more + del + c1Control + bidi + isolates + marks

  @Test func joinersAndVariationSelectorsSurvive() {
    let name = "👩\u{200D}💻 क्\u{200C}ष ✈\u{FE0F}.jpg"
    #expect(DisplayText.escaped(name) == name)
  }

  @Test(arguments: cases)
  func controlsAreEscaped(input: String, expected: String) {
    #expect(DisplayText.escaped(input) == expected)
  }
}
