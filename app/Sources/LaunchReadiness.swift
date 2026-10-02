import Foundation
import CoreGraphics

// Window existence is a handoff signal, not proof that Blizzard has finished
// loading its web content. Only geometry and exact owned-process IDs are used.
// No window titles, screenshots, Accessibility or Screen Recording permission.
enum LaunchReadiness {
    enum Result: Equatable { case ready(Int32), existing(String), timedOut, stopped }
    static func visibleProcess(_ windows: [[String:Any]], processes: [[String:Any]]) -> Int32? {
        for kind in ["game", "client"] {
            for process in processes where process["kind"] as? String == kind {
                guard let pid=process["pid"] as? NSNumber else { continue }
                if windows.contains(where: { window in
                    guard let owner=window[kCGWindowOwnerPID as String] as? NSNumber,
                          owner.int32Value == pid.int32Value,
                          let layer=window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                          let alpha=window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                          let bounds=window[kCGWindowBounds as String] as? [String:Any],
                          let width=bounds["Width"] as? NSNumber,
                          let height=bounds["Height"] as? NSNumber else { return false }
                    return width.doubleValue >= 320 && height.doubleValue >= 200
                }) { return pid.int32Value }
            }
        }
        return nil
    }
    static func visibleWindows() async -> [[String:Any]] {
        await Task.detached(priority:.utility) {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        }.value
    }
    @MainActor static func wait(
        launchEvents: [[String:Any]] = [],
        timeout: Duration = .seconds(90), interval: Duration = .seconds(1),
        stopped: () -> Bool,
        session: () async throws -> [[String:Any]],
        windows: () async -> [[String:Any]] = visibleWindows
    ) async throws -> Result {
        // Existing sessions have already received an activation request from
        // the scoped worker. A minimized/other-desktop window must not send a
        // reopen through the fresh-launch timeout again.
        if let existing=launchEvents.last(where:{$0["stage"] as? String == "session_existing"}) {
            return .existing(existing["kind"] as? String == "game" ? "Overwatch" : "Battle.net")
        }
        let clock=ContinuousClock(), deadline=clock.now.advanced(by:timeout)
        var previous: Int32?
        while clock.now < deadline {
            if stopped() || Task.isCancelled { return .stopped }
            let processes=try await session()
            let visible=await windows()
            if stopped() || Task.isCancelled { return .stopped }
            let pid=visibleProcess(visible,processes:processes)
            // Two consecutive observations avoid dismissing for a transient
            // startup surface. There is no arbitrary ten-second splash delay.
            if let pid, pid == previous { return .ready(pid) }
            previous=pid
            try await Task.sleep(for:interval)
        }
        return .timedOut
    }
}
