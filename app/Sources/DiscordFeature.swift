import AppKit

// Puts the Discord card up while Overwatch runs (DiscordPresence.swift sends it).
@MainActor @Observable final class DiscordFeature {
    // Support: defaults write org.overwatch2mac.launcher discordPresence -bool false
    var on=UserDefaults.standard.object(forKey:"discordPresence") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(on,forKey:"discordPresence")
            watchRuns();checkPresence()
            // With Game Mode off, only Recall's process list finds the game.
            if on && card == nil && runningGame == nil && allowed { recall?.lookForGame() }
        }
    }
    @ObservationIgnored private let ipc=DiscordIPC()
    @ObservationIgnored private var recall:(allowed:()->Bool,lookForGame:()->Void)?
    @ObservationIgnored private var statusRead=false
    @ObservationIgnored private var sawSessions=false
    @ObservationIgnored private var card:(pid:pid_t,exit:DispatchSourceProcess)?
    // macOS can list a run's app for a moment after it ends.
    @ObservationIgnored private var ended:pid_t?
    @ObservationIgnored private var wineSeen:Set<pid_t>=[]
    @ObservationIgnored private var runningObservation:NSKeyValueObservation?

    func start(allowed:@escaping ()->Bool,lookForGame:@escaping ()->Void) { recall=(allowed,lookForGame);watchRuns() }
    func statusKnown() { statusRead=true;checkPresence() }
    func sessionSeen(_ processes:[[String:Any]]) {
        sawSessions=true
        let listed=processes.first { $0["kind"] as? String == "game" }.flatMap { ($0["pid"] as? NSNumber)?.int32Value }
        syncPresence(game:runningGame ?? listed.flatMap { $0 == ended || !Self.alive($0) ? nil : $0 })
    }
    var report:[String:Any] {
        ["v":1,"wired":["start":recall != nil,"status":statusRead,"sessions":sawSessions],"power":on ? "on" : "off","allowed":allowed,
         "connected":ipc.connected,"accepted":ipc.accepted,"last_answer":ipc.lastAnswer ?? "none",
         "app_id":DiscordAssets.applicationID == DiscordAssets.standardID ? "default" : "custom"]
    }

    // Discord is blocked in mainland China, and previews never touch it.
    private var allowed:Bool { on && statusRead && recall?.allowed() == true }
    private var runningGame:pid_t? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "org.overwatch2mac.overwatch" }.map(\.processIdentifier).flatMap { $0 == ended ? nil : $0 }
    }
    private func checkPresence() { syncPresence(game:card?.pid ?? runningGame) }
    private func syncPresence(game:pid_t?) {
        guard let game,allowed else { stopPresence();return }
        guard card?.pid != game else { return }
        stopPresence()
        let exit=DispatchSource.makeProcessSource(identifier:game,eventMask:.exit,queue:.main)
        exit.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.gameEnded(game) } }
        exit.resume();card=(game,exit)
        ipc.set(PresenceCard.activity(launched:Self.startTime(of:game) ?? NSRunningApplication(processIdentifier:game)?.launchDate ?? Date()))
        // A process that ended before the watch began never reports.
        if !Self.alive(game) { gameEnded(game) }
    }
    private func stopPresence() {
        guard let card else { return }
        card.exit.cancel();self.card=nil;ipc.stop()
    }
    private func gameEnded(_ pid:pid_t) {
        guard card?.pid == pid else { return }
        ended=pid;stopPresence();runningAppsChanged()
    }
    // Without Game Mode the game is only a Wine process: a new one has Recall look.
    private func runningAppsChanged() {
        let wine=Self.wineApps(),new = !wine.subtracting(wineSeen).isEmpty
        wineSeen=wine
        if let game=runningGame { syncPresence(game:game) } else if new && card == nil && allowed { recall?.lookForGame() }
    }
    private func watchRuns() {
        guard recall != nil,on else { runningObservation=nil;return }
        guard runningObservation == nil else { return }
        wineSeen=Self.wineApps()
        runningObservation=NSWorkspace.shared.observe(\.runningApplications) { [weak self] _,_ in Task { @MainActor in self?.runningAppsChanged() } }
    }
    nonisolated private static func wineApps()->Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.filter { $0.executableURL?.lastPathComponent == "wine" }.map(\.processIdentifier))
    }
    nonisolated private static func alive(_ pid:pid_t)->Bool { kill(pid,0) == 0 || errno != ESRCH }
    // The game's Wine app has no launch date of its own.
    nonisolated private static func startTime(of pid:pid_t)->Date? {
        var info=proc_bsdinfo();let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size) == size else { return nil }
        return Date(timeIntervalSince1970:TimeInterval(info.pbi_start_tvsec)+TimeInterval(info.pbi_start_tvusec)/1e6)
    }
}
