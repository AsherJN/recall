import AppKit

// The busy note's reading and decisions (app/Sources/BusyApps.swift, REC-5):
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/BusyApps.swift \
//     tests/BusyAppsTests.swift -o runtime/phase-3/busy-apps-tests
//   runtime/phase-3/busy-apps-tests
@main struct BusyAppsTests {
    static var failures=0
    static func check(_ condition:Bool,_ message:String,line:Int=#line) {
        if !condition { failures+=1;print("FAIL line \(line): \(message)") }
    }
    static func main() {
        let second:UInt64=1_000_000_000
        // Usage over two seconds: a helper counts toward the app responsible for it, processor
        // and graphics time become percents, memory is what each holds at the end.
        var first=BusyApps.Sample(time:10*second),last=BusyApps.Sample(time:12*second)
        first.cpu=[100:1*second,101:0,200:5*second];last.cpu=[100:3*second,101:2*second,200:5*second,300:9*second]
        first.gpu=[101:0,999:0];last.gpu=[101:second,999:2*second]
        last.memory=[100:1<<30,101:2<<30,200:512<<20,300:1<<20]
        last.responsible=[100:100,101:100,200:200,300:300]
        let usage=BusyApps.usage(from:first,to:last)
        check(usage[100]?.cpu == 200,"app and helper: 2 s + 2 s of processor over 2 s is 200%, got \(String(describing:usage[100]?.cpu))")
        check(usage[100]?.gpu == 50,"helper's 1 s of graphics over 2 s is 50%")
        check(usage[100]?.memory == 3<<30,"app and helper hold 3 GiB")
        check(usage[200]?.cpu == 0,"an idle app uses nothing")
        check(usage[300]?.cpu == 0 && usage[300]?.memory == 1<<20,"a process that started meanwhile has no processor reading yet, only memory")
        check(usage[101] == nil,"a helper has no row of its own")
        check(usage[999] == nil,"another user's process (graphics only) is never named")
        check(BusyApps.usage(from:last,to:last).isEmpty,"no time between samples, no reading")

        // Which apps to name. The processor line is given (it follows the Mac's fast cores).
        typealias Use=BusyApps.Usage
        let line=BusyApps.gpuLine,game=BusyApps.gameMemory,cores=400.0
        func names(_ usage:[Use],memory:UInt64=game*2)->[pid_t] { BusyApps.busy(usage,availableMemory:memory,cpuLine:cores).map(\.pid) }
        let quiet=Use(pid:1,cpu:cores*0.9,gpu:line*0.9,memory:8<<30)
        check(names([quiet]).isEmpty,"under every line, with memory to spare: nothing")
        // Graphics: together over the line; without the larger the rest fits under it.
        let video=Use(pid:2,cpu:50,gpu:line*0.6,memory:1<<30),other=Use(pid:3,cpu:0,gpu:line*0.5,memory:0)
        let graphics=BusyApps.busy([video,other],availableMemory:game*2,cpuLine:cores)
        check(graphics.map(\.pid) == [2] && graphics.first?.reasons == [.graphics],"graphics over the line together: the larger user, got \(graphics.map(\.pid))")
        check(names([video]).isEmpty,"one app under the graphics line alone")
        // Processor: 300% + 150% + 100% is 150% over; the 300% app is enough.
        let processor=[Use(pid:4,cpu:150,gpu:0,memory:0),Use(pid:5,cpu:300,gpu:0,memory:0),Use(pid:6,cpu:100,gpu:0,memory:0)]
        check(names(processor) == [5],"processor over the line together: the largest user")
        check(names([Use(pid:7,cpu:cores,gpu:0,memory:0)]) == [7],"one app at the line")
        // Graphics first; an app over two lines is named once, for both.
        let both=BusyApps.busy([Use(pid:8,cpu:cores,gpu:0,memory:0),Use(pid:9,cpu:cores,gpu:line,memory:0)],availableMemory:game*2,cpuLine:cores)
        check(both.map(\.pid) == [9,8] && both.first?.reasons == [.graphics,.processor],"graphics first, both reasons, got \(both.map(\.reasons))")
        // Memory short by 3 GiB: the app holding 8 GiB frees enough on its own.
        let short=BusyApps.busy([quiet,Use(pid:10,cpu:0,gpu:0,memory:1<<30)],availableMemory:game-(3<<30),cpuLine:cores)
        check(short.map(\.pid) == [1] && short.first?.reasons == [.memory],"memory short: the largest app, for memory")
        // Short by 2.5 GiB: 2 GiB and 1 GiB together free enough; 512 MiB isn't needed.
        let held=[Use(pid:11,cpu:0,gpu:0,memory:512<<20),Use(pid:12,cpu:0,gpu:0,memory:2<<30),Use(pid:13,cpu:0,gpu:0,memory:1<<30)]
        check(names(held,memory:game-(5<<29)) == [12,13],"the largest apps until they'd free enough")
        check(names(held,memory:0) == [12,13,11],"no memory to spare: every app holding some, largest first")

        // Never named: Recall itself, macOS's own apps.
        check(BusyApps.quittable(getpid(),excluding:[]) == nil,"Recall itself")
        if let dock=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first {
            check(BusyApps.quittable(dock.processIdentifier,excluding:[]) == nil,"the Dock (in /System/Library)")
        }
        if let finder=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first {
            check(BusyApps.quittable(finder.processIdentifier,excluding:[]) == nil,"the Finder")
        }
        if let app=NSWorkspace.shared.runningApplications.first(where:{ $0.activationPolicy == .regular && $0.bundleURL?.path.hasPrefix("/Applications/") == true }),
           let path=app.bundleURL?.path {
            check(BusyApps.quittable(app.processIdentifier,excluding:[]) != nil,"\(app.localizedName ?? path) can be quit")
            check(BusyApps.quittable(app.processIdentifier,excluding:[(path as NSString).deletingLastPathComponent+"/"]) == nil,"an app under an excluded folder")
        }

        // A real reading of this Mac.
        let a=BusyApps.sample()
        var spin=0.0;for i in 0..<20_000_000 { spin+=Double(i).squareRoot() }
        let b=BusyApps.sample()
        check(spin > 0 && (b.cpu[getpid()] ?? 0) > (a.cpu[getpid()] ?? 0),"this process's processor time is read")
        check(b.memory[getpid()] ?? 0 > 0,"this process's memory is read")
        check(!b.gpu.isEmpty,"graphics time is read from the GPU driver")
        check(b.cpu.keys.allSatisfy { b.responsible[$0] != nil },"every process has a responsible app")

        // The Support Report's record.
        var load=MacLoad(apps:[MacLoad.App(pid:5,name:"Steam",path:"/Applications/Steam.app",bundleID:nil,cpu:240.4,gpu:0,memory:3<<29,reasons:[.processor])],lowPowerMode:true,thermal:"serious",availableMemory:6<<30)
        check(load.found && load.hot,"busy, hot")
        let rows=load.report["busy_apps"] as? [[String:Any]]
        check(rows?.first?["name"] as? String == "Steam" && rows?.first?["processor_percent"] as? Int == 240 && rows?.first?["memory_gib"] as? Double == 1.5
              && rows?.first?["reasons"] as? [String] == ["processor"],"report names the app with its numbers and reasons")
        check(load.report["available_memory_gib"] as? Int == 6 && load.report["thermal"] as? String == "serious" && load.report["low_power_mode"] as? Bool == true,"report gives the Mac's state")
        load=MacLoad(thermal:"fair")
        check(!load.found,"a warm Mac that macOS doesn't slow down, nothing busy: nothing to say")

        // Low memory is macOS's own pressure reading; memory on disk is only reported.
        check(!BusyApps.lowMemory(pressure:1) && !BusyApps.lowMemory(pressure:0),"normal or unread pressure: fine")
        check(BusyApps.lowMemory(pressure:2) && BusyApps.lowMemory(pressure:4),"warning or critical pressure: low on memory")
        // Under pressure the largest memory users are named until they hold Overwatch's footprint,
        // even with plenty "available" (kern.memorystatus_level counts compressed memory as free).
        let code=Use(pid:20,cpu:0,gpu:0,memory:4_400_000_000),safari=Use(pid:21,cpu:0,gpu:0,memory:1_700_000_000)
        let discord=Use(pid:22,cpu:0,gpu:0,memory:650_000_000),notes=Use(pid:23,cpu:0,gpu:0,memory:200_000_000)
        check(names([code,safari,discord,notes]).isEmpty,"normal pressure, room to spare: memory names nobody")
        let squeezed=BusyApps.busy([notes,discord,safari,code],availableMemory:game*2,lowMemory:true,cpuLine:cores)
        check(squeezed.map(\.pid) == [20,21] && squeezed.allSatisfy { $0.reasons == [.memory] },
              "pressure: Visual Studio Code and Safari together hold Overwatch's footprint, the rest stay unnamed, got \(squeezed.map(\.pid))")
        var (kept,restart)=BusyApps.forPressure(squeezed,gameRunning:false)
        check(kept == squeezed && !restart,"quitting them makes room: no restart")
        (kept,restart)=BusyApps.forPressure(squeezed,gameRunning:true)
        check(kept == squeezed && !restart,"mid-match the same apps are named, to make room for the game")
        // Only small apps open: quitting them all couldn't make room, so macOS holds the memory.
        let small=BusyApps.busy([discord,notes],availableMemory:game*2,lowMemory:true,cpuLine:cores)
        check(small.map(\.pid) == [22,23],"pressure with only small apps: both named at first")
        (kept,restart)=BusyApps.forPressure(small,gameRunning:false)
        check(kept.isEmpty && restart,"they couldn't make room: unnamed, restart instead")
        (kept,restart)=BusyApps.forPressure(small,gameRunning:true)
        check(kept.isEmpty && !restart,"mid-match a restart can't help: nothing said")
        // An app named for its processor too keeps that reason when its memory can't help.
        let busyChat=Use(pid:24,cpu:cores+50,gpu:0,memory:650_000_000)
        (kept,_)=BusyApps.forPressure(BusyApps.busy([busyChat,notes],availableMemory:game*2,lowMemory:true,cpuLine:cores),gameRunning:false)
        check(kept.map(\.pid) == [24] && kept.first?.reasons == [.processor],"a busy app stays named for its processor only")
        (kept,restart)=BusyApps.forPressure([],gameRunning:false)
        check(kept.isEmpty && restart,"pressure with no apps of the player's open: restart")

        load=MacLoad(memoryPressure:2,lowMemory:true)
        check(!load.found && !load.quitForMemory,"pressure while apps are being named is no row of its own")
        load.apps=[MacLoad.App(pid:20,name:"Code",path:"",bundleID:nil,cpu:0,gpu:0,memory:4_400_000_000,reasons:[.memory])]
        check(load.found && load.quitForMemory,"apps named under pressure: the note says the Mac is low on memory")
        load.lowMemory=false
        check(!load.quitForMemory,"apps named for memory without pressure keep the FPS wording")
        load=MacLoad(swapUsed:3<<29,memoryPressure:2,lowMemory:true,restart:true)
        check(load.found,"a restart alone is worth a row")
        check(load.report["low_memory"] as? Bool == true && load.report["suggests_restart"] as? Bool == true && load.report["swap_used_gib"] as? Double == 1.5
              && load.report["memory_pressure"] as? String == "warning","report gives the advice, memory on disk and macOS's pressure")
        check(MacLoad().report["memory_pressure"] as? String == "unknown" && MacLoad().report["low_memory"] as? Bool == false,"unread pressure reads unknown")
        // A real reading: mid-match a restart is never suggested.
        let live=BusyApps.load(from:a,to:b,excluding:[],gameRunning:true)
        check(!live.restart && live.memoryPressure > 0 && live.lowMemory == BusyApps.lowMemory(pressure:live.memoryPressure),
              "this Mac's pressure is read, and no restart is suggested while Overwatch runs (pressure \(live.memoryPressure))")

        print(failures == 0 ? "PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
