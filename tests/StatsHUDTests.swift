import AppKit
import IOKit.ps

@main struct StatsHUDTests {
    @MainActor static func main() {
        func ticks(_ user:UInt32,_ system:UInt32,_ idle:UInt32,_ nice:UInt32)->host_cpu_load_info {
            var info=host_cpu_load_info();info.cpu_ticks=(user,system,idle,nice);return info
        }
        let zero=ticks(0,0,0,0)
        assert(HUDStatsReader.cpuUsage(ticks(20,10,60,10),zero) == 40)
        assert(HUDStatsReader.cpuUsage(zero,zero) == nil)
        assert(HUDStatsReader.cpuUsage(ticks(5,0,10,0),ticks(UInt32.max-4,0,0,0)) == 50)
        assert(HUDStats.percent(nil) == "—")
        assert(HUDStats.percent(.nan) == "—")
        assert(HUDStats.percent(101) == "100%")
        var battery:[String:Any]=[
            kIOPSTypeKey:kIOPSInternalBatteryType,
            kIOPSPowerSourceStateKey:kIOPSBatteryPowerValue,
            kIOPSCurrentCapacityKey:50,kIOPSMaxCapacityKey:100,
            kIOPSTimeToEmptyKey:125,
        ]
        assert(HUDBattery(battery).percent == 50)
        assert(HUDBattery(battery).detail.hasPrefix("≈ "))
        assert(HUDBattery(battery).time?.hasPrefix("≈") == true)
        for minutes in [0,-1] {
            battery[kIOPSTimeToEmptyKey]=minutes
            assert(HUDBattery(battery).detail == L("Estimating…"))
            assert(HUDBattery(battery).time == "…")
        }
        battery[kIOPSMaxCapacityKey]=0
        assert(HUDBattery(battery).percent == nil)
        battery[kIOPSPowerSourceStateKey]=kIOPSACPowerValue
        assert(HUDBattery(battery).detail == L("Plugged in"))
        assert(HUDBattery(battery).time == nil)
        battery[kIOPSIsChargingKey]=true
        assert(HUDBattery(battery).detail == L("Charging"))
        assert(HUDBattery(battery).isCharging)
        battery[kIOPSTimeToFullChargeKey]=45
        assert(HUDBattery(battery).detail.contains("until full"))
        battery[kIOPSIsChargedKey]=true
        assert(HUDBattery(battery).detail == L("Fully charged"))

        let reader=HUDStatsReader()
        assert(reader.read().cpu == nil)
        Thread.sleep(forTimeInterval:0.2)
        let live=reader.read()
        assert(live.cpu.map { (0...100).contains($0) } == true)
        assert(live.gpu.map { (0...100).contains($0) } ?? true)
        reader.reset();assert(reader.read().cpu == nil)
        print("Live readings: CPU \(HUDStats.percent(live.cpu)), GPU \(HUDStats.percent(live.gpu)), battery \(HUDStats.percent(live.battery?.percent)) · \(live.battery?.detail ?? "No battery")")

        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        let hud=StatsHUD()
        assert(StatsHUD.shouldShow(enabled:true,bundleIdentifier:"org.overwatch2mac.overwatch"))
        assert(!StatsHUD.shouldShow(enabled:false,bundleIdentifier:"org.overwatch2mac.overwatch"))
        for identifier in [nil,"org.overwatch2mac.launcher","com.blizzard.BattleNet","org.winehq.wine","com.apple.finder"] as [String?] {
            assert(!StatsHUD.shouldShow(enabled:true,bundleIdentifier:identifier))
        }
        hud.setEnabled(true)
        assert(hud.isEnabled)
        hud.setEnabled(false)
        assert(!hud.isVisible)

        hud.setVisible(true)
        let panels=app.windows.filter { $0 is NSPanel && $0.isVisible }
        assert(panels.count == NSScreen.screens.count)
        assert(panels.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey && !$0.canBecomeMain && $0.collectionBehavior.contains(.fullScreenAuxiliary) })
        hud.setVisible(false)
        assert(!hud.isVisible)
        assert(panels.allSatisfy { !$0.isVisible })
        hud.setVisible(true);hud.setVisible(false)
        print("Stats HUD tests passed")
    }
}
