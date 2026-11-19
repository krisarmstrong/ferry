import DeviceKit
import Testing

struct DeviceNamesTests {
  private func names(_ devices: [(String, String)]) -> [String] {
    let listed = devices.map { (id: DeviceID(serial: $0.0), name: $0.1) }
    let suffixes = DeviceNames.suffixes(for: listed)
    return listed.map { DeviceNames.named($0.name, suffix: suffixes[$0.id]) }
  }

  @Test func aNameNoOtherDeviceHasStaysAsItIs() {
    #expect(
      names([("SER0000AAAA", "LinkRunner 10G"), ("SER0000BBBB", "Phone")])
        == ["LinkRunner 10G", "Phone"])
  }

  @Test func sameNamesTakeTheLastFourCharacters() {
    #expect(
      names([("SER0000AAAA", "LinkRunner 10G"), ("SER0000BBBB", "LinkRunner 10G")])
        == ["LinkRunner 10G (AAAA)", "LinkRunner 10G (BBBB)"])
  }

  /// Two units whose serials end alike get more characters, the same count for both, until
  /// they differ.
  @Test func sameEndingsTakeMoreCharactersUntilUnique() {
    #expect(
      names([
        ("0123456789abcdef", "LinkRunner-100G"), ("0b23456789abcdef", "LinkRunner-100G"),
        ("9999999989abcdef", "LinkRunner-100G"), ("ZZZZ", "Phone"),
      ]) == [
        "LinkRunner-100G (123456789abcdef)", "LinkRunner-100G (b23456789abcdef)",
        "LinkRunner-100G (999999989abcdef)", "Phone",
      ])
    #expect(
      names([("A5e72", "X"), ("B5e72", "X"), ("C1234", "X")])
        == ["X (A5e72)", "X (B5e72)", "X (C1234)"])
  }

  /// A serial that is the end of another's is told apart by the longer one's extra character.
  @Test func aSerialEndingAnotherIsToldApart() {
    #expect(names([("ABCD", "X"), ("1ABCD", "X")]) == ["X (ABCD)", "X (1ABCD)"])
  }
}
