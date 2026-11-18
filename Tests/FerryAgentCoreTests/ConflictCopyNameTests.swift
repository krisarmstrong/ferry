import DeviceKit
import Foundation
import Testing

@testable import FerryAgentCore

/// A conflict copy's name: the marker before a real extension, within what a device stores.
struct ConflictCopyNameTests {
  /// libmtp sends a name of at most 255 UTF-8 bytes, and a device takes at most 254 UTF-16
  /// units (PTP's string limit): the name gives way, the marker and the extension stay.
  @Test(arguments: [
    String(repeating: "a", count: 250), String(repeating: "é", count: 125),
    String(repeating: "𝄞", count: 70),
  ])
  func aConflictNameFitsInTheDevicesLimit(base: String) {
    let copy = ConflictCopy.name(for: base + ".txt", attempt: 12)

    #expect(copy.utf8.count <= 255)
    #expect(copy.utf16.count <= 254)
    #expect(copy.hasSuffix(" (conflict from Mac 12).txt"))
    #expect(base.hasPrefix(copy.prefix { $0 != " " }))
  }

  /// What follows the last dot is an extension only if it is short and has no space.
  @Test(arguments: [
    ("Notes 2026.11.17 meeting", "Notes 2026.11.17 meeting (conflict from Mac)"),
    ("v1.2 final.docx", "v1.2 final (conflict from Mac).docx"),
  ])
  func onlyAShortTailIsAnExtension(name: String, expected: String) {
    #expect(ConflictCopy.name(for: name, attempt: 1) == expected)
  }

  @Test func aLongTailIsPartOfTheNameAndTheCopyFits() {
    let name = "a." + String(repeating: "b", count: 250)
    let copy = ConflictCopy.name(for: name, attempt: 1)

    #expect(copy.utf8.count <= 255)
    #expect(copy.utf16.count <= 254)
    #expect(copy.hasPrefix("a.bbb"))
    #expect(copy.hasSuffix(" (conflict from Mac)"))
  }

  @Test func aCopyNeverStartsWithASpace() {
    #expect(ConflictCopy.name(for: " .txt", attempt: 1) == "(conflict from Mac).txt")
    // A space with a combining mark on it is one Character, but still a leading 0x20 byte.
    let marked = ConflictCopy.name(for: " \u{301}x.txt", attempt: 1)
    #expect(marked.utf8.first != 0x20)
    #expect(marked == "x (conflict from Mac).txt")
  }

  /// A space with a combining mark on it is still a space: that tail is no extension.
  @Test func aTailWithAMarkedSpaceIsNoExtension() {
    #expect(
      ConflictCopy.name(for: "a.b \u{301}c", attempt: 1) == "a.b \u{301}c (conflict from Mac)")
  }

  /// One letter carrying hundreds of combining marks cannot be shortened by whole characters:
  /// it loses marks instead, and the copy keeps its letter.
  @Test func anOversizedLetterLosesMarksNotItself() {
    let copy = ConflictCopy.name(
      for: "e" + String(repeating: "\u{301}", count: 200) + ".txt", attempt: 1)

    #expect(RemotePath.fitsOnDevice(copy))
    #expect(copy.unicodeScalars.first == "e")
    #expect(copy.hasSuffix(" (conflict from Mac).txt"))
  }

  @Test func aShortenedNameLeavesNoDoubleSpace() {
    let base = String(repeating: "a", count: 226) + " " + String(repeating: "b", count: 30)
    let copy = ConflictCopy.name(for: base + ".txt", attempt: 12)

    #expect(RemotePath.fitsOnDevice(copy))
    #expect(!copy.contains("  "))
  }

  /// A bare trailing dot is no extension, so the copy does not end in one.
  @Test func aTrailingDotIsNoExtension() {
    #expect(ConflictCopy.name(for: "foo.", attempt: 1) == "foo. (conflict from Mac)")
  }
}
