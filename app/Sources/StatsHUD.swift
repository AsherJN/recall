import AppKit
import SwiftUI
import IOKit.ps

// Readers adapted from exelban/Stats (MIT), copyright Serhiy Mytrovtsiy.
// Pinned source and modifications: THIRD_PARTY_NOTICES.md; license: licenses/STATS-MIT.
struct HUDStats {
    var cpu:Double?
    var gpu:Double?
    var battery:HUDBattery?
    var date=Date()

    static func percent(_ value:Double?)->String {
        guard let value,value.isFinite else { return "—" }
        return "\(Int(min(100,max(0,value)).rounded()))%"
    }
}

struct HUDBattery {
    let percent:Double?
    let detail:String
    let time:String?
    let isCharging:Bool

    // Stats uses the OS's smoothed time-to-empty, not a percentage / elapsed-time guess.
    // Keep unknown and external-power states distinct from a zero-minute estimate.
    init(_ source:[String:Any]) {
        if let current=source[kIOPSCurrentCapacityKey] as? Int,
           let maximum=source[kIOPSMaxCapacityKey] as? Int,maximum>0,current>=0 {
            percent=100*Double(current)/Double(maximum)
        } else { percent=nil }
        let onBattery=source[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        let charging=source[kIOPSIsChargingKey] as? Bool == true
        isCharging=charging
        if onBattery,let minutes=source[kIOPSTimeToEmptyKey] as? Int,minutes>0 {
            time="≈"+Self.duration(minutes)
        } else { time=onBattery ? "…" : nil }
        if onBattery {
            if let minutes=source[kIOPSTimeToEmptyKey] as? Int,minutes>0 {
                detail=L("≈ {0} remaining",Self.duration(minutes))
            } else { detail=L("Estimating…") }
        } else if source[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
            if source[kIOPSIsChargedKey] as? Bool == true { detail=L("Fully charged") }
            else if source[kIOPSIsChargingKey] as? Bool == true {
                if let minutes=source[kIOPSTimeToFullChargeKey] as? Int,minutes>0 {
                    detail=L("{0} until full",Self.duration(minutes))
                } else { detail=L("Charging") }
            } else { detail=L("Plugged in") }
        } else { detail="—" }
    }

    private static func duration(_ minutes:Int)->String {
        let formatter=DateComponentsFormatter()
        formatter.allowedUnits=minutes>=60 ? [.hour,.minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from:TimeInterval(minutes)*60) ?? "—"
    }
}

final class HUDStatsReader {
    private var previous:host_cpu_load_info?
    func reset() { previous=nil }

    func read()->HUDStats {
        HUDStats(cpu:readCPU(),gpu:readGPU(),battery:readBattery())
    }

    static func cpuUsage(_ current:host_cpu_load_info,_ previous:host_cpu_load_info)->Double? {
        let user=Double(current.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system=Double(current.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle=Double(current.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice=Double(current.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total=user+system+idle+nice
        return total>0 ? 100*(user+system+nice)/total : nil
    }

    private func readCPU()->Double? {
        let count=MemoryLayout<host_cpu_load_info>.stride/MemoryLayout<integer_t>.stride
        var size=mach_msg_type_number_t(count),info=host_cpu_load_info()
        let host=mach_host_self()
        defer { mach_port_deallocate(mach_task_self_,host) }
        let result=withUnsafeMutablePointer(to:&info) {
            $0.withMemoryRebound(to:integer_t.self,capacity:count) {
                host_statistics(host,HOST_CPU_LOAD_INFO,$0,&size)
            }
        }
        guard result == KERN_SUCCESS else { previous=nil;return nil }
        defer { previous=info }
        guard let previous else { return nil }
        return Self.cpuUsage(info,previous)
    }

    private func readGPU()->Double? {
        var iterator:io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOAccelerator"),&iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var values:[Double]=[]
        while case let service=IOIteratorNext(iterator),service != 0 {
            defer { IOObjectRelease(service) }
            guard let property=IORegistryEntryCreateCFProperty(service,"PerformanceStatistics" as CFString,kCFAllocatorDefault,0),
                  let stats=property.takeRetainedValue() as? [String:Any],
                  let value=stats["Device Utilization %"] as? Double ?? stats["GPU Activity(%)"] as? Double,
                  value.isFinite,(0...100).contains(value) else { continue }
            values.append(value)
        }
        // Like Stats' automatic selection, show the busiest reporting GPU.
        return values.max()
    }

    private func readBattery()->HUDBattery? {
        guard let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources=IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description=IOPSGetPowerSourceDescription(info,source)?.takeUnretainedValue() as? [String:Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return HUDBattery(description)
        }
        return nil
    }
}

@MainActor final class StatsHUD:NSObject,ObservableObject {
    @Published private(set) var stats=HUDStats()
    private(set) var isVisible=false
    private(set) var isEnabled=false
    private let reader=HUDStatsReader()
    private var panels:[NSPanel]=[]
    private var timer:Timer?
    // The runtime launches the game with this identity (scripts/game_mode_app.py).
    static func shouldShow(enabled:Bool,bundleIdentifier:String?)->Bool {
        enabled && bundleIdentifier == "org.overwatch2mac.overwatch"
    }

    func setEnabled(_ enabled:Bool) {
        guard enabled != isEnabled else { return }
        isEnabled=enabled
        let center=NSWorkspace.shared.notificationCenter
        if enabled {
            for name in [NSWorkspace.didActivateApplicationNotification,NSWorkspace.didTerminateApplicationNotification,NSWorkspace.activeSpaceDidChangeNotification] {
                center.addObserver(self,selector:#selector(updateVisibility),name:name,object:nil)
            }
        } else { center.removeObserver(self) }
        updateVisibility()
    }

    @objc private func updateVisibility() {
        let app=NSWorkspace.shared.frontmostApplication
        setVisible(Self.shouldShow(enabled:isEnabled,bundleIdentifier:app?.isTerminated == false ? app?.bundleIdentifier : nil))
    }

    func setVisible(_ visible:Bool) {
        guard visible != isVisible else { return }
        isVisible=visible
        timer?.invalidate();timer=nil
        reader.reset()
        if visible {
            stats=reader.read();rebuildPanels()
            NotificationCenter.default.addObserver(self,selector:#selector(rebuildPanels),name:NSApplication.didChangeScreenParametersNotification,object:nil)
            let timer=Timer(timeInterval:2,repeats:true) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return };self.stats=self.reader.read() }
            }
            timer.tolerance=0.25
            RunLoop.main.add(timer,forMode:.common);self.timer=timer
        } else {
            NotificationCenter.default.removeObserver(self,name:NSApplication.didChangeScreenParametersNotification,object:nil)
            panels.forEach { $0.close() };panels=[]
        }
    }

    @objc private func rebuildPanels() {
        panels.forEach { $0.close() };panels=[]
        guard isVisible else { return }
        // One panel per screen: external displays, separate Spaces and fullscreen games.
        for screen in NSScreen.screens {
            let panel=HUDPanel(contentRect:NSRect(x:0,y:0,width:306,height:24),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false;panel.isOpaque=false;panel.backgroundColor = .clear
            panel.hasShadow=false;panel.ignoresMouseEvents=true;panel.hidesOnDeactivate=false
            panel.level = .statusBar
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
            panel.contentView=NSHostingView(rootView:StatsHUDView(hud:self))
            // Below the notch/menu bar, also when a fullscreen Space hides the menu bar.
            let inset=max(24,screen.safeAreaInsets.top)
            panel.setFrameOrigin(NSPoint(x:screen.frame.minX+10,y:screen.frame.maxY-inset-6-24))
            panel.orderFrontRegardless();panels.append(panel)
        }
    }
}

private final class HUDPanel:NSPanel {
    override var canBecomeKey:Bool { false }
    override var canBecomeMain:Bool { false }
}

private struct StatsHUDView:View {
    @ObservedObject var hud:StatsHUD
    var body:some View {
        HStack(spacing:8) {
            metric(L("CPU"),HUDStats.percent(hud.stats.cpu),color:.cyan)
            metric(L("GPU"),HUDStats.percent(hud.stats.gpu),color:.purple)
            HStack(spacing:3) {
                if let battery=hud.stats.battery {
                    HUDBatteryIcon(percent:battery.percent,charging:battery.isCharging)
                } else { Image(systemName:"powerplug.fill").foregroundStyle(.mint) }
                Text(hud.stats.battery.map { HUDStats.percent($0.percent) } ?? L("AC Power"))
            }.accessibilityLabel(hud.stats.battery?.detail ?? L("AC Power"))
            if let time=hud.stats.battery?.time {
                Text(time).foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength:0)
            Text(hud.stats.date,format:.dateTime.hour().minute())
        }
        .font(.system(size:10,weight:.medium,design:.rounded)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(.white)
        .padding(.horizontal,8).frame(width:306,height:24)
        .background(.black.opacity(0.72),in:RoundedRectangle(cornerRadius:6))
        .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(.white.opacity(0.12),lineWidth:0.5))
        .environment(\.colorScheme,.dark)
    }

    private func metric(_ label:String,_ value:String,color:Color)->some View {
        HStack(spacing:3) {
            Text(label).foregroundStyle(color)
            Text(value)
        }
    }
}

private struct HUDBatteryIcon:View {
    let percent:Double?
    let charging:Bool
    private var fraction:Double { min(100,max(0,percent ?? 0))/100 }
    private var color:Color { fraction<=0.1 ? .red : fraction<=0.2 ? .orange : .mint }
    var body:some View {
        HStack(spacing:1) {
            ZStack(alignment:.leading) {
                RoundedRectangle(cornerRadius:1.5).strokeBorder(color,lineWidth:1).frame(width:14,height:8)
                Rectangle().fill(color).frame(width:10*fraction,height:4).padding(.leading,2)
            }.overlay {
                if charging { Image(systemName:"bolt.fill").font(.system(size:8,weight:.black)).foregroundStyle(.white).shadow(color:.black,radius:1) }
            }
            Rectangle().fill(color).frame(width:1,height:3)
        }.accessibilityHidden(true)
    }
}
