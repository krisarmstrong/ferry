import Testing

@testable import ADBTransport

struct ADBLocatorTests {
  func locator(
    existing: Set<String>, androidHome: String? = nil
  ) -> ADBLocator {
    ADBLocator(
      environment: androidHome.map { ["ANDROID_HOME": $0] } ?? [:], home: "/Users/me",
      isExecutable: { existing.contains($0) })
  }

  @Test func nothingInstalled() {
    #expect(locator(existing: []).adbURL() == nil)
  }

  @Test func homebrewWinsOverEverything() {
    let all: Set = [
      "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
      "/Users/me/Library/Android/sdk/platform-tools/adb", "/sdk/platform-tools/adb",
    ]
    #expect(locator(existing: all, androidHome: "/sdk").adbURL()?.path == "/opt/homebrew/bin/adb")
  }

  @Test func searchOrder() {
    #expect(
      locator(existing: ["/usr/local/bin/adb", "/Users/me/Library/Android/sdk/platform-tools/adb"])
        .adbURL()?.path == "/usr/local/bin/adb")
    #expect(
      locator(
        existing: ["/Users/me/Library/Android/sdk/platform-tools/adb", "/sdk/platform-tools/adb"],
        androidHome: "/sdk"
      )
      .adbURL()?.path == "/Users/me/Library/Android/sdk/platform-tools/adb")
  }

  @Test func androidHomeIsLast() {
    #expect(
      locator(existing: ["/sdk/platform-tools/adb"], androidHome: "/sdk").adbURL()?.path
        == "/sdk/platform-tools/adb")
  }

  @Test func androidHomeIgnoredWhenUnset() {
    #expect(locator(existing: ["/platform-tools/adb"]).adbURL() == nil)
  }
}
