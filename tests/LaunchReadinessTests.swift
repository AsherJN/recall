import Foundation
import CoreGraphics

@main struct LaunchReadinessTests {
    static func window(_ pid:Int, width:Int=900, alpha:Double=1, layer:Int=0) -> [String:Any] {
        [kCGWindowOwnerPID as String:pid,kCGWindowLayer as String:layer,kCGWindowAlpha as String:alpha,
         kCGWindowBounds as String:["Width":width,"Height":600]]
    }
    @MainActor static func main() async throws {
        let owned:[[String:Any]]=[["pid":101,"kind":"client"]]
        for kind in ["client","game"] {
            let existing=try await LaunchReadiness.wait(
                launchEvents:[["stage":"session_existing","kind":kind,"activated":false]],
                stopped:{false},session:{fatalError("Existing session entered fresh-launch polling")},
                windows:{fatalError("Existing session waited for a visible window")})
            precondition(existing == .existing(kind == "game" ? "Overwatch" : "Battle.net"))
        }
        var ticks=0
        // A process exists immediately; another installation's window and a
        // tiny startup surface must not dismiss the launcher. A one-frame
        // window then disappears before the stable real window arrives.
        let frames:[[String:Any]]=[window(999),window(101,width:1),window(101),window(999),window(101),window(101)]
        let ready=try await LaunchReadiness.wait(timeout:.seconds(2),interval:.milliseconds(5),stopped:{false},session:{ owned },windows:{
            defer { ticks += 1 };return [frames[min(ticks,frames.count-1)]]
        })
        precondition(ready == .ready(101) && ticks == 6,"Dismissed before the owned window was stable")
        let timeout=try await LaunchReadiness.wait(timeout:.milliseconds(30),interval:.milliseconds(5),stopped:{false},session:{owned},windows:{[window(999),window(101,alpha:0),window(101,layer:3)]})
        precondition(timeout == .timedOut,"Foreign/invisible windows accepted")
        var stopped=false
        let cancelled=try await LaunchReadiness.wait(interval:.milliseconds(5),stopped:{stopped},session:{stopped=true;return owned},windows:{[window(101)]})
        precondition(cancelled == .stopped,"Cancellation dismissed to client")
        do {
            _ = try await LaunchReadiness.wait(stopped:{false},session:{throw SetupFailure(code:"session_membership_unknown")},windows:{[window(101)]})
            fatalError("Session identity failure ignored")
        } catch let failure as SetupFailure { precondition(failure.code == "session_membership_unknown") }
        let game=LaunchReadiness.visibleProcess([window(101),window(202)],processes:owned+[["pid":202,"kind":"game"]])
        precondition(game == 202,"Running game not preferred")
        print("PASS: immediate existing-session routing without polling, delayed/stable window handoff, foreign and invisible window rejection, timeout, stop, identity failure, game preference")
    }
}
