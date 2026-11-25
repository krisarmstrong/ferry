import FerryIPC
import Testing

struct MoveDeadlineTests {
  /// A move can be a copy of the whole file (a device without MoveObject): a deadline would cut
  /// it off and FileProvider would start it again. A rename is always one call.
  @Test func aMoveHasNoDeadline() {
    let id = ItemID.root
    #expect(AgentRequest.move(domain: "d", id: id, toFolder: .root).mayTakeLong)
    #expect(!AgentRequest.rename(domain: "d", id: id, to: "b").mayTakeLong)
  }
}
