import DeviceKit
import Testing

@testable import MTPTransport

struct MTPErrorClassificationTests {
  /// Counts probes so tests can assert the bus is only checked for transport-layer errors.
  final class Probe {
    let present: Bool
    var count = 0

    init(present: Bool) {
      self.present = present
    }

    func callAsFunction() -> Bool {
      count += 1
      return present
    }
  }

  func classify(
    _ entries: [MTPErrorEntry], generalMeansLocked: Bool = false, present: Bool = true
  ) -> (TransportError, probes: Int) {
    let probe = Probe(present: present)
    let error = TransportError.classify(
      entries, during: "listing folder", generalMeansLocked: generalMeansLocked,
      deviceStillPresent: probe.callAsFunction)
    return (error, probe.count)
  }

  @Test func cancelWinsOverEverything() {
    let (error, probes) = classify(
      [.init(code: .usbLayer, text: "a"), .init(code: .cancelled, text: "b")], present: false)
    #expect(error == .cancelled)
    #expect(probes == 0)
  }

  @Test func noDeviceIsDisconnectedWithoutProbing() {
    let (error, probes) = classify([.init(code: .noDevice, text: "gone")])
    #expect(error == .deviceDisconnected)
    #expect(probes == 0)
  }

  @Test(arguments: [MTPErrorCode.usbLayer, .ptpLayer])
  func transportErrorWithDeviceGoneIsDisconnected(code: MTPErrorCode) {
    let (error, probes) = classify([.init(code: code, text: "x")], present: false)
    #expect(error == .deviceDisconnected)
    #expect(probes == 1)
  }

  @Test(arguments: [MTPErrorCode.usbLayer, .ptpLayer])
  func transportErrorWithDevicePresentIsIO(code: MTPErrorCode) {
    let (error, probes) = classify([.init(code: code, text: "x")], present: true)
    #expect(error == .io("listing folder failed: x"))
    #expect(probes == 1)
  }

  @Test func disconnectWinsOverLockedGeneral() {
    let (error, _) = classify(
      [.init(code: .general, text: "a"), .init(code: .ptpLayer, text: "b")],
      generalMeansLocked: true, present: false)
    #expect(error == .deviceDisconnected)
  }

  @Test func onlyGeneralWhileReadingStoragesIsLocked() {
    let (error, probes) = classify(
      [.init(code: .general, text: "Get Storage information failed.")], generalMeansLocked: true)
    #expect(error == .deviceLocked)
    #expect(probes == 0)
  }

  @Test func emptyStackWhileReadingStoragesIsLocked() {
    #expect(classify([], generalMeansLocked: true).0 == .deviceLocked)
  }

  @Test func generalMixedWithOtherErrorsIsIO() {
    let (error, _) = classify(
      [.init(code: .general, text: "a"), .init(code: .storageFull, text: "b")],
      generalMeansLocked: true)
    #expect(error == .io("listing folder failed: a; b"))
  }

  @Test func generalOutsideStorageReadIsIO() {
    #expect(classify([.init(code: .general, text: "a")]).0 == .io("listing folder failed: a"))
  }

  @Test func emptyStackIsIOWithoutDetail() {
    #expect(classify([]).0 == .io("listing folder failed"))
  }
}
