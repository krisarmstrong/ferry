import DeviceKit

// MARK: Rescan

extension DeviceHub {
  /// Scans again after `delay`, replacing any rescan already waiting.
  func scheduleRescan(after delay: Duration?) {
    rescan?.cancel()
    rescan = delay.map { delay in
      requestFreeTask { [weak self, clock] in
        do {
          try await clock.sleep(for: delay)
        } catch {
          return
        }
        await self?.reconcile()
      }
    }
  }
}

// MARK: Back-off

extension DeviceHub {
  /// Holds off the next open of a failing device: 2 s, doubling to 60 s. Then rescans.
  func backOff(_ id: DeviceID) {
    let delay = backoff[id].map { min($0.delay * 2, Self.maxRetryDelay) } ?? Self.firstRetryDelay
    generations += 1
    let token = generations
    backoff[id] = Backoff(delay: delay, waiting: true, token: token)
    requestFreeTask { [weak self, clock] in
      do {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
      await self?.retry(id, token: token)
    }
  }

  fileprivate func retry(_ id: DeviceID, token: UInt64) async {
    guard let wait = backoff[id], wait.waiting, wait.token == token else { return }
    backoff[id]?.waiting = false
    await reconcile()
  }
}

// MARK: Polling

extension DeviceHub {
  /// Held devices not sharing files, in serial order.
  fileprivate var waitingIDs: [DeviceID] {
    entries.values.compactMap { entry in
      guard case .held = entry.holding, entry.state == .notSharingFiles else { return nil }
      return entry.info.id
    }.sorted { $0.serial < $1.serial }
  }

  func updatePolling() {
    let waiting = !waitingIDs.isEmpty
    if waiting, poller == nil {
      poller = requestFreeTask { [weak self, clock] in
        while !Task.isCancelled {
          do {
            try await clock.sleep(for: Self.recheckInterval)
          } catch {
            return
          }
          guard !Task.isCancelled, let self else { return }
          await self.recheckWaiting()
        }
      }
    } else if !waiting, let poller {
      poller.cancel()
      self.poller = nil
    }
  }

  fileprivate func recheckWaiting() async {
    for id in waitingIDs {
      await recheckHeld(id)
    }
  }
}
