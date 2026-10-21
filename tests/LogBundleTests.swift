import AppKit

// Save Logs (LogBundle, LogCleaner, LoggingSetting; REC-40) on a made-up data folder holding each kind of
// personal detail the check of real logs found, with Recall's, Battle.net's and Overwatch's logs as they
// write them. Build with every app source but Main.swift, and run:
//   mkdir -p runtime/phase-3/log-tests
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library $(ls app/Sources/*.swift | grep -v Main.swift) \
//     tests/LogBundleTests.swift -o runtime/phase-3/log-tests/log-bundle-tests
//   runtime/phase-3/log-tests/log-bundle-tests
// With --real <data folder> <zip> it saves that folder's logs, as the app would on this Mac.
// Main.swift's AppDelegate, for the one menu action the app's views name.
final class AppDelegate: NSObject { @objc func forceQuit() {} }
@main struct LogBundleTests {
    static let fm=FileManager.default
    static func write(_ root:URL,_ path:String,_ text:String) throws {
        let url=root.appendingPathComponent(path)
        try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(text.utf8).write(to:url)
    }
    static func unzip(_ zip:URL)->URL {
        let out=fm.temporaryDirectory.appendingPathComponent("log-bundle-out-\(UUID().uuidString)")
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");p.arguments=["-x","-k",zip.path,out.path]
        try! p.run();p.waitUntilExit();precondition(p.terminationStatus == 0)
        return out
    }
    /// Every file's text in an unpacked bundle, by its path in the bundle.
    static func contents(_ folder:URL)->[String:String] {
        var result:[String:String]=[:]
        let top=(try! fm.contentsOfDirectory(atPath:folder.path)).first { !$0.hasPrefix(".") }!
        let base=folder.appendingPathComponent(top)
        for case let path as String in fm.enumerator(atPath:base.path)! {
            var directory:ObjCBool=false
            fm.fileExists(atPath:base.appendingPathComponent(path).path,isDirectory:&directory)
            if !directory.boolValue { result[path]=String(decoding:try! Data(contentsOf:base.appendingPathComponent(path)),as:UTF8.self) }
        }
        return result
    }
    @MainActor static func main() throws {
        if let i=CommandLine.arguments.firstIndex(of:"--real"),CommandLine.arguments.count > i+2 {
            let started=Date()
            let input=LogBundle.Input(root:URL(fileURLWithPath:CommandLine.arguments[i+1]),report:"{}",appVersion:"test",runtime:"test",logging:.off,custom:"",since:nil,
                                      readme:URL(fileURLWithPath:"app/Resources/LogsReadme.md"))
            let saved=try LogBundle.save(input,to:URL(fileURLWithPath:CommandLine.arguments[i+2]))
            print("saved \(saved.bytes) bytes, \(saved.sessions) sessions, \(saved.olderLeftOut) older left out, \(Int(Date().timeIntervalSince(started)*1000)) ms")
            return
        }
        // What players paste for Custom, and what Wine takes.
        precondition(LoggingSetting.normalized(" WINEDEBUG=`fixme-all, +seh,,+tid ,+timestamp,+loaddll` ") == "fixme-all,+seh,+tid,+timestamp,+loaddll")
        for good in ["fixme-all,+seh,+tid,+timestamp,+loaddll","warn+all","loaddll","-all","Overwatch.exe:+seh","Battle.net Launcher.exe:warn+winhttp","trace+heap"] {
            precondition(LoggingSetting.valid(good),good)
        }
        for bad in ["","+SEH","+seh;rm -rf","debug+all","+a_channel_name_too_long","+seh,","+seh\n+loaddll"] { precondition(!LoggingSetting.valid(bad),bad) }
        precondition(LoggingSetting.custom.launchArguments(custom:"+seh") == ["--logging","custom","--logging-custom","+seh"])
        precondition(LoggingSetting.crashes.launchArguments(custom:"+seh") == ["--logging","crashes"])

        // Runs of three or more identical Wine lines are kept once, with a count.
        let run=(0..<5).map { "102\($0).000:0024:0028:fixme:ntdll:NtQuerySystemInformation info_class SystemCodeIntegrityInformation" }
        let (collapsed,removed)=LogBundle.collapse((["start"]+run+["1029.000:0024:0028:err:seh:other","a","a","end"]).joined(separator:"\n"))
        precondition(removed == 4,"\(removed)")
        precondition(collapsed == ["start",run[0],"[recall:repeated count=4 last=\"1024.000:0024:0028:\"]","1029.000:0024:0028:err:seh:other","a","a","end"].joined(separator:"\n"),collapsed)

        let root=fm.temporaryDirectory.appendingPathComponent("log-bundle-\(getpid())/Overwatch2Mac")
        try? fm.removeItem(at:root.deletingLastPathComponent())
        defer { try? fm.removeItem(at:root.deletingLastPathComponent()) }
        let user="environment/drive_c/users/crossover"
        // An older Battle.net start (the 18th), before Recall kept sessions.
        try write(root,"\(user)/AppData/Local/Battle.net/Logs/battle.net-20261018T100000.000001.log",
                  "I 2026-10-18 10:00:00.000001 [Main] {Main} Starting\n"+String(repeating:"I 2026-10-18 10:00:01.000000 [Main] {Main} filler line \(UUID().uuidString)\n",count:200))
        // A start on the 17th known only from Battle.net's agent, with an update Battle.net cancelled.
        try write(root,"environment/drive_c/ProgramData/Battle.net/Agent/Agent.9775/Logs/Agent-20261017T080000.log","[I 2026-10-17 08:00:00.0000] Agent starting\r\n")
        try write(root,"environment/drive_c/ProgramData/Battle.net/Agent/Agent.9775/Logs/Operations-20261017T080000.log",[
            "[I 2026-10-17 08:00:10.0000] Queue operation - OP_UPDATE for 'prometheus'",
            "[I 2026-10-17 08:00:10.0000] Active operation nullptr replaced by OP_UPDATE for 'prometheus'",
            "[I 2026-10-17 08:00:50.0000] Cancel requested for active operation - OP_UPDATE for 'prometheus'",
            "[I 2026-10-17 08:00:50.0200] Process finished OP_UPDATE for 'prometheus'",
            "[I 2026-10-17 08:00:50.0200] OP_UPDATE for 'prometheus' done Canceling",
            "[I 2026-10-17 08:05:00.0000] Active operation nullptr replaced by nullptr",
        ].joined(separator:"\r\n")+"\r\n")
        // The session on the 19th: Recall's record and Wine's log, with logging on.
        try write(root,"logs/sessions/20261019T190000Z/session.json",
                  #"{"schema":1,"started":"2026-10-19T19:00:00Z","wine_clock_ms":1000000,"logging":"crashes","winedebug":"-all,err+all,+seh,+loaddll,+timestamp,+pid","dxmt_log_level":"error","games":[{"started":"2026-10-19T19:05:00Z","ended":"2026-10-19T19:20:00Z"}],"ended":"2026-10-19T19:21:00Z"}"#)
        try write(root,"logs/sessions/20261019T190000Z/battlenet.log",([
            "msync: up and running.",
            "1010.000:0024:0028:trace:winsock:gethostname <- \"Testers-MacBook-Pro.local\"",
            "1010.100:0024:0028:trace:winsock:getaddrinfo => family 23, addr { family AF_INET6, address 2600:1700:abcd:1234:5678:9abc:def0:1f, port 0 }",
            "1010.200:0024:0028:trace:winsock:getaddrinfo => family 23, addr { family AF_INET6, address fe80::1c2b:3d4e:5f60:7a8b%en0, port 0 }",
            "1010.300:0024:0028:trace:winsock:connect addr { family AF_INET, address 137.221.64.4, port 443 }, loopback ::1",
            "1011.000:0030:0034:warn:hid:add_device Failed to open device file L\"\\\\??\\\\HID#VID_054C&PID_0CE6#256&a4:83:e7:12:34:56&5140E5D&0&0\"",
            "1012.000:0030:0034:trace:loaddll:build_module Loaded L\"Z:\\\\Users\\\\tester\\\\Library\\\\Application Support\\\\Overwatch2Mac\\\\runtimes\\\\x\\\\d3d11.dll\" at 0000",
            "1013.000:0030:0034:trace:module:load dxmt::Logger::emitMsg std::string a::b",
        ]+run+[
            "wine: Unhandled page fault on read access to 0000000000000040 at address 0000000140001000 (thread 0034), starting debugger...",
            "1500.000:0030:0034:err:seh:dispatch_exception unhandled exception code c0000005",
        ]).joined(separator:"\n")+"\n")
        try write(root,"\(user)/AppData/Local/Battle.net/Logs/battle.net-20261019T185958.000001.log",[
            "I 2026-10-19 18:59:58.000001 [Main] {Main} Running from: Z:\\Users\\tester\\Library\\Application Support\\Overwatch2Mac\\downloads\\x",
            "I 2026-10-19 19:00:01.000000 [GSAccountProvider] {Main} Received AccountLevelInfo for account. entityId=1:0:3a9882ed accountLevelInfo=|country=USA|preferred_region=1|",
            "I 2026-10-19 19:00:02.000000 [Main] {Main} Opened database at: C:\\users\\crossover\\AppData\\Local\\Battle.net\\Account\\123456789\\account.db",
            "E 2026-10-19 19:00:03.000000 [Login] {Main} Login failed for tester@example.com, retrying",
            "I 2026-10-19 19:00:04.000000 [Social] {Main} Friend online: Tracer#11234 and token=QWERTYUIOP123456&x=1",
        ].joined(separator:"\n")+"\n")
        try write(root,"environment/drive_c/ProgramData/Battle.net/Agent/Agent.9824/Logs/Agent-20261019T190003.log",[
            "[I 2026-10-19 19:00:03.0000] Request GET /agent ",
            "Response 200 (6.3050 ms): {",
            "  \"authorization\": \"ABCDEF0123456789ABCDEF\",",
            "  \"session\": \"14154935577319281012\",",
            "  \"user_id\": \"S-1-5-21-1111111111-2222222222-3333333333-1000\",",
            "}",
            "[E 2026-10-19 19:00:05.0000] Build marked non-playable for prometheus: Permissions check failure (2123)",
        ].joined(separator:"\n")+"\n")
        try write(root,"environment/drive_c/ProgramData/Battle.net/Agent/Agent.9824/Logs/Operations-20261019T190003.log",[
            "[I 2026-10-19 19:00:10.0000] Queue operation - OP_UPDATE for 'pro'",
            "[I 2026-10-19 19:00:10.0000] Active operation OP_NONE replaced by OP_UPDATE for 'pro'",
            "[I 2026-10-19 19:01:10.0000] Active operation OP_UPDATE for 'pro' completed",
        ].joined(separator:"\r\n")+"\r\n")
        try write(root,"\(user)/Documents/Overwatch/Logs/Overwatch.log",[
            "[VoiceChat] [External(0)] [External()] [2026-10-19T19:06:00.000Z]: ==[VC] SetTargetOutputDevice Tom Tester’s AirPods Pro #3",
            "[VoiceChat] [External(0)] [External()] [2026-10-19T19:06:00.000Z]: ==[VC] SetTargetInputDevice Tom’s iPhone Microphone",
            "[Main] Overwatch’s Video settings applied. Game Server IP: 24.105.30.129",
        ].joined(separator:"\n")+"\n")
        // Blizzard's crash report as Overwatch writes it, CR CR LF on some lines included (grep counts those once).
        let dashes=String(repeating:"-",count:67)
        try write(root,"\(user)/Documents/Overwatch/Logs/errors/Overwatch_154088_Retailx64_enUS_420_10-19-26_19.19.56_ErrorLog.txt",[
            dashes,"                                ERROR                              ",dashes,"<BlizzardError.Summary:>",
            "Overwatch - 2.25.0.0: EXCEPTION_ACCESS_VIOLATION reading from 0x0000000000000040","<:BlizzardError.Summary>\r","",
            "**Crashing Thread** (ID: 2060)","DBG-ADDR<00000001425641F9>()","DBG-ADDR<00000001425621C8>()","",
            "Bnet account id:           123456789","Game account id:           987654321","Running Time:           0:01:49  (H:M:S)\r",
            "Most Recent Logs:","[NRM] [VoiceChat] [External(0)] [External()] [2026-10-19T19:19:50.000Z]: ==[VC] SetTargetOutputDevice Tom Tester’s AirPods Pro #3",
            "[NRM] [TACT] [External(0)] [External()] [2026-10-19T19:19:55.496Z]: File read failed with error: 1","",dashes,
        ].joined(separator:"\r\n")+"\r\n")
        try write(root,"\(user)/Documents/Overwatch/Logs/errors/Overwatch_154088_Retailx64_enUS_420_10-19-26_19.19.56_Minidump.dmp","MDMP binary memory")
        try fm.setAttributes([.modificationDate:ISO8601DateFormatter().date(from:"2026-10-19T19:19:56Z")!],
                             ofItemAtPath:root.appendingPathComponent("\(user)/Documents/Overwatch/Logs/errors/Overwatch_154088_Retailx64_enUS_420_10-19-26_19.19.56_ErrorLog.txt").path)
        try write(root,"logs/session-query-123.log","  1 Fri Oct  2 10:54:21 2026     /Users/example/Library/Application Support/Figma/FigmaAgent.app\n")
        try write(root,"logs/pipeline-preparation.log","Prepared and verified 5 learned pipelines; 9 of 9 ready\n")

        let identity=LogCleaner.Identity(user:"tester",fullName:"Tom Tester",hosts:["Testers-MacBook-Pro","Testers-MacBook-Pro.local"])
        // Every rule compiles (ICU refuses some patterns, and a refused rule would remove nothing).
        let probe=LogCleaner(user:identity.user,fullName:identity.fullName,hosts:identity.hosts,accountIDs:["123456789"])
        precondition(probe.broken.isEmpty,"\(probe.broken)")
        precondition(LogCleaner.forThisMac(accountIDs:[]).broken.isEmpty)
        let zip=root.deletingLastPathComponent().appendingPathComponent("Recall-logs-test.zip")
        var input=LogBundle.Input(root:root,report:#"{"app_version":"1.5.0","note":"from tester"}"#,appVersion:"1.5.0",runtime:"phase2-20261019.1",
                                  logging:.crashes,custom:"",since:ISO8601DateFormatter().date(from:"2026-10-19T18:00:00Z"),
                                  readme:URL(fileURLWithPath:"app/Resources/LogsReadme.md"),identity:identity)
        let saved=try LogBundle.save(input,to:zip)
        precondition(saved.sessions == 3 && saved.olderLeftOut == 0 && saved.bytes > 0,"\(saved)")
        let files=contents(unzip(zip))
        for path in ["Summary.txt","README.md","index.json","support-report.json","recall/sessions/20261019T190000Z/battlenet.log","recall/sessions/20261019T190000Z/session.json",
                     "battlenet/client/battle.net-20261019T185958.000001.log","battlenet/client/battle.net-20261018T100000.000001.log",
                     "battlenet/agent/Agent.9824/Agent-20261019T190003.log","overwatch/Overwatch.log","recall/pipeline-preparation.log",
                     "overwatch/errors/Overwatch_154088_Retailx64_enUS_420_10-19-26_19.19.56_ErrorLog.txt"] { precondition(files[path] != nil,"missing \(path): \(files.keys.sorted())") }
        // Never: crash dumps, process lists.
        precondition(!files.keys.contains { $0.hasSuffix(".dmp") || $0.contains("session-query") },"\(files.keys.sorted())")
        // Nothing personal is left anywhere.
        let all=files.values.joined(separator:"\n")
        for secret in ["Users\\tester","FigmaAgent","tester@","Tom Tester","Tom’s","Testers-MacBook-Pro","123456789","987654321","3a9882ed","ABCDEF0123456789ABCDEF",
                       "14154935577319281012","S-1-5-21-1111111111","2600:1700","fe80::1c2b","a4:83:e7:12:34:56","Tracer#11234","QWERTYUIOP123456","from tester"] {
            precondition(!all.contains(secret),"left in: \(secret)")
        }
        precondition(!all.lowercased().contains("tester"),"left in: tester")
        // What helps and isn't personal stays: Blizzard's servers, the country, versions, loopback, C++ names, company names.
        for kept in ["137.221.64.4","24.105.30.129","country=USA","2.25.0.0","::1","dxmt::Logger::emitMsg","a::b","Overwatch’s Video","[user]","[name]’s AirPods Pro #3",
                     "[name]’s iPhone","[computer]","[account-id]","[removed]","[windows-user-id]","[ip-address]","[hardware-address]","[email]","[battletag]"] {
            precondition(all.contains(kept),"lost: \(kept)")
        }
        precondition(files["recall/sessions/20261019T190000Z/battlenet.log"]!.contains("[recall:repeated count=4 last=\"1024.000:0024:0028:\"]"))

        let index=try JSONSerialization.jsonObject(with:Data(files["index.json"]!.utf8)) as! [String:Any]
        let moments=index["moments"] as! [[String:Any]]
        func moment(_ kind:String)->[String:Any]? { moments.first { $0["kind"] as? String == kind } }
        for kind in ["session_started","game_started","game_ended","session_ended","battlenet_started","battlenet_update","battlenet_not_playable","overwatch_crash","windows_program_error"] {
            precondition(moment(kind) != nil,"no \(kind) in \(moments.map { $0["kind"]! })")
        }
        let update=moments.first { $0["kind"] as? String == "battlenet_update" && $0["product"] as? String == "pro" }!
        precondition(update["seconds"] as? Int == 60 && update["finished"] as? Bool == true && update["cancelled"] as? Bool == false,"\(update)")
        precondition(moment("battlenet_not_playable")!["code"] as? String == "2123")
        let crash=moment("overwatch_crash")!
        precondition(crash["after_failed_read"] as? Bool == true && crash["line"] as? Int == 5 && crash["running_time"] as? String == "0:01:49  (H:M:S)","\(crash)")
        precondition(crash["top_frames"] as? [String] == ["DBG-ADDR<00000001425641F9>()","DBG-ADDR<00000001425621C8>()"],"\(crash)")
        precondition((crash["last_log_line"] as? [String:Any])?["line"] as? Int == 17,"\(crash)")
        let cancelled=moments.first { $0["kind"] as? String == "battlenet_update" && $0["cancelled"] as? Bool == true }!
        precondition(cancelled["seconds"] as? Int == 40 && cancelled["finished"] as? Bool == false,"\(cancelled)")
        precondition(moment("overwatch_log_started") != nil)
        // Newest session first.
        let listed=(index["sessions"] as! [[String:Any]]).map { $0["started"] as! String }
        precondition(listed == ["2026-10-19T18:59:58Z","2026-10-18T10:00:00Z","2026-10-17T08:00:00Z"],"\(listed)")
        // Wine's clock: the last line before it, 1024 s (kept in the repeat marker), on a session that
        // started at 19:00:00 with Wine at 1000 s.
        precondition(moment("windows_program_error")!["time"] as? String == "2026-10-19T19:00:24Z","\(moment("windows_program_error")!)")
        precondition((moment("windows_program_error")!["line"] as? Int) == 11,"\(moment("windows_program_error")!)")
        precondition((index["errors"] as! [[String:Any]]).contains { ($0["text"] as? String)?.contains("err:seh:dispatch_exception") == true })
        precondition((index["left_out"] as! [String:Any])["crash_dumps"] as? Int == 1)
        precondition((index["removed"] as! [String:Int]).keys.contains("account_id"))
        precondition((index["logging"] as! [String:Any])["setting"] as? String == "crashes")

        let summary=files["Summary.txt"]!
        for line in ["Logging: Crashes and freezes","Battle.net opened. Logging: Crashes and freezes.","Battle.net updated Overwatch (1 min).",
                     "Battle.net marked Overwatch not playable (code 2123).","Overwatch started.","Overwatch closed.","Battle.net closed.",
                     "Overwatch crashed: Overwatch - 2.25.0.0: EXCEPTION_ACCESS_VIOLATION reading from 0x0000000000000040",
                     "Just before, it couldn’t read one of its game files.","Battle.net stopped updating Overwatch after 40 sec.",
                     "Removed before saving:","For an AI assistant, start with README.md."] {
            precondition(summary.contains(line),"summary lacks \(line):\n\(summary)")
        }
        // The 18th's start is told once, from Battle.net's own log; the 19th's once, from Recall's record;
        // Overwatch's own log of the run Recall recorded isn't told again.
        precondition(summary.components(separatedBy:"Battle.net opened.").count-1 == 2,summary)
        precondition(summary.components(separatedBy:"Overwatch started.").count-1 == 1,summary)
        // Newest day first.
        precondition(summary.range(of:"October 19")!.lowerBound < summary.range(of:"October 17")!.lowerBound,summary)

        // Too big for the limit: the newest session only, and the summary says so.
        input.limit=1
        let small=try LogBundle.save(input,to:zip)
        precondition(small.sessions == 1 && small.olderLeftOut == 2,"\(small)")
        let smaller=contents(unzip(zip))
        precondition(smaller["battlenet/client/battle.net-20261018T100000.000001.log"] == nil)
        precondition(smaller["Summary.txt"]!.contains("Older sessions left out: 2.") && smaller["Summary.txt"]!.contains("larger than GitHub’s 25 MB limit"))
        print("PASS: Custom text as Wine reads it; repeats collapsed; every personal detail found in real logs removed, helpful details kept; crash dumps and process lists left out; moments with files, lines and Wine's clock; the summary; the GitHub limit")
    }
}
