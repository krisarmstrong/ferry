import Foundation
import Testing

/// The release workflow's scripts, run against stand-ins: scripts/notarize.sh against a fake
/// `xcrun` that answers as notarytool did, and scripts/check-developer-id.sh against
/// certificates made here.
struct ReleaseScriptTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// What notarytool printed when Apple dropped the upload of v0.3.0's DMG.
  static let connectionLost =
    #"Error: HTTPError(statusCode: nil, error: Error Domain=NSURLErrorDomain Code=-1005 "#
    + #""The network connection was lost." UserInfo={NSErrorFailingURLStringKey="#
    + #"https://appstoreconnect.apple.com/notary/v2/submissions?})"#
  static let timedOut =
    #"Error: HTTPError(statusCode: nil, error: Error Domain=NSURLErrorDomain Code=-1001 "#
    + #""The request timed out." UserInfo={})"#
  static let submission = "2efe2717-52ef-43a5-96dc-0797e4ca1041"

  static func verdict(_ status: String) -> String {
    #"{"id":"\#(submission)","message":"Processing complete","status":"\#(status)"}"#
  }

  /// One answer of the fake `xcrun`, in the order it is called.
  struct Answer {
    var out = ""
    var err = ""
    var status: Int32 = 0
  }

  /// A folder with fake `xcrun` and `sleep`, which record their arguments, one call a line.
  final class Fakes: Sendable {
    let folder: URL

    init(_ answers: [Answer]) throws {
      folder = FileManager.default.temporaryDirectory
        .appending(path: "release-script-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for (index, answer) in answers.enumerated() {
        try answer.out.write(
          to: folder.appending(path: "\(index + 1).out"), atomically: true, encoding: .utf8)
        try answer.err.write(
          to: folder.appending(path: "\(index + 1).err"), atomically: true, encoding: .utf8)
        try "\(answer.status)".write(
          to: folder.appending(path: "\(index + 1).status"), atomically: true, encoding: .utf8)
      }
      try Self.install(
        """
        #!/bin/bash
        dir="$(dirname "$0")"
        echo "$*" >> "$dir/xcrun.calls"
        n="$(wc -l < "$dir/xcrun.calls" | tr -d ' ')"
        cat "$dir/$n.out" 2> /dev/null
        cat "$dir/$n.err" >&2 2> /dev/null
        exit "$(cat "$dir/$n.status" 2> /dev/null || echo 99)"
        """, as: folder.appending(path: "xcrun"))
      try Self.install(
        """
        #!/bin/bash
        echo "$*" >> "$(dirname "$0")/sleep.calls"
        """, as: folder.appending(path: "sleep"))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    private static func install(_ script: String, as file: URL) throws {
      try script.write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }

    private func lines(_ name: String) -> [String] {
      let text = (try? String(contentsOf: folder.appending(path: name), encoding: .utf8)) ?? ""
      return text.split(separator: "\n").map(String.init)
    }

    /// Each `xcrun` call's arguments, the API key's options left out.
    var calls: [String] {
      lines("xcrun.calls").map {
        $0.replacing(" --key /tmp/notary.p8 --key-id KEYID --issuer ISSUER", with: "")
      }
    }

    var sleeps: [String] { lines("sleep.calls") }
  }

  /// A script's exit status and all it printed.
  struct Outcome {
    let status: Int32
    let output: String
  }

  /// Runs a script with `fakes` first on PATH.
  static func run(_ script: String, _ arguments: [String], fakes: Fakes? = nil) throws -> Outcome {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = [root.appending(path: script).path] + arguments
    process.environment = [
      "PATH": (fakes.map { "\($0.folder.path):" } ?? "") + "/usr/bin:/bin",
      "NOTARY_KEY": "/tmp/notary.p8", "NOTARY_KEY_ID": "KEYID", "NOTARY_ISSUER_ID": "ISSUER",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    process.waitUntilExit()
    return Outcome(status: process.terminationStatus, output: output ?? "")
  }

  /// Runs `body` on a dispatch thread. The scripts and openssl block while they run, and a
  /// blocked thread of the shared pool holds up every other suite's tasks.
  static func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws
    -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
    }
  }

  static func notarize(_ answers: [Answer]) async throws -> (Outcome, Fakes) {
    let fakes = try Fakes(answers)
    return (
      try await offThePool { try run("scripts/notarize.sh", ["Ferry.dmg"], fakes: fakes) }, fakes
    )
  }

  static let submit = "notarytool submit Ferry.dmg --output-format json"
  static let wait = "notarytool wait \(submission) --timeout 30m --output-format json"
  static let log = "notarytool log \(submission)"

  /// What `submit --output-format json` prints once the upload is done.
  static let uploaded = Answer(
    out: #"{"id":"\#(submission)","message":"Successfully uploaded file","path":"Ferry.dmg"}"#)

  @Test func anAcceptedSubmissionIsUploadedOnceAndWaitedOn() async throws {
    let (outcome, fakes) = try await Self.notarize([
      Self.uploaded, Answer(out: Self.verdict("Accepted")),
    ])
    #expect(outcome.status == 0)
    #expect(fakes.calls == [Self.submit, Self.wait])
    #expect(fakes.sleeps.isEmpty)
  }

  /// The v0.3.0 release: the upload's connection was lost, and nothing was wrong with the DMG.
  /// json mode prints nothing until the end, so a failed upload has no id: it is uploaded again.
  @Test func aLostUploadIsUploadedAgainAfterABackOff() async throws {
    let (outcome, fakes) = try await Self.notarize([
      Answer(err: Self.connectionLost, status: 1), Self.uploaded,
      Answer(out: Self.verdict("Accepted")),
    ])
    #expect(outcome.status == 0)
    #expect(fakes.calls == [Self.submit, Self.submit, Self.wait])
    #expect(fakes.sleeps == ["30"])
  }

  @Test func threeLostUploadsFailAfterTheThirdAttempt() async throws {
    let lost = Answer(err: Self.timedOut, status: 1)
    let (outcome, fakes) = try await Self.notarize([lost, lost, lost, Self.uploaded])
    #expect(outcome.status != 0)
    #expect(fakes.calls == [Self.submit, Self.submit, Self.submit])
    #expect(fakes.sleeps == ["30", "60"])
    #expect(
      outcome.output.contains("::error::uploading Ferry.dmg lost its connection to Apple 3 times"))
  }

  /// Once the upload is done, a dropped connection waits on the same submission again: the
  /// file is never sent twice.
  @Test func aConnectionLostWhileWaitingWaitsOnTheSameSubmission() async throws {
    let (outcome, fakes) = try await Self.notarize([
      Self.uploaded, Answer(err: Self.connectionLost, status: 1),
      Answer(out: Self.verdict("Accepted")),
    ])
    #expect(outcome.status == 0)
    #expect(fakes.calls == [Self.submit, Self.wait, Self.wait])
    #expect(fakes.sleeps == ["30"])
  }

  @Test func threeLostWaitsFailWithoutUploadingAgain() async throws {
    let lost = Answer(err: Self.connectionLost, status: 1)
    let (outcome, fakes) = try await Self.notarize([Self.uploaded, lost, lost, lost])
    #expect(outcome.status != 0)
    #expect(fakes.calls == [Self.submit, Self.wait, Self.wait, Self.wait])
    #expect(fakes.sleeps == ["30", "60"])
    #expect(
      outcome.output.contains(
        "::error::waiting on submission \(Self.submission) lost its connection to Apple 3 times"))
  }

  /// Apple's verdict is final: an Invalid submission is not sent again, and its log is shown,
  /// after the error line.
  @Test(arguments: ["Invalid", "Rejected"])
  func aVerdictOtherThanAcceptedIsNeverRetried(verdict: String) async throws {
    let (outcome, fakes) = try await Self.notarize([
      Self.uploaded, Answer(out: Self.verdict(verdict), status: 1), Answer(out: "THE-LOG"),
    ])
    #expect(outcome.status != 0)
    #expect(fakes.calls == [Self.submit, Self.wait, Self.log])
    #expect(fakes.sleeps.isEmpty)
    let error = try #require(outcome.output.range(of: "::error::notarization of Ferry.dmg was"))
    let log = try #require(outcome.output.range(of: "THE-LOG"))
    #expect(error.lowerBound < log.lowerBound)
  }

  /// A log that cannot be fetched still leaves the error line.
  @Test func aFailedLogFetchKeepsTheError() async throws {
    let (outcome, fakes) = try await Self.notarize([
      Self.uploaded, Answer(out: Self.verdict("Invalid"), status: 1),
      Answer(err: "Error: no log", status: 1),
    ])
    #expect(outcome.status != 0)
    #expect(fakes.calls == [Self.submit, Self.wait, Self.log])
    #expect(outcome.output.contains("::error::notarization of Ferry.dmg was not accepted"))
  }

  /// A wait that times out reports the timeout, not a verdict, and is not retried.
  @Test func aWaitThatTimesOutSaysSo() async throws {
    let (outcome, fakes) = try await Self.notarize([
      Self.uploaded, Answer(out: Self.verdict("In Progress"), status: 1),
    ])
    #expect(outcome.status != 0)
    #expect(fakes.calls == [Self.submit, Self.wait])
    #expect(fakes.sleeps.isEmpty)
    #expect(
      outcome.output.contains(
        "::error::submission \(Self.submission) had no verdict within 30m"))
  }

  /// Any other failure (a refused key, say) is not a dropped connection, and fails at once.
  @Test func anotherFailureIsNotRetried() async throws {
    let (outcome, fakes) = try await Self.notarize([
      Answer(err: "Error: HTTP status code: 401. Unable to authenticate.", status: 1),
      Self.uploaded,
    ])
    #expect(outcome.status != 0)
    #expect(fakes.calls == [Self.submit])
    #expect(fakes.sleeps.isEmpty)
  }
}

/// The release workflow notarizes and checks the identity only through the scripts above.
struct ReleaseWorkflowScriptTests {
  private static let workflow = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: ".github/workflows/release.yml")

  @Test func theWorkflowRunsTheScripts() throws {
    let text = try String(contentsOf: Self.workflow, encoding: .utf8)
    #expect(text.contains("scripts/check-developer-id.sh \"$work/identity.pem\" \"$team\""))
    #expect(text.contains("\"$GITHUB_WORKSPACE/scripts/build-pkgconf.sh\""))
    #expect(!text.contains("brew install pkgconf"))
    #expect(text.contains("scripts/notarize.sh \"$RUNNER_TEMP/notarize.zip\""))
    #expect(text.contains("scripts/notarize.sh \"$dmg\""))
    #expect(!text.contains("notarytool submit"))
  }

  /// CI builds the release with the same pinned pkgconf, so that path runs on every PR.
  @Test func ciBuildsTheReleaseWithThePinnedPkgconf() throws {
    let ciWorkflow = Self.workflow.deletingLastPathComponent().appending(path: "ci.yml")
    let text = try String(contentsOf: ciWorkflow, encoding: .utf8)
    #expect(text.contains("scripts/build-pkgconf.sh \"$RUNNER_TEMP/pkgconf\""))
  }
}
