import AppKit
import IOKit
import IOKit.ps

/// What else is using this Mac as Overwatch starts (REC-5): open apps busy enough to cost it
/// frames, Low Power Mode, and a Mac hot enough that macOS slows it down. The numbers are
/// Activity Monitor's (processor and graphics time, memory), read without any permission:
/// processor time and memory of this user's processes, graphics time from the GPU driver's
/// per-client counters in the I/O Registry. Helper processes count toward the app macOS holds
/// responsible for them (Safari's web pages, Chrome's renderers). Nothing leaves the Mac.
struct MacLoad: Equatable {
    struct App: Identifiable, Equatable {
        let pid:pid_t
        let name:String
        /// The app's bundle, for its icon.
        let path:String
        let bundleID:String?
        /// Percent of one processor core, and of the graphics processor's time, over the sample.
        var cpu:Double
        var gpu:Double
        var memory:UInt64
        /// What it uses enough of to name it.
        var reasons:[BusyApps.Reason]
        var id:pid_t { pid }
    }
    /// Busy enough to matter, most first; Recall and its Battle.net and Overwatch never count.
    var apps:[App]=[]
    var lowPowerMode=false
    /// ProcessInfo.ThermalState as a word; from "serious" macOS slows the Mac to cool it.
    var thermal="nominal"
    var hot:Bool { thermal == "serious" || thermal == "critical" }
    /// What macOS says it could hand Overwatch without pressure (kern.memorystatus_level).
    var availableMemory:UInt64=0
    /// Memory macOS has moved to disk (vm.swapusage), for the report only, and its pressure level
    /// (kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical; 0 unread).
    var swapUsed:UInt64=0
    var memoryPressure:Int32=0
    /// macOS reports memory pressure (BusyApps.lowMemory): the apps using the most are named.
    var lowMemory=false
    /// Low on memory with no apps of the player's that could make room, before Overwatch starts:
    /// macOS itself holds the memory, and a restart frees it (BusyApps.forPressure).
    var restart=false
    var found:Bool { !apps.isEmpty || lowPowerMode || hot || restart }
    /// Apps named for memory while macOS reports pressure, which the note says (PerformanceTip).
    var quitForMemory:Bool { lowMemory && apps.contains { $0.reasons.contains(.memory) } }
    /// A MacBook: System Settings names the Low Power Mode pane Battery, other Macs Energy.
    static let hasBattery:Bool={
        guard let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources=IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            (IOPSGetPowerSourceDescription(info,source)?.takeUnretainedValue() as? [String:Any])?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
    /// The Support Report's record (AppModel.makeReport).
    var report:[String:Any] {
        ["busy_apps":apps.map { ["name":$0.name,"processor_percent":Int($0.cpu.rounded()),"graphics_percent":Int($0.gpu.rounded()),
                                 "memory_gib":(Double($0.memory)/Double(1<<30)*10).rounded()/10,"reasons":$0.reasons.map(\.rawValue)] },
         "low_power_mode":lowPowerMode,"thermal":thermal,"available_memory_gib":availableMemory == .max ? -1 : Int(availableMemory>>30),
         "low_memory":lowMemory,"suggests_restart":restart,"swap_used_gib":(Double(swapUsed)/Double(1<<30)*10).rounded()/10,
         "memory_pressure":[1:"normal",2:"warning",4:"critical"][memoryPressure] ?? "unknown"]
    }
}

enum BusyApps {
    /// Graphics: other apps' combined share of the graphics processor at which Overwatch lost
    /// frames, off screen (October 19, REC-5): 4% cost nothing, 8% about 13%.
    static let gpuLine:Double=8
    /// Processor: performance cores Overwatch needs to itself. In a real match
    /// its four busiest threads used 2.3 cores (2.6 at p90, 3.2 at most; play-test of
    /// September 30), and the replay, using 1.2, lost frames once fewer than 2 fast cores were
    /// left. Other apps may keep the rest busy; past that, their combined use costs frames.
    static let gameCores=4
    /// This Mac's performance cores (hw.perflevel0; all cores on a Mac without levels).
    static let fastCores:Int={
        var cores:Int32=0,size=MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu",&cores,&size,nil,0) == 0,cores > 0 { return Int(cores) }
        return ProcessInfo.processInfo.activeProcessorCount
    }()
    static var cpuLine:Double { Double(max(1,fastCores-gameCores))*100 }
    /// Overwatch's footprint in a match at the owner's settings, Shader memory "All"
    /// (October 14; 9.6 GB at maximum settings). Other apps' memory matters when the Mac
    /// can't spare this much.
    static let gameMemory:UInt64=5_650_000_000
    /// macOS's own reading that memory is short now, as Activity Monitor's memory graph turns
    /// yellow (warning) or red (critical). On October 20 the owner's 16 GB M1 Pro, six days without
    /// a restart, was at "warning" with Overwatch loaded and 3.1 GB of the game's 4.7 GB compressed:
    /// FPS held while movement and aim answered late, for 30-60 s after a map loaded or after long
    /// in another app. Memory moved to disk is no sign: an hour after a restart and one match, the
    /// same Mac had 1.4 GB there at "normal", as it stays there long after the pressure ends.
    static func lowMemory(pressure:Int32)->Bool { pressure >= 2 }
    enum Reason: String { case graphics, processor, memory }
    /// One app's use over a sample, and why it's named once decided.
    struct Usage: Equatable {
        let pid:pid_t
        var cpu:Double
        var gpu:Double
        var memory:UInt64
        var reasons:[Reason]=[]
    }
    /// Which apps to name. For graphics, processor and memory in turn: when other apps together
    /// use more than Overwatch can spare, the largest users until the rest would fit; under memory
    /// pressure, until they hold Overwatch's footprint. Graphics first, as it costs Overwatch the
    /// most; an app named for more than one lists each.
    static func busy(_ usage:[Usage],availableMemory:UInt64,lowMemory:Bool=false,cpuLine:Double=cpuLine)->[Usage] {
        var found:[Usage]=[]
        /// Names the largest users until `excess` (how far over the line they are) is gone.
        func name(_ reason:Reason,excess:Double,_ amount:(Usage)->Double) {
            var excess=excess
            for use in usage.sorted(by:{ amount($0) > amount($1) }) where excess >= 0 && amount(use) > 0 {
                excess-=amount(use)
                if let i=found.firstIndex(where:{ $0.pid == use.pid }) { found[i].reasons.append(reason) }
                else { var use=use;use.reasons=[reason];found.append(use) }
            }
        }
        name(.graphics,excess:usage.reduce(0) { $0+$1.gpu }-gpuLine) { $0.gpu }
        name(.processor,excess:usage.reduce(0) { $0+$1.cpu }-cpuLine) { $0.cpu }
        // Memory: enough freed for Overwatch's footprint; all of it under pressure.
        let room=lowMemory ? 0 : availableMemory
        if gameMemory > room { name(.memory,excess:Double(gameMemory-room)-1) { Double($0.memory) } }
        return found
    }
    /// Under memory pressure, the apps named for memory stay if quitting them all would make room
    /// for Overwatch. Otherwise macOS itself holds the memory: they lose that reason, and before
    /// Overwatch starts a restart is suggested instead. Restarting doesn't help with apps the
    /// player opens again, and mid-match it can't help at all.
    static func forPressure(_ found:[Usage],gameRunning:Bool)->(apps:[Usage],restart:Bool) {
        guard found.filter({ $0.reasons.contains(.memory) }).reduce(0,{ $0+$1.memory }) < gameMemory else { return (found,false) }
        return (found.compactMap { use in var use=use;use.reasons.removeAll { $0 == .memory };return use.reasons.isEmpty ? nil : use },!gameRunning)
    }

    // MARK: Reading the Mac

    struct Sample {
        let time:UInt64
        var cpu:[pid_t:UInt64]=[:]
        var memory:[pid_t:UInt64]=[:]
        var gpu:[pid_t:UInt64]=[:]
        var responsible:[pid_t:pid_t]=[:]
    }
    /// Processor time (ns), footprint and responsible app of each of this user's processes,
    /// and graphics time (ns) of each process that has used the GPU since it started.
    static func sample()->Sample {
        var sample=Sample(time:clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let uid=getuid()
        for pid in processes() {
            var info=proc_taskinfo()
            guard proc_pidinfo(pid,PROC_PIDTASKINFO,0,&info,Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size else { continue }
            var bsd=proc_bsdshortinfo()
            guard proc_pidinfo(pid,PROC_PIDT_SHORTBSDINFO,0,&bsd,Int32(MemoryLayout<proc_bsdshortinfo>.size)) == MemoryLayout<proc_bsdshortinfo>.size,
                  bsd.pbsi_uid == uid else { continue }
            sample.cpu[pid]=nanoseconds(info.pti_total_user+info.pti_total_system)
            var usage=rusage_info_v4()
            let read=withUnsafeMutablePointer(to:&usage) { $0.withMemoryRebound(to:rusage_info_t?.self,capacity:1) { proc_pid_rusage(pid,RUSAGE_INFO_V4,$0) } }
            sample.memory[pid]=read == 0 ? usage.ri_phys_footprint : 0
            sample.responsible[pid]=responsiblePID?(pid) ?? pid
        }
        sample.gpu=graphicsTime()
        return sample
    }
    /// Use between two samples, per responsible app.
    static func usage(from first:Sample,to second:Sample)->[pid_t:Usage] {
        let seconds=Double(second.time-first.time)/1e9
        guard seconds > 0 else { return [:] }
        var apps:[pid_t:Usage]=[:]
        for (pid,cpu) in second.cpu {
            let owner=second.responsible[pid] ?? pid
            var app=apps[owner] ?? Usage(pid:owner,cpu:0,gpu:0,memory:0)
            if let before=first.cpu[pid],cpu >= before { app.cpu+=Double(cpu-before)/1e9/seconds*100 }
            app.memory+=second.memory[pid] ?? 0
            if let gpu=second.gpu[pid],let before=first.gpu[pid],gpu >= before { app.gpu+=Double(gpu-before)/1e9/seconds*100 }
            apps[owner]=app
        }
        return apps
    }
    /// The apps a player can quit, with their names; never Recall, its session or macOS's own.
    static func quittable(_ pid:pid_t,excluding paths:[String])->NSRunningApplication? {
        guard pid != getpid(),let app=NSRunningApplication(processIdentifier:pid),
              app.activationPolicy != .prohibited,!app.isTerminated,app.bundleIdentifier != "com.apple.finder" else { return nil }
        let path=app.bundleURL?.path ?? app.executableURL?.path ?? ""
        if path.isEmpty || path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/") { return nil }
        if paths.contains(where:{ path.hasPrefix($0) }) { return nil }
        return app
    }
    /// One look at the Mac over `seconds`: busy apps, Low Power Mode, heat, spare memory and a squeezed Mac.
    static func check(over seconds:Double=2,excluding paths:[String],gameRunning:Bool=false) async -> MacLoad {
        let first=await Task.detached(priority:.utility) { sample() }.value
        try? await Task.sleep(for:.seconds(seconds))
        return await Task.detached(priority:.utility) { load(from:first,to:sample(),excluding:paths,gameRunning:gameRunning) }.value
    }
    /// With Overwatch already running its memory is in use, so other apps' is weighed against it
    /// only under pressure, when the largest are named to make room for it; no restart then.
    static func load(from first:Sample,to second:Sample,excluding paths:[String],gameRunning:Bool=false)->MacLoad {
        let thermal=["nominal","fair","serious","critical"]
        var load=MacLoad(lowPowerMode:ProcessInfo.processInfo.isLowPowerModeEnabled,
                         thermal:thermal[min(thermal.count-1,ProcessInfo.processInfo.thermalState.rawValue)],
                         availableMemory:availableMemory(),swapUsed:swapUsed(),memoryPressure:memoryPressure())
        load.lowMemory=lowMemory(pressure:load.memoryPressure)
        let usage=usage(from:first,to:second).values.compactMap { use -> (Usage,NSRunningApplication)? in
            quittable(use.pid,excluding:paths).map { (use,$0) }
        }
        let names=Dictionary(usage.map { ($0.0.pid,$0.1) },uniquingKeysWith:{ a,_ in a })
        var found=busy(usage.map(\.0),availableMemory:gameRunning ? .max : load.availableMemory,lowMemory:load.lowMemory)
        if load.lowMemory { (found,load.restart)=forPressure(found,gameRunning:gameRunning) }
        load.apps=found.compactMap { use in
            names[use.pid].map { MacLoad.App(pid:use.pid,name:$0.localizedName ?? $0.bundleURL?.deletingPathExtension().lastPathComponent ?? "?",
                                             path:$0.bundleURL?.path ?? $0.executableURL?.path ?? "",bundleID:$0.bundleIdentifier,
                                             cpu:use.cpu,gpu:use.gpu,memory:use.memory,reasons:use.reasons) }
        }
        return load
    }

    private static func processes()->[pid_t] {
        let size=proc_listpids(UInt32(PROC_ALL_PIDS),0,nil,0)
        guard size > 0 else { return [] }
        var pids=[pid_t](repeating:0,count:Int(size)/MemoryLayout<pid_t>.size+32)
        let read=proc_listpids(UInt32(PROC_ALL_PIDS),0,&pids,Int32(pids.count*MemoryLayout<pid_t>.size))
        return pids.prefix(max(0,Int(read))/MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }
    private static let timebase:mach_timebase_info_data_t={ var info=mach_timebase_info_data_t();mach_timebase_info(&info);return info }()
    private static func nanoseconds(_ ticks:UInt64)->UInt64 { ticks*UInt64(timebase.numer)/UInt64(max(1,timebase.denom)) }
    /// The app macOS holds responsible for a process, as Activity Monitor groups them. Not public
    /// API; without it each process stands for itself and helpers go unnamed.
    private typealias Responsible=@convention(c) (pid_t)->pid_t
    private static let responsiblePID:Responsible?={
        dlsym(UnsafeMutableRawPointer(bitPattern:-2),"responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0,to:Responsible.self) }
    }()
    /// Graphics time per process from the GPU driver's user clients (`AppUsage`, ns), as
    /// `ioreg -c AGXDeviceUserClient` shows them. Empty if the driver stops publishing it.
    private static func graphicsTime()->[pid_t:UInt64] {
        var times:[pid_t:UInt64]=[:]
        var accelerators:io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOAccelerator"),&accelerators) == KERN_SUCCESS else { return times }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator=IOIteratorNext(accelerators),accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients:io_iterator_t=0
            guard IORegistryEntryGetChildIterator(accelerator,kIOServicePlane,&clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client=IOIteratorNext(clients),client != 0 {
                defer { IOObjectRelease(client) }
                // "pid 1234, Safari"
                guard let creator=IORegistryEntryCreateCFProperty(client,"IOUserClientCreator" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String,
                      creator.hasPrefix("pid "),let pid=pid_t(creator.dropFirst(4).prefix { $0 != "," }),
                      let usage=IORegistryEntryCreateCFProperty(client,"AppUsage" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? [[String:Any]] else { continue }
                times[pid,default:0]+=usage.reduce(0) { $0+((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
            }
        }
        return times
    }
    /// macOS's estimate of memory it can hand out without pressure, as `memory_pressure` prints it.
    private static func availableMemory()->UInt64 {
        var level:Int32=0,size=MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level",&level,&size,nil,0) == 0 else { return .max }
        return ProcessInfo.processInfo.physicalMemory/100*UInt64(max(0,level))
    }
    /// Memory moved to disk, as `sysctl vm.swapusage` prints it; 0 if unread.
    private static func swapUsed()->UInt64 {
        var usage=xsw_usage(),size=MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage",&usage,&size,nil,0) == 0 else { return 0 }
        return usage.xsu_used
    }
    /// macOS's memory pressure (1 normal, 2 warning, 4 critical), as Activity Monitor colours it; 0 if unread.
    private static func memoryPressure()->Int32 {
        var level:Int32=0,size=MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level",&level,&size,nil,0) == 0 else { return 0 }
        return level
    }
}
