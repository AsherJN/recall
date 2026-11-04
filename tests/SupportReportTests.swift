import AppKit

// The support report (AppModel.makeReport): its MetalFX fields, and ShaderRecord
// (app/Sources/GraphicsDetails.swift), which names how the last after-match preparation ended and
// whether one is preparing now or waiting for the game to close. AfterMatch.running accepts only a
// process named ow2-setup, so the test is built under that name. Build with every app source but
// Main.swift, and run:
//   mkdir -p runtime/phase-3/report-tests
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library $(ls app/Sources/*.swift | grep -v Main.swift) \
//     tests/SupportReportTests.swift -o runtime/phase-3/report-tests/ow2-setup
//   runtime/phase-3/report-tests/ow2-setup
// Main.swift's AppDelegate, for the one menu action the app's views name.
final class AppDelegate: NSObject { @objc func forceQuit() {} }
@main struct SupportReportTests {
    @MainActor static func main() throws {
        // A copy of this test started with --report prints the report for the settings it was given.
        if CommandLine.arguments.contains("--report") { let model=AppModel();model.makeReport();print(model.report);return }
        // How a run ended, from the helper's last word (scripts/portable_pipeline.swift).
        let skipped="Pipeline preparation skipped; existing cache retained: "
        precondition(ShaderRecord.outcome(skipped+"Preparation cancelled\n") == "cancelled")
        precondition(ShaderRecord.outcome(skipped+"Preparation cancelled or timed out\n") == "cancelled_or_timed_out")
        precondition(ShaderRecord.outcome(skipped+"Fresh-process verification failed\n") == "failed")
        precondition(ShaderRecord.outcome(skipped+"No Metal device\n") == "failed")
        precondition(ShaderRecord.outcome("{\"graphics\":\"learned\",\"learned\":9,\"ready\":4}\nPrepared and verified 5 learned pipelines; 9 of 9 ready\n") == "prepared")
        precondition(ShaderRecord.outcome("Preparation ran out of time; the rest is prepared after the next session\n") == "timed_out")
        precondition(ShaderRecord.outcome("{\"graphics\":\"learned\",\"learned\":9,\"ready\":4}\n") == "incomplete")
        precondition(ShaderRecord.outcome("") == "never")

        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("support-report-\(getpid())")
        defer { try? fm.removeItem(at:root) }
        try fm.createDirectory(at:root.appendingPathComponent("logs"),withIntermediateDirectories:true)
        try fm.createDirectory(at:root.appendingPathComponent("cache"),withIntermediateDirectories:true)
        let log=root.appendingPathComponent("logs/pipeline-after-session.log")
        let pid=root.appendingPathComponent("cache/after-session.pid")
        func age(_ url:URL,_ seconds:Double) throws {
            try fm.setAttributes([.modificationDate:Date().addingTimeInterval(-seconds)],ofItemAtPath:url.path)
        }

        // Nothing ran yet.
        var record=ShaderRecord.read(root:root)
        precondition(record["after_match"] as? String == "never")
        precondition(record["preparing_now"] as? Bool == false && record["waiting_for_game_to_close"] as? Bool == false)

        // The last run was stopped when the game started again, and nothing runs now.
        try (skipped+"Preparation cancelled\n").write(to:log,atomically:true,encoding:.utf8);try age(log,7200)
        record=ShaderRecord.read(root:root)
        precondition(record["after_match"] as? String == "cancelled" && record["after_match_hours_ago"] as? Int == 2)
        precondition(record["preparing_now"] as? Bool == false && record["waiting_for_game_to_close"] as? Bool == false)

        // During the next match the preparation has named itself, but its helper hasn't started:
        // the log is still the last run's.
        try "\(getpid())".write(to:pid,atomically:true,encoding:.utf8);try age(pid,600)
        record=ShaderRecord.read(root:root)
        precondition(record["preparing_now"] as? Bool == false && record["waiting_for_game_to_close"] as? Bool == true)
        precondition(record["after_match"] as? String == "cancelled")

        // The game closed and the helper started over its log.
        try "{\"graphics\":\"learned\",\"learned\":9,\"ready\":4}\n".write(to:log,atomically:true,encoding:.utf8)
        record=ShaderRecord.read(root:root)
        precondition(record["preparing_now"] as? Bool == true && record["waiting_for_game_to_close"] as? Bool == false)
        precondition(record["after_match"] as? String == "incomplete" && record["learned"] as? Int == 9 && record["ready"] as? Int == 4)

        // A preparation named by a process that's gone (or isn't ow2-setup) isn't running.
        try "999999".write(to:pid,atomically:true,encoding:.utf8)
        record=ShaderRecord.read(root:root)
        precondition(record["preparing_now"] as? Bool == false && record["waiting_for_game_to_close"] as? Bool == false)

        // Waiting with no log at all: the first preparation after the first match.
        try fm.removeItem(at:log);try "\(getpid())".write(to:pid,atomically:true,encoding:.utf8)
        record=ShaderRecord.read(root:root)
        precondition(record["preparing_now"] as? Bool == false && record["waiting_for_game_to_close"] as? Bool == true)
        precondition(record["after_match"] as? String == "never")

        // MetalFX upscaling is on or off whatever the sharpening (schema 2 said "off" for on with
        // sharpening Off). The settings come from the copy's arguments (UserDefaults' argument
        // domain), so the test writes no defaults.
        func report(_ upscaling:String,_ sharpening:String,_ more:[String]=[]) throws -> [String:Any] {
            let copy=Process(),out=Pipe()
            copy.executableURL=Bundle.main.executableURL
            copy.arguments=["--report","-metalFXUpscaling",upscaling,"-metalFXSharpening",sharpening]+more
            copy.standardOutput=out;try copy.run()
            let data=out.fileHandleForReading.readDataToEndOfFile();copy.waitUntilExit()
            precondition(copy.terminationStatus == 0)
            return try JSONSerialization.jsonObject(with:data) as! [String:Any]
        }
        for (upscaling,sharpening,expected) in [("YES","off","on"),("YES","high","on"),("NO","off","off"),("NO","low","off")] {
            let fields=try report(upscaling,sharpening)
            precondition(fields["schema"] as? Int == 6)
            // Game Mode (REC-51, REC-55): on unless the player turned it off.
            precondition(fields["game_mode"] as? String == "on","\(fields)")
            // The mouse (REC-52, REC-57): Standard unless the player chose another, with Input
            // Monitoring as macOS has it for this process.
            precondition(fields["mouse_input"] as? String == "standard","\(fields)")
            // Mouse › Advanced (REC-63): every report unless the player lowers it.
            precondition(fields["mouse_rate"] as? String == "all","\(fields)")
            precondition(["allowed","denied","undecided"].contains(fields["input_monitoring"] as? String ?? ""),"\(fields)")
            // Other apps (REC-5): nothing launched from this copy, and its busy note never looked.
            let other=fields["other_apps"] as? [String:Any]
            precondition(other?["at_last_launch"] as? String == "none" && other?["now"] as? String == "not_checked","\(String(describing:other))")
            // Logging (REC-40): off unless the player turned it on, with no Battle.net open.
            let logging=fields["logging"] as? [String:Any]
            precondition(logging?["setting"] as? String == "off" && logging?["open_session"] == nil,"\(String(describing:logging))")
            precondition(fields["metalfx_upscaling"] as? String == expected && fields["metalfx_sharpening"] as? String == sharpening,"\(upscaling) \(sharpening): \(fields)")
            precondition((fields["shaders"] as? [String:Any])?["waiting_for_game_to_close"] is Bool)
        }
        // Game Mode's switch and support's Terminal default from 1.1 are one setting (REC-51).
        let gameModeOff=try report("NO","off",["-gameMode","NO"])
        precondition(gameModeOff["game_mode"] as? String == "off","\(gameModeOff)")
        let gameModeOn=try report("NO","off",["-gameMode","YES"])
        precondition(gameModeOn["game_mode"] as? String == "on","\(gameModeOn)")
        for choice in ["classic","high-precision"] {
            let chosen=try report("NO","off",["-mouseInput",choice])
            precondition(chosen["mouse_input"] as? String == choice,"\(chosen)")
        }
        for (chosen,expected) in [("500","500"),("250","250"),("8000","all")] {
            let fields=try report("NO","off",["-mouseRate",chosen])
            precondition(fields["mouse_rate"] as? String == expected,"\(chosen): \(fields)")
        }
        // Build 76's switch is gone: its default no longer chooses anything.
        let old=try report("NO","off",["-highPrecisionMouse","YES"])
        precondition(old["mouse_input"] as? String == "standard" && old["high_precision_mouse"] == nil,"\(old)")
        // Logging presets combine (REC-51); the report names each one that's on.
        let mixed=try report("NO","off",["-logging","crashes,mouse"])["logging"] as? [String:Any]
        precondition(mixed?["setting"] as? String == "crashes,mouse" && mixed?["custom"] == nil,"\(String(describing:mixed))")
        // Battle.net's last starts (BattleNetRecord, REC-6/31), from its agent's CRLF logs: updates with
        // how long they waited and ran, the codes for not playable, the servers' names only.
        precondition(BattleNetRecord.read(root:root).isEmpty)
        let agent=root.appendingPathComponent("environment/drive_c/ProgramData/Battle.net/Agent")
        func agentLog(_ version:String,_ name:String,_ lines:[String]) throws {
            let folder=agent.appendingPathComponent("Agent.\(version)/Logs")
            try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            try (lines.joined(separator:"\r\n")+"\r\n").write(to:folder.appendingPathComponent(name),atomically:true,encoding:.utf8)
        }
        try agentLog("9775","Operations-20260928T181829.log",["[I 2026-09-28 18:18:30.0000] Queue operation - OP_UPDATE for 'agent'"])
        for stamp in ["20261017T080000","20261018T080000"] { try agentLog("9824","Operations-\(stamp).log",[]) }
        try agentLog("9824","Operations-20261019T191303.log",[
            "[I 2026-10-19 19:13:04.0700] Queue operation - OP_UPDATE for 'agent'",
            "[I 2026-10-19 19:13:04.0701] Active operation nullptr replaced by OP_UPDATE for 'agent'",
            "[I 2026-10-19 19:13:10.0000] Queue operation - OP_UPDATE for 'prometheus'",
            "[I 2026-10-19 19:37:04.5000] Process finished OP_UPDATE for 'agent'",
            "[I 2026-10-19 19:37:04.5001] OP_UPDATE for 'agent' completed",
            "[I 2026-10-19 19:37:04.6000] Active operation nullptr replaced by OP_UPDATE for 'prometheus'",
            "[I 2026-10-19 19:37:16.6000] OP_UPDATE for 'prometheus' completed",
            "[I 2026-10-19 19:37:20.0000] Concurrent operation OP_UPDATE for 'battle.net' completed",
            "[I 2026-10-19 21:37:04.0000] Queue operation - OP_UPDATE for 'agent'",
            "[I 2026-10-19 21:37:04.0000] Active operation OP_UPDATE for 'prometheus' replaced by OP_UPDATE for 'agent'",
            "[I 2026-10-19 21:47:04.0000] Request GET /agent"])
        try agentLog("9824","Agent-20261019T191303.log",[
            "[I 2026-10-19 19:13:03.0696] Agent started as Administrator",
            "  \"account_country\": \"IND\", \"user_name\": \"S-1-5-21-0-0-0-1000\", \"battle_tag\": \"Player#1234\"",
            "[W 2026-10-19 19:13:04.0429] Build marked non-playable for agent: Failed Install Handler - 2110",
            "[W 2026-10-19 19:13:08.0003] Build marked non-playable for prometheus: Permissions check failure (2123)",
            "[W 2026-10-19 19:14:08.0003] Build marked non-playable for prometheus: Permissions check failure (2123)"])
        try agentLog("9824","bc-20261019T191303.log",[
            "[I 2026-10-19 19:13:04.0877] [tact] Adding server node 0. Server 'blizzard.gcdn.cloudn.co.kr' | Address '203.0.113.7'",
            "[I 2026-10-19 19:13:04.0878] [tact] Adding server node 1. Server 'Level3.Blizzard.com' | Address '23.211.177.196'",
            "[I 2026-10-19 19:13:04.0879] [tact] Adding server node 2. Server '198.51.100.4' | Address '198.51.100.4'",
            "[I 2026-10-19 19:13:04.0965] [tact] Selecting entries for tag query Volatile Windows KR? acct-IND? geoip-IN?"])
        let starts=BattleNetRecord.read(root:root)
        precondition(starts.count == 3 && starts.map { $0["started"] as? String } == ["2026-10-19T19:13:03Z","2026-10-18T08:00:00Z","2026-10-17T08:00:00Z"],"\(starts)")
        let last=starts[0]
        precondition(last["agent_version"] as? String == "9824")
        let updates=last["updates"] as! [[String:Any]]
        func update(_ i:Int)->String { let u=updates[i];return "\(u["product"]!) \(u["finished"]!) \(u["waited_seconds"]!) \(u["seconds"]!)" }
        // The agent updating itself for 24 minutes; Overwatch's update waited behind it; the
        // two-hourly agent update took over and was still running ten minutes later.
        precondition(updates.count == 3 && update(0) == "agent true 0 1440" && update(1) == "prometheus true 1435 12" && update(2) == "agent false 0 600","\(updates)")
        precondition(last["not_playable"] as! [String] == ["agent 2110","prometheus 2123"])
        precondition(last["download_servers"] as! [String] == ["blizzard.gcdn.cloudn.co.kr","level3.blizzard.com"])
        let leaked=String(data:try JSONSerialization.data(withJSONObject:starts),encoding:.utf8)!
        for secret in ["IND","Player#1234","S-1-5-21","203.0.113.7","198.51.100.4","acct-","geoip","Agent.9824","C:/"] { precondition(!leaked.contains(secret),secret) }
        let fields=try report("NO","off")
        precondition((fields["battlenet"] as? [String:Any])?["recent_starts"] is [Any])
        print("PASS: MetalFX on/off apart from sharpening; after-match outcomes (cancelled apart from failed), preparing vs waiting for the game to close; Battle.net's last starts")
    }
}
