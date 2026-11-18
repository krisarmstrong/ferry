import FerryIPC
import Foundation

/// The `Progress` FileProvider gets back for a transfer, counted in bytes as the agent reports
/// them, so Finder shows how far a copy has got.
public enum FileProgress {
  /// A progress of kind `.file` for `operation`, and the handler that moves it. The total is
  /// unknown (0) until the first report.
  public static func make(_ operation: Progress.FileOperationKind) -> (
    Progress, TransferProgressHandler
  ) {
    let progress = Progress(totalUnitCount: 0)
    progress.kind = .file
    progress.fileOperationKind = operation
    let update: TransferProgressHandler = { completed, total in
      progress.totalUnitCount = Int64(clamping: total)
      progress.completedUnitCount = Int64(clamping: min(completed, total))
    }
    return (progress, update)
  }
}
