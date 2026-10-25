import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    enum Screen: String, CaseIterable { case welcome, moveApp, checking, battleNet, readyToInstall, preparing, launching, installer, ready, running, driveMissing, failure }
    enum Sheet: String, Identifiable { case settings, help, about, uninstall, update, whatsNew, shaderUpdate, china, korea, changeRegion; var id: String { rawValue } }
    enum UninstallState: Equatable { case idle, working, done(appRemoved: Bool), failed(String) }
    enum UpdateState: Equatable { case idle, checking, upToDate, available(AvailableUpdate), downloading(Double), installing, failed(String) }
    var uninstall: UninstallState = .idle
    var update: UpdateState = .idle
    var updateNotice=""
    // Battle.net starts Overwatch itself when asked (its own launch command).
    static let playEnabled=false
    var automaticUpdates=UserDefaults.standard.object(forKey:"automaticUpdateChecks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticUpdates,forKey:"automaticUpdateChecks") }
    }
    /// Opening the app opens Battle.net too. Off, the player starts it with Open Battle.net.
    var autoOpenBattleNet=UserDefaults.standard.object(forKey:"autoOpenBattleNet") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoOpenBattleNet,forKey:"autoOpenBattleNet") }
    }
    /// Apple's Metal Performance HUD over Overwatch (worker: launch --metal-hud). Battle.net
    /// starts the game with its own environment, so Settings changes it only while
    /// Battle.net is closed (see running).
    var metalHUD=UserDefaults.standard.bool(forKey:"metalHUD") {
        didSet { UserDefaults.standard.set(metalHUD,forKey:"metalHUD") }
    }
    /// Settings › Display: live, click-through system metrics; no game restart required.
    @ObservationIgnored let statsHUD=StatsHUD()
    var systemStatsHUD=UserDefaults.standard.bool(forKey:"systemStatsHUD") {
        didSet {
            UserDefaults.standard.set(systemStatsHUD,forKey:"systemStatsHUD")
            statsHUD.setEnabled(systemStatsHUD)
        }
    }
    /// MetalFX upscaling (worker: launch --metalfx, portable_metalfx.h): Overwatch offers NVIDIA
    /// DLSS in its Video settings, and Recall runs it on Apple's MetalFX. Off by default. Like the
    /// HUD, Battle.net carries it from when it opens.
    var metalFXUpscaling=UserDefaults.standard.bool(forKey:"metalFXUpscaling") {
        didSet { UserDefaults.standard.set(metalFXUpscaling,forKey:"metalFXUpscaling") }
    }
    /// Sharpening after MetalFX (worker: launch --sharpening; the amounts are the contract's).
    /// Off by default; it applies only with upscaling on, and is kept while upscaling is off.
    enum Sharpening:String, CaseIterable { case off, low, high }
    var metalFXSharpening=Sharpening(rawValue:UserDefaults.standard.string(forKey:"metalFXSharpening") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(metalFXSharpening.rawValue,forKey:"metalFXSharpening") }
    }
    /// Settings › Advanced › Logging (LoggingSetting; worker: launch --logging). Off unless the player
    /// turns it on; Battle.net carries it from when it opens, like the HUD. While it's on the home
    /// screen says so (LoggingReminder), and the support report and saved logs say since when.
    var logging=LoggingSetting(rawValue:UserDefaults.standard.string(forKey:"logging") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(logging.rawValue,forKey:"logging")
            if logging == .off { UserDefaults.standard.removeObject(forKey:"loggingSince") }
            else if oldValue == .off { UserDefaults.standard.set(Date(),forKey:"loggingSince") }
        }
    }
    /// Custom's WINEDEBUG text, as Wine reads it (LoggingSetting.normalized); kept while another setting is chosen.
    var loggingCustom=UserDefaults.standard.string(forKey:"loggingCustom") ?? "" {
        didSet { UserDefaults.standard.set(loggingCustom,forKey:"loggingCustom") }
    }
    var loggingSince:Date? { UserDefaults.standard.object(forKey:"loggingSince") as? Date }
    /// What the open Battle.net logs, as its session's record says (portable_logs.h): it keeps the
    /// setting it opened with. Read with the session (syncSession, checkRunning).
    var sessionLogging:LoggingSetting?
    private func readSessionLogging() {
        guard let name=state["log_session"] as? String,!name.contains("/"),
              let data=try? Data(contentsOf:root.appendingPathComponent("logs/sessions/\(name)/session.json")),
              let record=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],record["ended"] == nil else { sessionLogging=nil;return }
        sessionLogging=LoggingSetting(rawValue:record["logging"] as? String ?? "") ?? .off
    }
    /// Save Logs (LogBundle): working, then the file just saved, for its "Saved" line.
    var savingLogs=false
    var savedLogs:(name:String,bytes:Int64)?
    enum Running { case client, game }
    /// What runs now, as Settings last checked; nil when neither Battle.net nor Overwatch does.
    var running: Running?
    /// How far the player has put the first-matches tip away (FirstMatchTip.Hidden). A new key in
    /// 1.5.0: closing the earlier tip ("firstMatchTipDismissed") hid it for good, so players who
    /// did that still see this one (owner, October 19).
    var stutterTipHidden=FirstMatchTip.Hidden(rawValue:UserDefaults.standard.string(forKey:"stutterTipHidden") ?? "") ?? .shown {
        didSet { UserDefaults.standard.set(stutterTipHidden.rawValue,forKey:"stutterTipHidden") }
    }
    /// Shaders Overwatch has used on this Mac, for the first-matches tip (FirstMatchTip): from the
    /// helper's logs (ShaderRecord), then from each launch's and each after-match preparation's
    /// numbers. nil until read, and with nothing learned yet.
    var learnedShaders:Int?
    /// The Korean build of Overwatch is installed: its folder holds Nexon's anti-cheat (worker
    /// status). On Global, the Play screens then suggest the Korea region until dismissed.
    var nexonBuild=false
    var koreanTipDismissed=UserDefaults.standard.bool(forKey:"koreanTipDismissed") {
        didSet { UserDefaults.standard.set(koreanTipDismissed,forKey:"koreanTipDismissed") }
    }
    var showKoreanTip:Bool { nexonBuild && !koreanSupport && !koreanTipDismissed }
    /// Choose your Battle.net (BattleNetChoice.swift), before Battle.net installs: what the screen
    /// shows, filled in from the Mac, and what setup installs. Setup hands it to the worker
    /// (battlenet), which keeps it in state.json from then on.
    var battleNetRegion=BattleNetRegion.suggested
    var battleNetLanguage=BattleNetLanguage.suggested
    /// Continue on Choose your Battle.net this session; with a choice already kept, not needed.
    private var battleNetConfirmed=false
    var needsBattleNetChoice:Bool { !clientInstalled && state["battlenet_region"] == nil && !battleNetConfirmed }
    /// The region the installation is for (BattleNetRegion.kept): installations from before 1.4.1
    /// are Global, or Korea with Korean account support on.
    var installedRegion:BattleNetRegion { BattleNetRegion.kept(state) }
    /// The Battle.net the player is on: as installed, or as chosen while setting up. Help, the
    /// Discord card and the sign-in notes follow it.
    var currentRegion:BattleNetRegion { clientInstalled ? installedRegion : battleNetRegion }
    /// Discord is blocked in mainland China: players on China's Battle.net get GitHub wherever
    /// Recall offers the Discord (GitHubHelpLink; owner, October 15).
    var showsDiscord:Bool { currentRegion != .china }
    /// The 929PJ warm-up is a global-server code; China's servers don't take it (NetEase). Players
    /// on China's Battle.net get the stutter heads-up without it (owner, October 19).
    var offersWorkshopCode:Bool { currentRegion != .china }
    /// China's game folder holds NetEase's anti-cheat (worker status); support reports name it.
    var neacBuild=false
    /// Settings › General › Battle.net region, to or from China's: the installation going to the
    /// Trash, and the region setup then starts again with.
    enum RegionChange: Equatable { case idle, working, failed(String) }
    var regionChange=RegionChange.idle
    var regionTarget=BattleNetRegion.global
    /// Kept by the worker (state.json): automatic proxy detection (Settings › Advanced), off unless
    /// turned on, and Korean account support, which is the Korea region (Settings › General).
    enum AdvancedSetting: String { case proxyAutoDetect="proxy_auto_detect", koreanSupport="korean_support" }
    @ObservationIgnored private var advancedSettingsTask:Task<Void,Never>?
    @ObservationIgnored private var pendingAdvancedSettings=[(AdvancedSetting,Bool)]()
    var proxyAutoDetect:Bool { state[AdvancedSetting.proxyAutoDetect.rawValue] as? Bool == true }
    var koreanSupport:Bool { state[AdvancedSetting.koreanSupport.rawValue] as? Bool == true }
    /// The worker keeps these once setup has installed the game components.
    var canChangeAdvanced:Bool { isPreview || state["active_runtime"] != nil }
    /// The Settings tab shown; Settings reopens on it, as a Mac app's Settings window does.
    var settingsTab=SettingsTab(rawValue:UserDefaults.standard.string(forKey:"settingsTab") ?? "") ?? .general {
        didSet { UserDefaults.standard.set(settingsTab.rawValue,forKey:"settingsTab") }
    }
    /// Recall is preparing what the last match learned (AfterMatch). Checked when the player
    /// comes back to the window, then every few seconds while it lasts (SetupView).
    var preparingAfterMatch=false
    var afterMatchProgress:AfterMatch.Progress?
    /// What's preparing is the one-time shader cache update (Update Now) rather than a match's.
    var updatingShaderCache=false
    /// What else is using the Mac (BusyApps, REC-5): looked at every few seconds while the Play,
    /// opening or running screen is on screen, so the note names what's busy as the player
    /// starts Overwatch. Nothing is checked while this window is hidden, a match included.
    var macLoad=MacLoad()
    var windowVisible=true
    /// Apps the player chose Quit for, until they end.
    var quittingApps:Set<pid_t>=[]
    @ObservationIgnored private var loadChecked:Date?
    var watchesLoad:Bool { !isPreview && clientInstalled && windowVisible && [.ready,.launching,.running].contains(screen) }
    /// Recall itself and everything under its data folders (Wine, Battle.net, Overwatch).
    private var ownPaths:[String] { [Bundle.main.bundlePath,root.standardizedFileURL.path,InstallLocation.standard.standardizedFileURL.path].map { $0.hasSuffix("/") ? $0 : $0+"/" } }
    func watchLoad() async {
        let paths=ownPaths
        var previous=await Task.detached(priority:.utility) { BusyApps.sample() }.value
        // The first answer two seconds in, then over each five seconds: long enough that a
        // video's or a game's use reads steady.
        var interval=2.0
        while watchesLoad && !Task.isCancelled {
            try? await Task.sleep(for:.seconds(interval))
            guard watchesLoad && !Task.isCancelled else { return }
            let first=previous,gameRunning=screen == .running && existingName == "Overwatch"
            let (load,next)=await Task.detached(priority:.utility) { () -> (MacLoad,BusyApps.Sample) in
                let next=BusyApps.sample();return (BusyApps.load(from:first,to:next,excluding:paths,gameRunning:gameRunning),next)
            }.value
            previous=next;interval=5
            macLoad=load;loadChecked=Date()
            quittingApps.formIntersection(load.apps.map(\.pid))
        }
    }
    /// Quit, as Cmd-Q in that app: it can still ask to save. The note updates when it has ended.
    func quitApp(_ app:MacLoad.App) {
        guard let running=NSRunningApplication(processIdentifier:app.pid),running.terminate() else { return }
        quittingApps.insert(app.pid)
    }
    func appEnded(_ pid:pid_t) {
        guard macLoad.apps.contains(where:{ $0.pid == pid }) else { return }
        macLoad.apps.removeAll { $0.pid == pid };quittingApps.remove(pid)
    }
    /// For the Support Report: what was busy as Battle.net or Overwatch was last opened.
    private func recordLaunchLoad() {
        guard !isPreview else { return }
        if let loadChecked,Date().timeIntervalSince(loadChecked) < 10 { Self.saveLaunchLoad(macLoad);return }
        let paths=ownPaths
        Task { Self.saveLaunchLoad(await BusyApps.check(excluding:paths)) }
    }
    private static func saveLaunchLoad(_ load:MacLoad) {
        var record=load.report;record["at"]=ISO8601DateFormatter().string(from:Date())
        UserDefaults.standard.set(try? JSONSerialization.data(withJSONObject:record),forKey:"launchLoad")
    }
    private var launchLoad:[String:Any]? {
        UserDefaults.standard.data(forKey:"launchLoad").flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
    }
    /// Update Now was chosen: its monitor starts within seconds, or once one from before 1.4
    /// has ended (up to three minutes; portable_session.h), and the status shows meanwhile.
    private var shaderUpdateRequested:Date?
    /// The ready screen, or the running screen with only Battle.net open: the match is over.
    var showsAfterMatch:Bool { preparingAfterMatch && (screen == .ready || (screen == .running && existingName != "Overwatch")) }
    func checkAfterMatch() {
        guard !isPreview && clientInstalled else { return }
        let wasPreparing=preparingAfterMatch
        defer {
            // The logs are read once, and again when a preparation ends with its final numbers.
            if let progress=afterMatchProgress { learnedShaders=max(learnedShaders ?? 0,progress.learned) }
            else if learnedShaders == nil || (wasPreparing && !preparingAfterMatch) { readLearnedShaders() }
        }
        let running=AfterMatch.running(root:root)
        if running || shaderUpdateRequested.map({ Date().timeIntervalSince($0) > 240 }) == true { shaderUpdateRequested=nil }
        preparingAfterMatch=running || shaderUpdateRequested != nil
        updatingShaderCache=preparingAfterMatch && (shaderUpdateRequested != nil || AfterMatch.updating(root:root))
        afterMatchProgress=preparingAfterMatch ? AfterMatch.progress(root:root) : nil
    }
    /// After updating to 1.4, once, following What's New: shaders Overwatch has used that aren't
    /// prepared yet get a one-time update now, or after the next match (ShaderUpdateSheet).
    var shaderUpdatePending=0
    /// A click on the main window outside the open pop-up (Main.swift): closes it where Esc
    /// does, the way its own button does, so onDisappear hooks still run. Never during an
    /// update's download or install, or once uninstalling or switching Battle.net has started.
    func closeSheetFromOutside()->Bool {
        guard let open=sheet else { return false }
        switch open {
        case .update:
            if case .downloading=update { return false }
            if update == .installing { return false }
        case .uninstall:
            switch uninstall { case .idle, .failed: uninstall = .idle; default: return false }
        case .changeRegion:
            if regionChange == .working { return false }
            regionChange = .idle
        default: break
        }
        sheet=nil
        return true
    }
    /// Clear Shader Cache keeps the helper's logs, so numbers logged before it are ignored.
    func readLearnedShaders() {
        let logs=["pipeline-preparation.log","pipeline-after-session.log"].compactMap {
            (try? root.appendingPathComponent("logs/\($0)").resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate
        }
        let cleared=UserDefaults.standard.object(forKey:"shadersCleared") as? Date ?? .distantPast
        guard let newest=logs.max(),newest > cleared else { learnedShaders=nil;return }
        let learned=ShaderRecord.read(root:root)["learned"] as? Int
        learnedShaders=learned.flatMap { $0 > 0 ? $0 : nil }
    }
    func whatsNewClosed() {
        guard !isPreview,clientInstalled,UserDefaults.standard.string(forKey:"shaderUpdateOffered") == nil else { return }
        UserDefaults.standard.set(WhatsNew.version,forKey:"shaderUpdateOffered")
        let record=ShaderRecord.read(root:root)
        guard let learned=record["learned"] as? Int,let ready=record["ready"] as? Int,learned > ready,!AfterMatch.running(root:root) else { return }
        shaderUpdatePending=learned-ready
        DispatchQueue.main.async { self.sheet = .shaderUpdate }
    }
    func updateShaderCache() {
        sheet=nil
        guard !isPreview else { return }
        shaderUpdateRequested=Date();checkAfterMatch()
        Task {
            while busy { try? await Task.sleep(for:.milliseconds(200)) }
            busy=true
            defer { busy=false }
            do {
                let gameMode=UserDefaults.standard.object(forKey:"gameMode") as? Bool ?? true
                _ = try await service.run("prepare-shaders",gameMode ? [] : ["--game-mode","0"])
            } catch {
                shaderUpdateRequested=nil;checkAfterMatch()
                notice=(error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message
            }
        }
    }
    /// Settings › Graphics › Shader memory (ShaderMemory): the worker's choice, or the default.
    var shaderMemory:String {
        if let saved=state["shader_memory"] as? String,ShaderMemory.valid(saved) { return saved }
        return ShaderMemory.defaultChoice
    }
    /// The shader cache's parts, read when Settings shows them.
    var shaderPack=[ShaderMemory.Part]()
    func loadShaderPack() {
        guard !isPreview else { return }
        shaderPack=ShaderMemory.parts(root:root)
    }
    func chooseShaderMemory(_ choice:String) {
        guard choice != shaderMemory,ShaderMemory.valid(choice) else { return }
        state["shader_memory"]=choice
        guard !isPreview && state["active_runtime"] != nil else { return }
        Task {
            // Another step (a launch, say) may be using the worker; save right after it.
            while busy { try? await Task.sleep(for:.milliseconds(200)) }
            busy=true
            defer { busy=false }
            do { _ = try await service.run("shader-memory",["--limit",choice]) }
            catch { notice=(error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message }
        }
    }
    /// Settings › Graphics › Clear Shader Cache: how much it frees, measured off the main
    /// thread when the panel shows (nil until then).
    var shaderCacheBytes:Int64?
    func measureShaderCache() {
        guard !isPreview else { return }
        let root=root,runtime=state["active_runtime"] as? String
        Task {
            shaderCacheBytes=await Task.detached(priority:.utility) { ShaderCache.bytes(root:root,runtime:runtime) }.value
        }
    }
    /// Settings › Graphics › Clear Shader Cache (from @dagadtwok's pull request, #37; its
    /// confirmation says what goes): every shader Recall keeps, so each builds again as
    /// Overwatch uses it. Battle.net and Overwatch must be closed.
    func deleteShaders() {
        guard !isPreview else { shaderPack=[];shaderCacheBytes=0;learnedShaders=nil;stutterTipHidden = .shown;notice=L("Shader cache cleared. {0} rebuilds it after your next match.",Brand.name);return }
        Task {
            // Another step (a launch, say) may be using the worker; clear right after it.
            while busy { try? await Task.sleep(for:.milliseconds(200)) }
            busy=true
            defer { busy=false }
            do {
                _ = try await service.run("delete-shaders",[])
                shaderPack=[];shaderCacheBytes=0
                // Overwatch learns its shaders again from nothing: the first-matches tip returns.
                learnedShaders=nil;stutterTipHidden = .shown;UserDefaults.standard.set(Date(),forKey:"shadersCleared")
                notice=L("Shader cache cleared. {0} rebuilds it after your next match.",Brand.name)
            } catch {
                // What the panels show must match what the worker kept.
                loadShaderPack();measureShaderCache()
                notice=(error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message
            }
        }
    }
    /// The Help tab shown, and a topic to open with it (see openHelp).
    var helpTab=HelpTab.questions
    var helpTopic:String?
    /// Help's search, kept here so Esc can clear it before it closes Help (Main.swift).
    var helpQuery=""
    var updatingComponents=false
    private var updateCheck: Task<AvailableUpdate?,Error>?
    private var lastUpdateCheck: Date?
    private var launchDeferredForUpdate=false
    var screen: Screen = .welcome
    var sheet: Sheet?
    var busy=false
    var stage=""
    var failure=SetupFailure(code:"")
    var resolution=DisplayResolution.standard
    var report=""
    var notice=""
    /// Settings › Remember a resolution for each display (the worker's display_memory).
    var rememberEachDisplay=true
    /// Settings shows "Saved" once the chosen resolution is recorded.
    var displaySaved=false
    @ObservationIgnored private var displaySave:Task<Void,Never>?
    var freeBytes: UInt64=0
    var gameInstalled=false
    var clientInstalled=false
    var downloadedBytes: UInt64=0
    var lastEvents=[String]()
    /// "Preparing graphics" for the launching screen's details; starts over with each launch.
    var graphics=GraphicsProgress()
    var release: Release?
    var root: URL
    /// The installed Battle.net program; the worker launches the same file and says where it is.
    var battleNetPath="environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
    var battleNetExecutable:URL { root.appendingPathComponent(battleNetPath) }
    let service: SetupService
    var state=[String:Any]()
    var canCancel=false
    var existingName="Battle.net"
    /// Moving out of the disk image: older copies this replaces, and a copy
    /// already in Applications that is at least as new as this one.
    var moveReplaces=[String]()
    var installedCopy: AppLocation.Copy?
    /// Battle.net has opened at least once; the support card shows from then on.
    var onboarded: Bool { state["onboarding_complete"] as? Bool == true }
    var launchStarted=Date()
    private var stopLaunchWait=false
    /// Set by the launching screen's Cancel: also close the Battle.net this launch opened.
    private var closeOnStop=false
    var isPreview=false
    /// This Mac's macOS ("15.6.1"); a private preview can stand in another with --preview-macos.
    var macOS=UpdateCheck.system
    private var started=false
    private var paused=false
    private let fm=FileManager.default
    var resources: URL { Bundle.main.resourceURL! }
    // Advisory only: a new installation (Overwatch, Battle.net, game components
    // and update room) measures about 85 GB. Setup still proceeds below this;
    // the helper's own step checks stop a write that cannot fit.
    static let recommendedFreeBytes: UInt64=85_000_000_000
    var lowStorage: Bool { !gameInstalled && freeBytes < Self.recommendedFreeBytes }
    // Advisory only: gameplay has been measured on 16 GB. Macs with less
    // memory can still install and play; the player decides.
    static let recommendedMemoryBytes: UInt64=16<<30
    var memoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
    var lowMemory: Bool { memoryBytes < Self.recommendedMemoryBytes }
    // The location can change only while nothing is installed there yet.
    var canChangeLocation: Bool { state["active_runtime"] == nil && !clientInstalled }
    var driveName: String { InstallLocation.driveName(root) }
    private var mountObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    var title: String {
        switch screen {
        case .welcome: return Brand.name
        case .moveApp: return installedCopy == nil ? L("Move {0} to Applications",Brand.name) : L("{0} is already installed",Brand.name)
        case .checking: return L("Checking your Mac")
        case .battleNet: return L("Choose your Battle.net")
        case .readyToInstall: return clientInstalled ? L("Finish setup") : L("Set up Battle.net")
        case .preparing: return repairing ? L("Repairing") : (updatingComponents ? L("Updating {0}",Brand.name) : L("Setting up Overwatch"))
        case .launching: return L("Opening Battle.net")
        case .installer: return L("Finish in Battle.net")
        case .ready: return gameInstalled ? L("Play Overwatch") : L("Install Overwatch")
        case .running: return L("{0} is running",L(existingName))
        case .driveMissing: return L("Connect {0}",driveName)
        case .failure:
            switch failure.code {
            case "cancelled": return L("Setup paused")
            case "insufficient_disk_space": return L("More space needed")
            case "rosetta_required": return L("Install Rosetta")
            case "close_installer_client": return L("Close Battle.net first")
            case "setup_already_running", "app_worker_busy", "pipeline_cache_busy": return L("Another operation is finishing")
            case "download_hash_mismatch", "client_installer_hash_mismatch", "cached_download_hash_mismatch": return L("Download verification failed")
            case "run_from_installed_app", "app_move_failed", "app_name_taken": return L("Move {0} to Applications",Brand.name)
            default: return L("Setup needs attention")
            }
        }
    }
    init() {
        let configuration=try? JSONDecoder().decode(Release.self,from:Data(contentsOf:Bundle.main.url(forResource:"release",withExtension:"json") ?? URL(fileURLWithPath:"/missing")))
        let args=CommandLine.arguments
        let selectedRoot: URL
        if configuration?.distribution == "private-preview",let i=args.firstIndex(of:"--data-root"),args.indices.contains(i+1) {
            selectedRoot=URL(fileURLWithPath:args[i+1]).standardizedFileURL
            UserDefaults.standard.set(selectedRoot.path,forKey:"privatePreviewDataRoot")
        } else if configuration?.distribution == "private-preview",let saved=UserDefaults.standard.string(forKey:"privatePreviewDataRoot") {
            selectedRoot=URL(fileURLWithPath:saved)
        } else if let saved=UserDefaults.standard.string(forKey:InstallLocation.savedKey) {
            selectedRoot=URL(fileURLWithPath:saved)
        } else { selectedRoot=InstallLocation.standard }
        root=selectedRoot
        service=SetupService(root:selectedRoot,helper:Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ow2-setup"))
        release=configuration
    }
    func receive(_ value: [String:Any]) {
        guard let name=value["stage"] as? String else { return }
        if name == "graphics" {
            graphics.update(value)
            if graphics.learned > 0 { learnedShaders=graphics.learned }
            return
        }
        if name == "pipeline_preparation_skipped" { graphics.skipped() }
        // Allowlisted stage names only; never retain arbitrary error detail/paths.
        let labels=["downloading":L("Downloading Battle.net"), "download_verified":L("Download verified"), "installing_runtime":L("Installing game components"), "runtime_ready":L("Game components ready"), "preparing_environment":L("Preparing your game environment"), "environment_ready":L("Game environment ready"), "installing_battlenet":L("Opening the Battle.net installer"), "preparing_pipelines":L("Preparing graphics"), "battlenet_started":L("Opening Battle.net"), "pipeline_preparation_skipped":L("Opening Battle.net"), "closing_client":L("Closing Battle.net"), "displays_changed":L("Reopening Battle.net for your displays"), "waiting_for_setup":L("Waiting for another operation to finish")]
        if let label=labels[name] { stage=label; lastEvents.append(name); lastEvents=Array(lastEvents.suffix(12)) }
    }
    func refresh() async throws {
        let values=try await service.run("status")
        guard let status=values.last else { throw SetupFailure(code:"status_unavailable") }
        state=status["state"] as? [String:Any] ?? [:]
        clientInstalled=status["battlenet_installed"] as? Bool ?? false
        gameInstalled=status["game_installed"] as? Bool ?? false
        nexonBuild=status["nexon_build"] as? Bool ?? false
        neacBuild=status["neac_build"] as? Bool ?? false
        if let path=status["battlenet_path"] as? String,path.hasPrefix("environment/drive_c/") { battleNetPath=path }
        // A choice the worker keeps is the one setup goes on with, unless the player changed it
        // on Choose your Battle.net this session (setup then hands the worker the new one).
        if !battleNetConfirmed {
            if clientInstalled || state["battlenet_region"] != nil { battleNetRegion=installedRegion }
            if let language=(state["battlenet_language"] as? String).flatMap(BattleNetLanguage.init) { battleNetLanguage=language }
        }
        freeBytes=(status["free_bytes"] as? NSNumber)?.uint64Value ?? 0
        // Match Finder's "available" figure, which includes purgeable storage.
        if let available=try? root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,available>0 {
            freeBytes=max(freeBytes,UInt64(available))
        }
        // The resolution Overwatch opens at next: the last one chosen, here or in the game.
        if let next=status["display_next"] as? [String:Any],let width=next["width"] as? Int,let height=next["height"] as? Int {
            resolution=DisplayResolution(width:width,height:height)
            rememberEachDisplay=next["per_display"] as? Bool ?? true
        } else {
            // Installations from before 1.0 saved only a height, 1920 pixels wide.
            let saved=DisplayResolution(width:state["display_width"] as? Int ?? 1920,height:state["display_height"] as? Int ?? 1200)
            resolution=saved.isSupported ? saved : .standard
        }
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isPreview else { return }
        guard !busy && advancedSettingsTask == nil else { return }; busy=true; notice=""; paused=false
        Task {
            defer { busy=false;canCancel=false;downloadedBytes=0 }
            do { try await action() }
            catch {
                failure=paused ? SetupFailure(code:"cancelled") : (error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error"))
                screen = failure.code == "install_location_unavailable" ? .driveMissing : .failure
                if sheet != nil { notice=failure.message }
            }
        }
    }
    func startup() {
        guard !started else { return };started=true
        // Preview states exercise UI only and never create a user environment.
        if release?.distribution == "private-preview",let i=CommandLine.arguments.firstIndex(of:"--preview-state"),CommandLine.arguments.indices.contains(i+1),let preview=Screen(rawValue:CommandLine.arguments[i+1]) {
            isPreview=true;previewScreen(preview);return
        }
        // Plugging the drive back in retries without another click.
        mountObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didMountNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in if self?.screen == .driveMissing { self?.recheck() } }
        }
        // An app the busy note names has quit (its Quit button, or the player elsewhere).
        quitObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didTerminateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            guard let pid=(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor in self?.appEnded(pid) }
        }
        // Opened from the disk image: move to Applications before anything else.
        if AppLocation.needsMove(Bundle.main.bundleURL) { prepareMove();return }
        statsHUD.setEnabled(systemStatsHUD)
        if automaticUpdates { checkForUpdates(manual:false) }
        screen = .checking
        perform {
            guard self.release != nil else { throw SetupFailure(code:"release_unavailable") }
            let retired=self.retireOlderCopies()
            try await self.route(autoLaunch:true)
            if let old=retired.first,self.notice.isEmpty {
                self.notice=L("The old {0} app is in the Trash now. {1} replaces it; your game and sign-in are kept.",old.url.deletingPathExtension().lastPathComponent,Brand.name)
            }
        }
    }
    /// An installed copy retires older copies of itself in the Applications
    /// folders, such as the app under its former name (to the Trash).
    private func retireOlderCopies() -> [AppLocation.Copy] {
        let bundle=Bundle.main.bundleURL
        guard AppLocation.isInstalled(bundle),let identifier=Bundle.main.bundleIdentifier else { return [] }
        return AppLocation.retire(AppLocation.olderCopies(identifier:identifier,version:UpdateCheck.installed,build:UpdateCheck.build,keeping:bundle))
    }
    private func prepareMove() {
        let identifier=Bundle.main.bundleIdentifier ?? ""
        let target=try? AppLocation.destination(identifier:identifier,create:false)
        installedCopy=target.flatMap { AppLocation.copy(at:$0) }.flatMap { found in
            found.identifier == identifier && !AppLocation.isOlder(found.copy,than:UpdateCheck.installed,build:UpdateCheck.build) ? found.copy : nil
        }
        moveReplaces=AppLocation.olderCopies(identifier:identifier,version:UpdateCheck.installed,build:UpdateCheck.build,keeping:target ?? Bundle.main.bundleURL)
            .map { $0.url.deletingPathExtension().lastPathComponent }
        screen = .moveApp
    }
    /// True when nothing is running, so quitting needs no confirmation.
    var quitsNow:Bool { isPreview || !busy }
    /// Quits the app, from the menu or from outside (AppDelegate.quitEvent). AppKit
    /// ignores a quit while a sheet is attached to the window, so when nothing is
    /// running, close the sheet first and quit once it has gone.
    func quit() {
        guard sheet != nil,quitsNow else { NSApp.terminate(nil);return }
        sheet=nil
        Task {
            var waits=0
            while waits<40 && NSApp.windows.contains(where:{ $0.attachedSheet != nil }) { try? await Task.sleep(for:.milliseconds(50));waits+=1 }
            NSApp.terminate(nil)
        }
    }
    /// Copies this app into Applications (verified like an update), moves older
    /// copies to the Trash, then reopens it from there and ejects the disk image.
    func moveToApplications() {
        perform {
            let bundle=Bundle.main.bundleURL
            guard let team=UpdateInstaller.team(of:bundle),let identifier=Bundle.main.bundleIdentifier else { throw SetupFailure(code:"run_from_installed_app") }
            self.stage=L("Copying {0} to Applications",Brand.name)
            let target=try AppLocation.destination(identifier:identifier)
            try await AppLocation.install(bundle,at:target,team:team,identifier:identifier,version:UpdateCheck.installed)
            _ = AppLocation.retire(AppLocation.olderCopies(identifier:identifier,version:UpdateCheck.installed,build:UpdateCheck.build,keeping:target))
            let volume=await AppLocation.diskImageVolume(containing:AppLocation.original(of:bundle))
            UpdateInstaller.relaunch(target,ejecting:volume)
            self.busy=false
            self.quit()
        }
    }
    /// A copy at least as new is already installed: open it instead.
    func openInstalledCopy() {
        guard let copy=installedCopy else { return }
        perform {
            let volume=await AppLocation.diskImageVolume(containing:AppLocation.original(of:Bundle.main.bundleURL))
            UpdateInstaller.relaunch(copy.url,ejecting:volume)
            self.busy=false
            self.quit()
        }
    }
    private func route(autoLaunch:Bool) async throws {
        guard InstallLocation.isAvailable(root) else { screen = .driveMissing;return }
        try await refresh()
        let updated=isNewVersion(existing:clientInstalled || state["onboarding_complete"] as? Bool == true)
        if !updated { markVersionSeen() }
        if clientInstalled && state["active_runtime"] != nil && state["prepared_runtime"] as? String != release?.runtimeVersion {
            // A new app version brings new game components. The player chose
            // the update, so they install now; game data and sign-in are kept.
            updatingComponents=true
            defer { updatingComponents=false }
            try await setupSteps()
            if updated { markVersionSeen();sheet = .whatsNew }
        } else if clientInstalled && state["prepared_runtime"] as? String == release?.runtimeVersion {
            screen = .ready
            if updated { markVersionSeen();sheet = .whatsNew;return }
            guard autoLaunch && autoOpenBattleNet && state["onboarding_complete"] as? Bool == true else { return }
            if let found=await pendingUpdate() {
                update = .available(found);launchDeferredForUpdate=true;sheet = .update;return
            }
            try await openClient()
        } else if state["active_runtime"] != nil { screen = needsBattleNetChoice ? .battleNet : .readyToInstall }
        else { screen = .welcome }
    }
    /// True until What's New for this version was shown on an installation an
    /// earlier version set up (an update that fails first shows it after retry).
    private func isNewVersion(existing:Bool) -> Bool {
        let previous=UserDefaults.standard.string(forKey:"lastLaunchedVersion")
        return previous != UpdateCheck.installed && (previous != nil || existing)
    }
    private func markVersionSeen() { UserDefaults.standard.set(UpdateCheck.installed,forKey:"lastLaunchedVersion") }
    /// The startup check's result when it arrives within a few seconds; a slow
    /// or missing network never delays play.
    private func pendingUpdate() async -> AvailableUpdate? {
        guard let check=updateCheck else { return nil }
        return await withTaskGroup(of:AvailableUpdate?.self) { group in
            group.addTask { try? await check.value }
            group.addTask { try? await Task.sleep(for:.seconds(3));return nil }
            let first=await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    private var updateFeed: URL {
        let args=CommandLine.arguments
        if release?.distribution == "private-preview",let i=args.firstIndex(of:"--update-feed"),args.indices.contains(i+1),let url=URL(string:args[i+1]) { return url }
        return UpdateCheck.feed
    }
    /// Automatic checks run at launch and, while the app stays open, at most
    /// every 12 hours. A manual check shows its result in the update sheet.
    func checkForUpdates(manual:Bool, present:Bool=true) {
        guard !isPreview else { return }
        switch update { case .checking, .downloading, .installing: if manual && present { sheet = .update };return; default: break }
        update = .checking;updateNotice="";lastUpdateCheck=Date()
        if manual && present { sheet = .update }
        let task=Task { try await UpdateCheck.latest(from:updateFeed) }
        updateCheck=task
        Task {
            do { update=try await task.value.map { UpdateState.available($0) } ?? .upToDate }
            catch { update = manual ? .failed(L("The update check couldn’t reach GitHub. Check your internet connection, then try again.")) : .idle }
        }
    }
    func checkIfDue() {
        guard automaticUpdates,!isPreview,screen != .moveApp,lastUpdateCheck.map({ Date().timeIntervalSince($0)>12*3600 }) ?? true else { return }
        checkForUpdates(manual:false)
    }
    private var installTask: Task<Void,Never>?
    func installUpdate() {
        guard case .available(let item)=update,!busy else { return }
        guard let team=UpdateInstaller.team(of:Bundle.main.bundleURL),let identifier=Bundle.main.bundleIdentifier else {
            NSWorkspace.shared.open(item.page);return   // Builds without a Developer ID signature update by hand.
        }
        busy=true;updateNotice=""
        installTask=Task {
            defer { busy=false;installTask=nil }
            do {
                // The player quits Overwatch; Battle.net is closed for them.
                if clientInstalled {
                    let processes=try await service.run("session").last?["processes"] as? [[String:Any]] ?? []
                    if processes.contains(where:{ $0["kind"] as? String == "game" }) { throw SetupFailure(code:"close_game_before_update") }
                    if !processes.isEmpty { _ = try await service.run("close-client",event:receive) }
                }
                update = .downloading(0)
                let work=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("org.overwatch2mac.launcher/update")
                try await UpdateInstaller.install(item,over:Bundle.main.bundleURL,team:team,identifier:identifier,work:work) { fraction in
                    Task { @MainActor in if case .downloading=self.update { self.update = .downloading(fraction) } }
                }
                update = .installing
                UpdateInstaller.relaunch(Bundle.main.bundleURL)
                busy=false
                quit()
            } catch {
                update = .available(item)
                if !Task.isCancelled { updateNotice=Self.updateMessage((error as? SetupFailure)?.code ?? "") }
            }
        }
    }
    func cancelUpdateDownload() { if case .downloading=update { installTask?.cancel() } }
    /// Closing the update sheet with Later continues the launch it paused.
    func updateSheetClosed() {
        guard launchDeferredForUpdate else { return }
        launchDeferredForUpdate=false
        if case .available=update, !busy { launch() }
    }
    static func updateMessage(_ code:String) -> String {
        switch code {
        case "close_game_before_update": return L("Quit Overwatch first, then choose Update Now.")
        case "client_close_failed": return L("Battle.net couldn’t be closed. Quit it from the Dock, then try again.")
        case "update_location_read_only": return L("This copy of the app is in a folder you can’t change. Download the update from the release page instead.")
        case "update_signature_invalid": return L("The download couldn’t be verified as an official release, so nothing was changed.")
        case "update_needs_newer_macos": return L("This update needs a newer version of macOS, so nothing was changed.")
        case "update_hash_mismatch", "update_download_failed": return L("The download didn’t complete correctly. Nothing was changed. Try again.")
        default: return L("The update couldn’t be installed. Nothing was changed. You can try again or download it from the release page.")
        }
    }
    func recheck() {
        perform { self.screen = .checking;try await self.route(autoLaunch:false) }
    }
    private func setRoot(_ value:URL) {
        root=value;service.root=value
        UserDefaults.standard.removeObject(forKey:"privatePreviewDataRoot")
        if InstallLocation.isStandard(value) { UserDefaults.standard.removeObject(forKey:InstallLocation.savedKey) }
        else { UserDefaults.standard.set(value.path,forKey:InstallLocation.savedKey) }
    }
    /// Point setup at another folder before anything is installed. The previous
    /// folder is removed only if it holds nothing but empty setup scaffolding.
    func useLocation(_ value:URL) {
        guard !isPreview,canChangeLocation,value.standardizedFileURL.path != root.standardizedFileURL.path else { return }
        if let problem=InstallLocation.problem(for:value) { notice=problem;return }
        perform {
            let previous=self.root
            if InstallLocation.isAvailable(previous) { _ = try? await self.service.run("discard-unused") }
            self.setRoot(value)
            do { try await self.refresh() }
            catch {
                // The helper enforces the same drive rules; keep the old choice.
                self.setRoot(previous)
                try await self.refresh()
                self.notice=(error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message
                return
            }
            // A reconnected installation continues from where it was.
            if !self.canChangeLocation { try await self.route(autoLaunch:false) }
        }
    }
    func chooseOtherLocation() {
        let panel=NSOpenPanel()
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false
        panel.title=L("Choose Install Location");panel.prompt=L("Choose")
        panel.message=L("Choose a drive or folder. Overwatch, Battle.net and their files go in an “{0}” folder inside it.",InstallLocation.folderName)
        panel.directoryURL=URL(fileURLWithPath:"/Volumes")
        if panel.runModal() == .OK,let folder=panel.url { useLocation(InstallLocation.root(forChosen:folder)) }
    }
    /// Stop waiting for a disconnected drive. Nothing on it is changed; choosing
    /// its Overwatch2Mac folder later reconnects that installation.
    func useThisMac() {
        setRoot(InstallLocation.standard);notice="";recheck()
    }
    func previewScreen(_ value:Screen) {
        guard isPreview else { return }
        screen=value;sheet=nil;notice="";clientInstalled=true;gameInstalled=true
        busy=[.checking,.preparing,.launching].contains(value);canCancel=[.preparing,.launching].contains(value)
        launchStarted=Date();stage=value == .launching ? L("Waiting for the Battle.net window") : L("Preparing your game environment")
        failure=SetupFailure(code:"insufficient_disk_space")
        // Setup screens show the location dropdown as for a new installation.
        if value == .readyToInstall { clientInstalled=false;gameInstalled=false;freeBytes=412_000_000_000 }
        update = .upToDate
        state["onboarding_complete"]=value != .welcome && value != .readyToInstall && value != .installer
        if value == .moveApp { moveReplaces=["Overwatch 2 Mac"] }
        let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--preview-macos"),args.indices.contains(i+1) { macOS=args[i+1] }
        if args.contains("--preview-korean") { nexonBuild=true;state["korean_support"]=false }
        // The first-matches tip at a number of learned shaders (FirstMatchTip).
        if let i=args.firstIndex(of:"--preview-learned"),args.indices.contains(i+1),let learned=Int(args[i+1]) { learnedShaders=learned > 0 ? learned : nil }
        if let i=args.firstIndex(of:"--preview-tip"),args.indices.contains(i+1),let hidden=FirstMatchTip.Hidden(rawValue:args[i+1]) { stutterTipHidden=hidden }
        // Choose your Battle.net with a region selected, and Settings' region as installed.
        if let i=args.firstIndex(of:"--preview-region"),args.indices.contains(i+1),let region=BattleNetRegion(rawValue:args[i+1]) {
            battleNetRegion=region;battleNetLanguage=region.suggestedLanguage
            state["battlenet_region"]=region.battleNet;state["korean_support"]=region == .korea
        }
        if value == .battleNet { clientInstalled=false;gameInstalled=false }
        preparingAfterMatch=args.contains("--preview-after-match") || args.contains("--preview-shader-update")
        updatingShaderCache=args.contains("--preview-shader-update")
        afterMatchProgress=preparingAfterMatch ? AfterMatch.Progress(ready:3072,learned:17767) : nil
        // The busy note (REC-5): Chrome and Steam busy, Low Power Mode, a hot Mac, low memory with
        // Visual Studio Code and Safari to quit, or with nothing to quit (a restart).
        macLoad=MacLoad()
        if args.contains("--preview-busy") {
            let app={ (path:String,cpu:Double,gpu:Double,memory:UInt64,reasons:[BusyApps.Reason]) in
                MacLoad.App(pid:-1-Int32(path.count),name:FileManager.default.displayName(atPath:path).replacingOccurrences(of:".app",with:""),path:path,bundleID:nil,cpu:cpu,gpu:gpu,memory:memory,reasons:reasons)
            }
            macLoad.apps=[app("/Applications/Google Chrome.app",180,24,3_400_000_000,[.graphics,.processor]),app("/Applications/Steam.app",12,0,2_100_000_000,[.memory])]
        }
        macLoad.lowPowerMode=args.contains("--preview-low-power");if args.contains("--preview-hot") { macLoad.thermal="serious" }
        if args.contains("--preview-low-memory-apps") {
            macLoad.lowMemory=true
            macLoad.apps=[("/Applications/Visual Studio Code.app",4_400_000_000 as UInt64),("/Applications/Safari.app",1_700_000_000)].map { path,memory in
                MacLoad.App(pid:-1-Int32(path.count),name:FileManager.default.displayName(atPath:path).replacingOccurrences(of:".app",with:""),path:path,bundleID:nil,cpu:0,gpu:0,memory:memory,reasons:[.memory])
            }
        }
        if args.contains("--preview-low-memory") { macLoad.lowMemory=true;macLoad.restart=true }
        // Settings › Graphics › Shader memory with the owner's pack of 2026-10-14.
        shaderUpdatePending=16911
        shaderPack=[121822128,172324720,179897488,202437120,196611296,166780256,162372016,89495856,166106304,139503200,32750624].enumerated()
            .map { ShaderMemory.Part(bytes:Int64($0.element),shaders:[856,1171,1257,1870,2048,2048,2048,2048,2048,2048,455][$0.offset]) }
        // Clear Shader Cache with the owner's caches of 2026-10-17 (pipelines, translated shaders, macOS's).
        shaderCacheBytes=5_300_000_000
        // The launching screen's "Preparing graphics" details: preparing, done, first,
        // or the warm-up after an update (warming, warmed).
        if value == .launching,let i=args.firstIndex(of:"--preview-graphics"),args.indices.contains(i+1) { previewGraphics(args[i+1]) }
        if let i=args.firstIndex(of:"--preview-sheet"),args.indices.contains(i+1),let preview=Sheet(rawValue:args[i+1]) {
            if preview == .update {
                update = .available(AvailableUpdate(version:"1.0.1",notes:[L("Fixes an issue that could stop Battle.net from opening after a Blizzard update."),L("Smoother first matches after installing.")],page:Brand.releases,download:Brand.releases,size:242_000_000,sha256:"",checksum:nil))
            }
            DispatchQueue.main.async { self.sheet=preview }
        }
    }
    private func previewGraphics(_ kind:String) {
        stage=L("Preparing graphics");graphics=GraphicsProgress()
        if kind == "first" { graphics.update(["phase":"done","learned":0,"ready":0,"added":0]);return }
        // A launch since 1.3.1: the numbers, with what the last match's preparation added
        // (ready), or before any preparation has finished (unprepared).
        if kind == "ready" || kind == "unprepared" {
            let ready=kind == "ready" ? 856 : 0
            graphics.update(["phase":"learned","learned":kind == "ready" ? 17767 : 7941,"ready":ready])
            graphics.update(["phase":"done","ready":ready,"added":kind == "ready" ? 48 : 0,"warmed":0]);stage=L("Opening Battle.net");return
        }
        graphics.update(["phase":"learned","learned":8168,"ready":1154])
        if kind == "warming" || kind == "warmed" {
            var generator=SystemRandomNumberGenerator()
            graphics.update(["phase":"warming","target":8168])
            let items:[[Any]]=(0..<(kind == "warmed" ? 8168 : 3420)).map { _ in
                [String(format:"%012llx",UInt64.random(in:0...0xffffffffffff,using:&generator)),Double.random(in:12...140),false]
            }
            graphics.update(["phase":"pipelines","items":items])
            if kind == "warmed" { graphics.update(["phase":"done","ready":1154,"added":0,"warmed":8168]);stage=L("Opening Battle.net") }
            return
        }
        graphics.update(["phase":"preparing","target":1192])
        var generator=SystemRandomNumberGenerator()
        let items:[[Any]]=(0..<(kind == "done" ? 1192 : 412)).map { i in
            [String(format:"%012llx",UInt64.random(in:0...0xffffffffffff,using:&generator)),i < 1154 ? Double.random(in:0.4...3) : Double.random(in:18...140),i >= 1154]
        }
        graphics.update(["phase":"pipelines","items":items])
        if kind == "done" { graphics.update(["phase":"done","ready":1192,"added":38]);stage=L("Opening Battle.net") }
    }
    func installRosetta() {
        guard !isPreview else { return }
        // Running an x86_64 app through LaunchServices asks macOS to present its
        // own Rosetta flow. No silent license agreement or password collection.
        let url=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Rosetta Check.app")
        NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) { _,_ in }
    }
    func check() {
        perform {
            self.screen = .checking
            _ = try await self.service.run("preflight")
            try await self.refresh()
            self.screen = self.needsBattleNetChoice ? .battleNet : .readyToInstall
        }
    }
    /// Choose your Battle.net's Continue. China's Battle.net first explains NetEase's sign-in and
    /// anti-cheat (ChinaBattleNetSheet), Korea what Recall changes for Nexon's (KoreanSupportSheet);
    /// their Continue confirms.
    func chooseBattleNet() {
        switch battleNetRegion {
        case .china: battleNetLanguage = .simplifiedChinese;sheet = .china
        case .korea: sheet = .korea
        case .global: confirmBattleNet()
        }
    }
    func confirmBattleNet() { battleNetConfirmed=true;screen = .readyToInstall }
    /// Set up Battle.net's Change: back to the choice, as it stands.
    func editBattleNet() { guard !busy else { return };notice="";screen = .battleNet }
    /// Settings › General › Battle.net region, apart from Global to Korea, which asks first
    /// (KoreanSupportSheet). Between Global and Korea only Korean account support changes.
    /// Accounts don't carry over between China's Battle.net and Global's, so changing to or from
    /// China asks (ChangeRegionSheet) before changeRegion sets up again.
    func chooseRegion(_ next:BattleNetRegion) {
        guard next != installedRegion else { return }
        if next == .china || installedRegion == .china { regionTarget=next;regionChange = .idle;sheet = .changeRegion }
        else { setAdvanced(.koreanSupport,next == .korea) }
    }
    /// The installation moves to the Trash (the worker's uninstall, which closes Battle.net and
    /// refuses while Overwatch runs), and setup starts again at Choose your Battle.net with
    /// regionTarget. Recall itself and its settings stay.
    func changeRegion() {
        let next=regionTarget
        guard !isPreview else { sheet=nil;battleNetRegion=next;battleNetLanguage=next.suggestedLanguage;screen = .battleNet;return }
        regionChange = .working
        Task {
            // A launch wait is cancellable; let any other step finish first.
            while busy { cancel(); try? await Task.sleep(for:.milliseconds(100)) }
            busy=true; notice=""
            defer { busy=false }
            do { _ = try await service.run("uninstall",event:receive) }
            catch { regionChange = .failed((error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message);return }
            clientInstalled=false;gameInstalled=false;nexonBuild=false;neacBuild=false;state=[:];running=nil
            battleNetRegion=next;battleNetLanguage=next.suggestedLanguage
            battleNetConfirmed=false;sheet=nil;screen = .battleNet
            regionChange = .idle
        }
    }
    func setup() { perform { try await self.setupSteps() } }
    private func setupSteps() async throws {
        guard let release else { throw SetupFailure(code:"release_unavailable") }
        _ = try await service.run("preflight")
        try await refresh()
        if !clientInstalled {
            // Battle.net installs as chosen on Choose your Battle.net; the worker keeps the
            // choice, and prepare adds the fonts it needs.
            if needsBattleNetChoice { screen = .battleNet;return }
            if battleNetConfirmed {
                _ = try await service.run("battlenet",["--region",battleNetRegion.battleNet,"--language",battleNetLanguage.rawValue])
                // Korea is Global's Battle.net with Korean account support, which prepare applies.
                if koreanSupport != (battleNetRegion == .korea) {
                    _ = try await service.run("korean-support",["--enabled",battleNetRegion == .korea ? "1" : "0"])
                }
                try await refresh()
            }
        }
        screen = .preparing;canCancel=true
        if state["active_runtime"] as? String != release.runtimeVersion {
            _ = try await service.run("install-runtime",["--archive",resources.appendingPathComponent(release.runtimeArchive).path,"--sha256",release.runtimeSHA256,"--version",release.runtimeVersion],event:receive)
        } else { _ = try await service.run("verify") }
        if paused { throw SetupFailure(code:"cancelled") }
        if state["prepared_runtime"] as? String != release.runtimeVersion {
            _ = try await service.run("prepare",event:receive)
        }
        if paused { throw SetupFailure(code:"cancelled") }
        try await refresh()
        if state["display_height"] == nil {
            // A first installation starts in the main display's shape, at 1080p.
            let initial=DisplayResolution.initial(for:MainDisplay.current)
            _ = try await service.run("display",["--width",String(initial.width),"--height",String(initial.height)])
        }
        if clientInstalled { screen = .ready;return }
        // China's Battle.net has its own installer (Blizzard's China download server).
        let china=battleNetRegion == .china
        let installerURL=china ? release.chinaInstallerURL : release.installerURL
        let installerSHA256=china ? release.chinaInstallerSHA256 : release.installerSHA256
        stage=L("Downloading Battle.net")
        let progress=Task { @MainActor in
            while !Task.isCancelled {
                let file=self.root.appendingPathComponent("downloads/"+installerSHA256+".part")
                self.downloadedBytes=(try? self.fm.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.uint64Value ?? 0
                try? await Task.sleep(for:.seconds(0.5))
            }
        }
        defer { progress.cancel() }
        _ = try await service.run("download",["--url",installerURL,"--sha256",installerSHA256],event:receive)
        if paused { throw SetupFailure(code:"cancelled") }
        canCancel=false
        _ = try await service.run("install-battlenet",["--installer",root.appendingPathComponent("downloads/"+installerSHA256).path,"--sha256",installerSHA256],event:receive)
        screen = .installer
    }
    /// Closes Overwatch and Battle.net at once (wineserver -k), for a game that
    /// stopped responding. The player confirms first.
    func forceQuit() {
        perform {
            _ = try await self.service.run("stop")
            self.screen = .ready
            self.notice=L("Overwatch and Battle.net were closed.")
        }
    }
    /// Reinstalls the game components from this app and refreshes the Windows
    /// environment. Overwatch, its settings and the Battle.net sign-in are kept.
    func repair() {
        perform {
            guard let release=self.release else { throw SetupFailure(code:"release_unavailable") }
            let processes=try await self.service.run("session").last?["processes"] as? [[String:Any]] ?? []
            guard processes.isEmpty else { throw SetupFailure(code:"close_game_before_maintenance") }
            self.sheet=nil;self.repairing=true;self.screen = .preparing
            defer { self.repairing=false }
            _ = try await self.service.run("install-runtime",["--archive",self.resources.appendingPathComponent(release.runtimeArchive).path,"--sha256",release.runtimeSHA256,"--version",release.runtimeVersion,"--repair","1"],event:self.receive)
            _ = try await self.service.run("prepare",event:self.receive)
            try await self.refresh()
            self.screen = .ready
            self.notice=L("Repair finished. Overwatch, its settings and your Battle.net sign-in were kept.")
        }
    }
    var repairing=false
    func finishInstaller() {
        perform {
            try await self.refresh()
            guard self.clientInstalled else { throw SetupFailure(code:"battlenet_not_installed") }
            // The installer may open CEF without the required renderer flags.
            // User explicitly closes that window; normal launch never kills it.
            let sessions=try await self.service.run("session")
            if let processes=sessions.last?["processes"] as? [[String:Any]],!processes.isEmpty { throw SetupFailure(code:"close_installer_client") }
            self.screen = .ready
        }
    }
    func openClient(play:Bool=false) async throws {
        screen = .launching
        recordLaunchLoad()
        // Once, before Battle.net opens: Overwatch's voice chat uses this app's permission.
        if Microphone.undecided { stage=L("Asking to use your microphone for voice chat");await Microphone.ask() }
        stage=L("Checking your running session");graphics=GraphicsProgress()
        launchStarted=Date();stopLaunchWait=false;closeOnStop=false;canCancel=true
        // Cancelling here ends the worker, and with it the graphics preparation, before
        // Battle.net opens (the preparation keeps its finished work; the next launch resumes).
        let launchEvents:[[String:Any]]
        do {
            // macOS Game Mode is on unless support turned it off for a player:
            // defaults write org.overwatch2mac.launcher gameMode -bool false
            let gameMode=UserDefaults.standard.object(forKey:"gameMode") as? Bool ?? true
            launchEvents=try await service.run("launch",(play ? ["--play","1"] : [])+["--metal-hud",metalHUD ? "1" : "0",
                "--metalfx",metalFXUpscaling ? "1" : "0","--sharpening",metalFXSharpening.rawValue]+(gameMode ? [] : ["--game-mode","0"]) +
                logging.launchArguments(custom:loggingCustom),event:receive)
        } catch {
            guard stopLaunchWait else { throw error }
            canCancel=false;screen = .ready;notice=L("Cancelled. Battle.net wasn’t opened.")
            return
        }
        // A Cancel that arrived as Battle.net was starting.
        if stopLaunchWait { try await stopLaunch(launchEvents);return }
        // The new Battle.net's record says what it logs (LoggingReminder).
        if let session=launchEvents.last(where:{ $0["stage"] as? String == "battlenet_open" })?["session"] as? String { state["log_session"]=session }
        readSessionLogging()
        // The chosen resolution is larger than this main display allows (see MainDisplay.fits).
        if let fitted=launchEvents.last(where:{ $0["stage"] as? String == "display_fitted" }),
           let width=fitted["width"] as? Int,let height=fitted["height"] as? Int {
            let chosen=(fitted["chosen_width"] as? Int).flatMap { w in (fitted["chosen_height"] as? Int).map { DisplayResolution(width:w,height:$0) } } ?? resolution
            notice=L("Your main display is too small for {0}, so Overwatch uses {1} this time.",chosen.label,DisplayResolution(width:width,height:height).label)
        }
        // Battle.net was open from before a display was connected, unplugged or rearranged.
        if launchEvents.contains(where:{ $0["stage"] as? String == "displays_changed" }) {
            notice=L("Your displays changed since Battle.net opened, so {0} reopened it.",Brand.name)
        }
        canCancel=false
        _ = try await service.run("onboarded")
        state["onboarding_complete"]=true
        stage=L("Waiting for the Battle.net window");canCancel=true
        let result: LaunchReadiness.Result
        do {
            result=try await LaunchReadiness.wait(launchEvents:launchEvents,stopped:{ self.stopLaunchWait },session:{
                let events=try await self.service.run("session")
                return events.last?["processes"] as? [[String:Any]] ?? []
            })
        } catch {
            if !stopLaunchWait { throw error }
            result = .stopped
        }
        canCancel=false
        if result == .stopped { try await stopLaunch(launchEvents);return }
        screen = .ready
        // The launcher stays open behind Battle.net on the running screen so
        // Settings, Help and About remain one click away. It never hides itself.
        switch result {
        case .existing(let name):
            existingName=name;screen = .running
            // One immediate check, never the 90-second fresh-launch wait.
            let sessions=try await service.run("session")
            let processes=sessions.last?["processes"] as? [[String:Any]] ?? []
            let windows=await LaunchReadiness.visibleWindows()
            if let pid=LaunchReadiness.visibleProcess(windows,processes:processes),sheet == nil {
                NSRunningApplication(processIdentifier:pid)?.activate(options:[])
            }
        case .ready(let pid):
            existingName="Battle.net";screen = .running
            // Do not steal focus if the player switched to another app while
            // waiting, or from a sheet they opened (the running screen says
            // where the window is).
            if sheet == nil && NSApp.isActive { NSRunningApplication(processIdentifier:pid)?.activate(options:[]) }
        case .timedOut:
            notice=L("No Battle.net window was detected after 90 seconds. It may still be starting or be on another desktop. Check the Dock, or choose Open Battle.net to check again.")
        case .stopped: break
        }
    }
    /// After a stopped launch: Cancel closes the Battle.net this launch opened; quitting
    /// the app, or a Battle.net that was already open, leaves it running.
    private func stopLaunch(_ launchEvents:[[String:Any]]) async throws {
        canCancel=false
        let opened=launchEvents.contains { $0["stage"] as? String == "battlenet_open" }
        if closeOnStop && opened {
            stage=L("Closing Battle.net")
            _ = try await service.run("close-client",event:receive)
            screen = .ready;notice=L("Cancelled. Battle.net was closed.")
        } else {
            screen = .ready
            notice=L("Battle.net has been left running. Select it in the Dock, or choose Open Battle.net to check its window again.")
        }
    }
    func launch() { perform { try await self.openClient() } }
    /// Opens Battle.net (or uses the open one) and has it start Overwatch.
    func play() { perform { try await self.openClient(play:true) } }
    func reopen(openingBattleNet:Bool) {
        guard !busy && clientInstalled && sheet == nil else { return }
        perform {
            // A Dock click while Battle.net or Overwatch already runs shows this
            // window (Settings, Help, About) instead of hiding behind them.
            let sessions=try await self.service.run("session")
            let processes=sessions.last?["processes"] as? [[String:Any]] ?? []
            if !processes.isEmpty { self.showSession(processes);return }
            guard openingBattleNet && self.autoOpenBattleNet else { return }
            try await self.openClient()
        }
    }
    // Keeps the running screen accurate when the player returns to this window,
    // for example after quitting Battle.net or starting Overwatch. No polling.
    func syncSession() {
        guard !isPreview && !busy && screen == .running else { return }
        busy=true
        Task {
            defer { busy=false }
            do {
                let sessions=try await service.run("session")
                showSession(sessions.last?["processes"] as? [[String:Any]] ?? [])
                // Battle.net may have installed the game meanwhile (the Korean card needs to know).
                if !nexonBuild { try? await refresh() }
            } catch let error as SetupFailure where error.code == "install_location_unavailable" {
                failure=error;screen = .driveMissing
            } catch {}
        }
    }
    private func showSession(_ processes:[[String:Any]]) {
        guard !processes.isEmpty else { screen = .ready;gameWindowHidden=false;sessionLogging=nil;return }
        readSessionLogging()
        existingName=processes.contains { $0["kind"] as? String == "game" } ? "Overwatch" : "Battle.net"
        screen = .running
        watchExits(processes)
        let game=processes.first { $0["kind"] as? String == "game" }.flatMap { ($0["pid"] as? NSNumber)?.int32Value }
        guard let game else { gameWindowHidden=false;return }
        Task {
            let windows=await LaunchReadiness.visibleWindows()
            gameWindowHidden = !windows.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == game }
        }
    }
    /// Overwatch's window isn't on screen while it runs. After Exit to Desktop the game
    /// minimizes its window and keeps working, invisible, for 10–80 seconds before it quits
    /// (QA, 2026-10-14); a minimized game or one on another desktop looks the same, so the
    /// running screen offers Force Quit (GameClosingNote) and never ends the game itself.
    var gameWindowHidden=false
    /// macOS reports when each session process ends (a process dispatch source), so the
    /// running screen returns to Play the moment Overwatch or Battle.net quits. Nothing polls
    /// while the game runs.
    @ObservationIgnored private var exitWatches:[Int32:DispatchSourceProcess]=[:]
    private func watchExits(_ processes:[[String:Any]]) {
        for process in processes {
            guard let pid=(process["pid"] as? NSNumber)?.int32Value,exitWatches[pid] == nil else { continue }
            let source=DispatchSource.makeProcessSource(identifier:pid_t(pid),eventMask:.exit,queue:.main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sessionProcessEnded(pid) } }
            exitWatches[pid]=source;source.resume()
            // A process that ended before the source was set up never reports.
            if kill(pid,0) != 0 && errno == ESRCH { sessionProcessEnded(pid) }
        }
    }
    private func sessionProcessEnded(_ pid:Int32) {
        guard let source=exitWatches.removeValue(forKey:pid) else { return }
        source.cancel()
        Task {
            while busy { try? await Task.sleep(for:.milliseconds(250)) }
            syncSession()
            // The worker starts preparing shaders within about ten seconds of the game quitting.
            for _ in 0..<3 { checkAfterMatch();try? await Task.sleep(for:.seconds(6)) }
            checkAfterMatch()
        }
    }
    /// Settings: what runs now. The screen answers at once; a session check confirms it
    /// unless another step is using the worker.
    func checkRunning() {
        running = screen == .running ? (existingName == "Overwatch" ? .game : .client) : (screen == .launching ? .client : nil)
        guard !isPreview && clientInstalled && !busy else { return }
        busy=true
        Task {
            defer { busy=false }
            guard let processes=try? await service.run("session").last?["processes"] as? [[String:Any]] else { return }
            running=processes.isEmpty ? nil : (processes.contains { $0["kind"] as? String == "game" } ? .game : .client)
            if screen == .running || screen == .ready { showSession(processes) }
            // The resolution may have changed in Overwatch since Recall last looked.
            try? await refresh()
        }
    }
    /// Settings: closes Battle.net so a setting it carries can change. The worker
    /// refuses while Overwatch runs.
    func closeBattleNet() {
        guard !busy else { return }
        guard !isPreview else { running=nil;return }
        busy=true;notice=""
        Task {
            defer { busy=false }
            do {
                _ = try await service.run("close-client",event:receive)
                running=nil
                if screen == .running { screen = .ready }
            } catch let error as SetupFailure where error.code == "close_game_before_update" {
                running = .game
            } catch {
                notice=L("Battle.net couldn’t be closed. Quit it from the Dock, then try again.")
            }
        }
    }
    /// The launching screen's Cancel.
    func cancelLaunch() { guard canCancel && screen == .launching else { return };closeOnStop=true;cancel() }
    func cancel() { guard canCancel else { return };if screen == .launching { stopLaunchWait=true;canCancel=false;service.cancel();return };paused=true;canCancel=false;stage=L("Pausing safely");service.cancel() }
    /// Settings saves a resolution as soon as it is chosen. The worker records it and
    /// writes it into the game's settings, where a choice made in Overwatch's Video
    /// settings goes too; the latest of the two is what the next launch uses.
    func chooseResolution(_ choice:DisplayResolution) {
        guard choice != resolution else { return }
        resolution=choice;displaySaved=false
        displaySave?.cancel()
        guard !isPreview && clientInstalled else { return }
        displaySave=Task {
            // Another step (a launch, say) may be using the worker; save right after it.
            while busy { try? await Task.sleep(for:.milliseconds(200)) }
            guard !Task.isCancelled else { return }
            busy=true
            defer { busy=false }
            do {
                _ = try await service.run("display",["--width",String(choice.width),"--height",String(choice.height)])
                if resolution == choice { displaySaved=true }
            } catch {
                notice=(error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message
            }
        }
    }
    /// The main display changed while Settings was open: show its own resolution.
    func refreshDisplay() {
        guard !isPreview && !busy else { return }
        busy=true
        Task { defer { busy=false };try? await refresh() }
    }
    /// Settings › Remember a resolution for each display. On, the MacBook's screen and each
    /// monitor open at the resolution last chosen on them; off, one resolution everywhere.
    func setRememberEachDisplay(_ on:Bool) {
        guard on != rememberEachDisplay else { return }
        rememberEachDisplay=on
        guard !isPreview && clientInstalled else { return }
        Task {
            while busy { try? await Task.sleep(for:.milliseconds(200)) }
            busy=true
            defer { busy=false }
            do {
                _ = try await service.run("display-memory",["--enabled",on ? "1" : "0"])
                try await refresh()
            } catch {
                rememberEachDisplay = !on
                notice=(error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message
            }
        }
    }
    /// Settings › Advanced's proxy detection, and Korean account support (the Korea region,
    /// Settings › General). Battle.net carries both from when it opens, so Settings offers them
    /// only while it and Overwatch are closed (see running); the worker refuses otherwise. Before setup has made the Windows environment the worker only keeps the
    /// choice, and setup applies it.
    func setAdvanced(_ setting:AdvancedSetting, _ on:Bool) {
        let requested=pendingAdvancedSettings.last(where:{ $0.0 == setting })?.1 ?? (state[setting.rawValue] as? Bool == true)
        guard requested != on else { return }
        guard !isPreview else { state[setting.rawValue]=on;return }
        pendingAdvancedSettings.append((setting,on))
        guard advancedSettingsTask == nil else { return }
        // Reserve an idle worker before returning to the UI: Play must not open Battle.net
        // with the old setting while this Task is still waiting to run. Choices made during
        // another operation stay queued; perform blocks new work until this queue finishes.
        let waitForOperation=busy
        if !waitForOperation { busy=true }
        advancedSettingsTask=Task {
            if waitForOperation {
                while busy { try? await Task.sleep(for:.milliseconds(200)) }
                busy=true
            }
            notice=""
            defer { busy=false;advancedSettingsTask=nil }
            while let (setting,on)=pendingAdvancedSettings.first {
                do {
                    _ = try await service.run(setting == .proxyAutoDetect ? "network" : "korean-support",
                                              [setting == .proxyAutoDetect ? "--proxy-detect" : "--enabled",on ? "1" : "0"])
                    // Only show a saved choice after the worker succeeds. If the following
                    // status read fails, the successful write is still the known state.
                    state[setting.rawValue]=on
                    try await refresh()
                } catch {
                    notice=(error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message
                }
                pendingAdvancedSettings.removeFirst()
            }
        }
    }
    /// Help, on the tab that fits: Troubleshooting after a failed step, otherwise the
    /// questions; Report a Problem… asks for Support. The report is made fresh.
    func openHelp(_ tab:HelpTab?=nil, topic:String?=nil) {
        makeReport()
        helpTab=tab ?? (screen == .failure ? .troubleshooting : .questions)
        helpTopic=topic
        helpQuery=""
        sheet = .help
    }
    /// The Korean card's Open Settings: Settings on its General tab, where the region is.
    func openRegionSettings() { settingsTab = .general;sheet = .settings }
    /// Troubleshooting's way back from a resolution that shows a black or wrong-sized
    /// picture: a new installation's resolution, with every other display setting
    /// written again. Graphics quality and FPS are kept. Overwatch must be closed.
    func resetDisplay() {
        let initial=DisplayResolution.initial(for:MainDisplay.current)
        guard !isPreview else { resolution=initial;notice=L("Display settings reset.");return }
        displaySave?.cancel()
        displaySave=Task {
            while busy { try? await Task.sleep(for:.milliseconds(200)) }
            busy=true
            defer { busy=false }
            do {
                _ = try await service.run("display",["--width",String(initial.width),"--height",String(initial.height)])
                resolution=initial;displaySaved=false
                notice=L("Display settings reset. Overwatch opens at {0} next time.",initial.label)
            } catch {
                notice=(error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message
            }
        }
    }
    func uninstallEverything() {
        guard !isPreview else { uninstall = .done(appRemoved:true);return }
        uninstall = .working
        Task {
            // A launch wait is cancellable; let any other step finish first.
            while busy { cancel(); try? await Task.sleep(for:.milliseconds(100)) }
            busy=true; notice=""
            defer { busy=false }
            do { _ = try await service.run("uninstall",event:receive) }
            catch { uninstall = .failed((error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")).message);return }
            // The game folder is in the Trash. Now remove what lives outside it:
            // the single-instance lock folder, saved defaults, then the app itself.
            let lockDirectory=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("org.overwatch2mac.launcher")
            try? fm.removeItem(at:lockDirectory)
            if let id=Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName:id) }
            // Move to Trash, never delete; if macOS refuses, the user drags it.
            let appRemoved=(try? fm.trashItem(at:Bundle.main.bundleURL,resultingItemURL:nil)) != nil
            clientInstalled=false;gameInstalled=false;state=[:];screen = .welcome
            uninstall = .done(appRemoved:appRemoved)
        }
    }
    func makeReport() {
        // The main display's mode, without its name: a scaled mode is drawn larger or
        // smaller than the screen's own pixels (issue #9).
        let size={ (size:CGSize) in "\(Int(size.width))x\(Int(size.height))" }
        let display:Any=MainDisplay.current.map { ["type":$0.builtIn ? "built_in" : "external","points":size($0.points),"drawn":size($0.drawn),
                                                    "native":$0.native.map(size) ?? "unknown","refresh_hz":Int($0.refresh.rounded())] } ?? "none"
        // Where the default web browser comes from: China's Battle.net signs in through it.
        let browser=NSWorkspace.shared.urlForApplication(toOpen:URL(string:"https://www.battlenet.com.cn/")!).flatMap { Bundle(url:$0)?.bundleIdentifier } ?? "unknown"
        let battleNet:[String:Any]=["region":installedRegion.rawValue,"language":state["battlenet_language"] as? String ?? (clientInstalled ? "enUS" : "not_chosen"),
                                    "installed":clientInstalled,"path":battleNetPath.replacingOccurrences(of:"environment/drive_c/",with:""),"neac_build":neacBuild,"nexon_build":nexonBuild,"korean_support":koreanSupport,
                                    "recent_starts":BattleNetRecord.read(root:root)]
        // Logging (REC-40): the setting, what Custom holds exactly as typed, and since when.
        var logs:[String:Any]=["setting":logging.rawValue]
        if logging == .custom { logs["custom"]=loggingCustom }
        if let since=loggingSince,logging != .off { logs["since"]=ISO8601DateFormatter().string(from:since) }
        if let sessionLogging { logs["open_session"]=sessionLogging.rawValue }
        // Schema 3 (1.5.0): MetalFX upscaling and its sharpening apart (schema 2 gave the sharpening
        // when on, so "off" was ambiguous); shaders.waiting_for_game_to_close; battlenet.recent_starts; logging (REC-40).
        // Schema 4 (1.5.0): other_apps, what the busy note saw at the last launch and now (REC-5).
        let fresh=loadChecked.map { Date().timeIntervalSince($0) < 15 } ?? false
        let otherApps:[String:Any]=["at_last_launch":launchLoad ?? "none","now":fresh ? macLoad.report as Any : "not_checked"]
        let data:[String:Any]=["schema":4,"other_apps":otherApps,"logging":logs,"battlenet":battleNet,"app_language":AppLanguage.current,"default_browser":browser,"main_display":display,"app_version":release?.appVersion ?? "unknown","runtime_version":state["active_runtime"] as? String ?? "not_installed","macos":ProcessInfo.processInfo.operatingSystemVersionString,"memory_gib":ProcessInfo.processInfo.physicalMemory>>30,"architecture":"arm64","free_gib":freeBytes>>30,"game_installed":gameInstalled,"display_resolution":"\(resolution.width)x\(resolution.height)","metalfx_upscaling":metalFXUpscaling ? "on" : "off","metalfx_sharpening":metalFXSharpening.rawValue,"install_location":InstallLocation.isStandard(root) ? "default" : (InstallLocation.isInternal(root) ? "other_internal" : "external"),"recent_stages":lastEvents,"last_error":failure.reportCode,"shaders":ShaderRecord.read(root:root),"shader_memory":shaderMemory]
        report=String(data:(try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys])) ?? Data(),encoding:.utf8) ?? ""
    }
    /// Save Logs (Settings › Advanced, Help › Support): the zip LogBundle makes, saved where the
    /// player chooses and shown in Finder so it's ready to attach.
    func saveLogs() {
        guard !savingLogs else { return }
        // Previews show the saved line with the size of the owner's logs of October 19 (1.7 MB).
        guard !isPreview else { savedLogs=(LogBundle.defaultName(),1_686_655);return }
        let panel=NSSavePanel();panel.nameFieldStringValue=LogBundle.defaultName();panel.title=L("Save logs")
        panel.allowedContentTypes=[.zip]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        makeReport()
        let input=LogBundle.Input(root:root,report:report,appVersion:release?.appVersion ?? "unknown",runtime:state["active_runtime"] as? String ?? "not_installed",
                                  logging:logging,custom:loggingCustom,since:loggingSince,readme:Bundle.main.url(forResource:"LogsReadme",withExtension:"md"))
        savingLogs=true;savedLogs=nil
        Task {
            let result=await Task.detached(priority:.userInitiated) { Result { try LogBundle.save(input,to:url) } }.value
            savingLogs=false
            switch result {
            case .success(let saved):
                savedLogs=(url.lastPathComponent,saved.bytes)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure:
                notice=L("The logs couldn’t be saved. Choose another location and try again.")
            }
        }
    }
    func saveReport() {
        let panel=NSSavePanel();panel.nameFieldStringValue="\(Brand.name)-support.json";panel.title=L("Save support report")
        if panel.runModal() == .OK,let url=panel.url { do { try report.write(to:url,atomically:true,encoding:.utf8) } catch { notice=L("The report couldn’t be saved. Choose another location and try again.") } }
    }
}
