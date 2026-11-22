@testable import FerryIPC

extension Refusal {
  /// The words a test handler gives for a refusal.
  var testText: String {
    switch self {
    case .badRequest: "bad request"
    case .notAllowed: "request not allowed"
    case .tooManyRequests: "too many requests"
    }
  }
}
