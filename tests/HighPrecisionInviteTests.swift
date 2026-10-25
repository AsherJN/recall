import Foundation

// The home screen's High-precision card (app/Sources/InputMonitoring.swift, REC-64):
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/InputMonitoring.swift \
//     tests/HighPrecisionInviteTests.swift -o runtime/phase-3/high-precision-invite-tests
//   runtime/phase-3/high-precision-invite-tests
// It also reads whether this Mac has a mouse connected (the I/O Registry, no permission asked).
@main struct HighPrecisionInviteTests {
    static var failures=0
    static func check(_ condition:Bool,_ message:String,line:Int=#line) {
        if !condition { failures+=1;print("FAIL line \(line): \(message)") }
    }
    static func stage(closed:Bool=false,installed:Bool=true,chosen:Bool=false,access:InputMonitoring.Access = .undecided,mouse:Bool=true)->HighPrecisionInvite? {
        HighPrecisionInvite.stage(closed:closed,gameInstalled:installed,highPrecision:chosen,access:access,mouseConnected:mouse)
    }
    static func main() {
        check(stage() == .invite,"a player with a mouse, on Standard or Classic, is invited")
        check(stage(access:.denied) == .invite,"also after saying no to macOS once: Turn On then opens System Settings")
        check(stage(access:.allowed) == .invite,"and with Input Monitoring already allowed")
        check(stage(mouse:false) == nil,"a trackpad alone isn't invited: High-precision reads only mice")
        check(stage(installed:false) == nil,"not before Overwatch is installed")
        check(stage(closed:true) == nil,"closed for good")
        check(stage(chosen:true,access:.allowed) == nil,"High-precision chosen and allowed: nothing left to do")
        check(stage(chosen:true,access:.undecided) == .permission,"chosen without an answer from macOS yet: the reminder")
        check(stage(chosen:true,access:.denied) == .permission,"chosen after a no: the reminder")
        check(stage(chosen:true,access:.denied,mouse:false) == .permission,"the reminder doesn't need the mouse connected right now")
        check(stage(closed:true,chosen:true,access:.denied) == nil,"the reminder closes for good too")
        check(HighPrecisionInvite(rawValue:"invite") == .invite && HighPrecisionInvite(rawValue:"permission") == .permission,"preview names")
        print("mouse connected on this Mac: \(InputMonitoring.mouseConnected)")
        if failures > 0 { print("\(failures) failed");exit(1) }
        print("High-precision invite tests passed")
    }
}
