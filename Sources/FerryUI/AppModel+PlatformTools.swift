import DeviceKit
import Foundation
import PlatformTools

/// What the menu's line about getting adb shows, if anything.
enum PlatformToolsLine: Equatable {
  /// No adb anywhere: Get Android Platform Tools….
  case offer
  /// This release pins a newer adb under a license the user has not accepted; the adb Ferry
  /// fetched before stays in use meanwhile.
  case licenseChanged
  case fetching
  case failed(PlatformToolsError)
}

/// The download the user asked for.
enum PlatformToolsFetch: Equatable {
  case idle
  case fetching
  case failed(PlatformToolsError)
}

struct PlatformToolsState {
  var fetch = PlatformToolsFetch.idle
  /// The bundled license text is not one the user accepted, and Ferry has fetched adb before.
  var licenseChanged = false
  /// The fetch running, the user's or a quiet update, one at most.
  var task: Task<Void, Never>?
  /// Whether the running fetch shows its progress and outcome: a quiet update becomes the
  /// user's when they ask for adb while it runs.
  var shown = false
}

/// Get Android Platform Tools…: Ferry downloads Google's adb once the user has accepted Google's
/// license (see `PlatformToolsFetcher`), then asks the agent to look for adb again. The app
/// fetches, not the agent: the user accepts here, and the agent only finds what is fetched.
extension AppModel {
  /// Shown with a device that could use adb, attached or on the network, or once the user opened
  /// a network form: a Mac that never meets an Android device has no use for adb. A download the
  /// user started, and how it ended, show whatever adb reports.
  var platformToolsRow: PlatformToolsLine? {
    guard agent == .running else { return nil }
    switch platformTools.fetch {
    case .fetching: return .fetching
    case .failed(let error): return .failed(error)
    case .idle: break
    }
    if adbStatus == .notInstalled, hasDevices || wantsNetwork { return .offer }
    return platformTools.licenseChanged ? .licenseChanged : nil
  }

  /// Accept, in the license window: records which text the user accepted and when, then fetches.
  func acceptLicense() {
    services.recordPlatformToolsAcceptance(
      LicenseAcceptance(of: PlatformToolsRelease.pinned.license, date: .now))
    platformTools.licenseChanged = false
    fetchPlatformTools(shown: true)
  }

  /// Try Again, under the acceptance already recorded.
  func retryPlatformTools() {
    fetchPlatformTools(shown: true)
  }

  func cancelPlatformTools() {
    platformTools.task?.cancel()
  }

  /// Takes what the agent says of adb. adb that turns up another way (the user installed it)
  /// ends a failed download's line; a failure while adb was there all along (an update under a
  /// changed license) stays.
  func noteADBStatus(_ status: ADBStatus?) {
    if case .failed = platformTools.fetch, status == .available, adbStatus != .available {
      platformTools.fetch = .idle
    }
    adbStatus = status
  }

  /// Returns once the fetch running, if any, has ended.
  func platformToolsSettled() async {
    await platformTools.task?.value
  }

  /// At launch, when Ferry has fetched adb before. A license text the user has not accepted
  /// (a new text, under this pin or a newer one) waits for the user, and the adb Ferry has stays
  /// in use meanwhile. Under an accepted license, a newer pinned version is fetched quietly.
  func considerPlatformToolsUpdate() {
    let pinned = PlatformToolsRelease.pinned
    guard let fetched = services.fetchedPlatformToolsVersion() else { return }
    if services.platformToolsAcceptance()?.covers(pinned.license) != true {
      platformTools.licenseChanged = true
    } else if fetched != pinned.version {
      fetchPlatformTools(shown: false)
    }
  }

  /// A quiet update shows nothing, and on failure leaves the adb Ferry has for the next launch to
  /// replace. The user asking while one runs takes it over rather than starting another.
  private func fetchPlatformTools(shown: Bool) {
    if shown {
      platformTools.shown = true
      platformTools.fetch = .fetching
    }
    guard platformTools.task == nil else { return }
    platformTools.shown = shown
    platformTools.task = Task {
      defer {
        platformTools.task = nil
        // A takeover that arrived after the download, during the recheck, has nothing left to
        // show: the line never outlives its task on Downloading.
        if platformTools.fetch == .fetching { platformTools.fetch = .idle }
      }
      do throws(PlatformToolsError) {
        try await services.fetchPlatformTools(accepted: services.platformToolsAcceptance())
        platformTools.fetch = .idle
        await recheckADB()
      } catch .cancelled, .licenseNotAccepted {
        platformTools.fetch = .idle
      } catch {
        Self.log.error(
          "fetching the platform tools: \(String(describing: error), privacy: .private)")
        platformTools.fetch = platformTools.shown ? .failed(error) : .idle
      }
    }
  }
}
