import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class AppModel {
    enum Screen: String, CaseIterable { case welcome, moveApp, checking, readyToInstall, preparing, launching, installer, ready, running, driveMissing, failure }
    enum Sheet: String, Identifiable { case settings, help, about, uninstall, update, whatsNew; var id: String { rawValue } }
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
    /// Battle.net drawn at twice Windows' size, the size it has on a Mac (worker: launch
    /// --battlenet-scale). Off keeps Windows' size, in case a Battle.net update breaks it.
    var largeBattleNet=UserDefaults.standard.object(forKey:"largeBattleNet") as? Bool ?? true {
        didSet { UserDefaults.standard.set(largeBattleNet,forKey:"largeBattleNet") }
    }
    /// Opening the app opens Battle.net too. Off, the player starts it with Open Battle.net.
    var autoOpenBattleNet=UserDefaults.standard.object(forKey:"autoOpenBattleNet") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoOpenBattleNet,forKey:"autoOpenBattleNet") }
    }
    var firstMatchTipDismissed=UserDefaults.standard.bool(forKey:"firstMatchTipDismissed") {
        didSet { UserDefaults.standard.set(firstMatchTipDismissed,forKey:"firstMatchTipDismissed") }
    }
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
    /// Settings shows "Saved" once the chosen resolution is recorded.
    var displaySaved=false
    @ObservationIgnored private var displaySave:Task<Void,Never>?
    var freeBytes: UInt64=0
    var gameInstalled=false
    var clientInstalled=false
    var downloadedBytes: UInt64=0
    var lastEvents=[String]()
    var release: Release?
    var root: URL
    /// The installed Battle.net program; the worker launches the same file.
    var battleNetExecutable:URL { root.appendingPathComponent("environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe") }
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
    var title: String {
        switch screen {
        case .welcome: return Brand.name
        case .moveApp: return installedCopy == nil ? "Move \(Brand.name) to Applications" : "\(Brand.name) is already installed"
        case .checking: return "Checking your Mac"
        case .readyToInstall: return clientInstalled ? "Finish setup" : "Set up Battle.net"
        case .preparing: return repairing ? "Repairing" : (updatingComponents ? "Updating \(Brand.name)" : "Setting up Overwatch")
        case .launching: return "Opening Battle.net"
        case .installer: return "Finish in Battle.net"
        case .ready: return gameInstalled ? "Play Overwatch" : "Install Overwatch"
        case .running: return "\(existingName) is running"
        case .driveMissing: return "Connect \(driveName)"
        case .failure:
            switch failure.code {
            case "cancelled": return "Setup paused"
            case "insufficient_disk_space": return "More space needed"
            case "rosetta_required": return "Install Rosetta"
            case "close_installer_client": return "Close Battle.net first"
            case "run_from_installed_app", "app_move_failed", "app_name_taken": return "Move \(Brand.name) to Applications"
            default: return "Setup needs attention"
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
        // Allowlisted stage names only; never retain arbitrary error detail/paths.
        let labels=["downloading":"Downloading Battle.net", "download_verified":"Download verified", "installing_runtime":"Installing game components", "runtime_ready":"Game components ready", "preparing_environment":"Preparing your game environment", "environment_ready":"Game environment ready", "installing_battlenet":"Opening the Battle.net installer", "preparing_pipelines":"Preparing graphics", "battlenet_started":"Opening Battle.net", "pipeline_preparation_skipped":"Opening Battle.net", "closing_client":"Closing Battle.net", "displays_changed":"Reopening Battle.net for your displays"]
        if let label=labels[name] { stage=label; lastEvents.append(name); lastEvents=Array(lastEvents.suffix(12)) }
    }
    func refresh() async throws {
        let values=try await service.run("status")
        guard let status=values.last else { throw SetupFailure(code:"status_unavailable") }
        state=status["state"] as? [String:Any] ?? [:]
        clientInstalled=status["battlenet_installed"] as? Bool ?? false
        gameInstalled=status["game_installed"] as? Bool ?? false
        freeBytes=(status["free_bytes"] as? NSNumber)?.uint64Value ?? 0
        // Match Finder's "available" figure, which includes purgeable storage.
        if let available=try? root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,available>0 {
            freeBytes=max(freeBytes,UInt64(available))
        }
        // Installations from before 1.0 saved only a height, 1920 pixels wide.
        let saved=DisplayResolution(width:state["display_width"] as? Int ?? 1920,height:state["display_height"] as? Int ?? 1200)
        resolution=saved.isSupported ? saved : .standard
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isPreview else { return }
        guard !busy else { return }; busy=true; notice=""; paused=false
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
        // Opened from the disk image: move to Applications before anything else.
        if AppLocation.needsMove(Bundle.main.bundleURL) { prepareMove();return }
        if automaticUpdates { checkForUpdates(manual:false) }
        screen = .checking
        perform {
            guard self.release != nil else { throw SetupFailure(code:"release_unavailable") }
            let retired=self.retireOlderCopies()
            try await self.route(autoLaunch:true)
            if let old=retired.first,self.notice.isEmpty {
                self.notice="The old \(old.url.deletingPathExtension().lastPathComponent) app is in the Trash now. \(Brand.name) replaces it; your game and sign-in are kept."
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
    /// Copies this app into Applications (verified like an update), moves older
    /// copies to the Trash, then reopens it from there and ejects the disk image.
    func moveToApplications() {
        perform {
            let bundle=Bundle.main.bundleURL
            guard let team=UpdateInstaller.team(of:bundle),let identifier=Bundle.main.bundleIdentifier else { throw SetupFailure(code:"run_from_installed_app") }
            self.stage="Copying \(Brand.name) to Applications"
            let target=try AppLocation.destination(identifier:identifier)
            try await AppLocation.install(bundle,at:target,team:team,identifier:identifier,version:UpdateCheck.installed)
            _ = AppLocation.retire(AppLocation.olderCopies(identifier:identifier,version:UpdateCheck.installed,build:UpdateCheck.build,keeping:target))
            let volume=await AppLocation.diskImageVolume(containing:AppLocation.original(of:bundle))
            UpdateInstaller.relaunch(target,ejecting:volume)
            self.busy=false
            NSApp.terminate(nil)
        }
    }
    /// A copy at least as new is already installed: open it instead.
    func openInstalledCopy() {
        guard let copy=installedCopy else { return }
        perform {
            let volume=await AppLocation.diskImageVolume(containing:AppLocation.original(of:Bundle.main.bundleURL))
            UpdateInstaller.relaunch(copy.url,ejecting:volume)
            self.busy=false
            NSApp.terminate(nil)
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
        } else if state["active_runtime"] != nil { screen = .readyToInstall }
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
            catch { update = manual ? .failed("The update check couldn’t reach GitHub. Check your internet connection, then try again.") : .idle }
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
                NSApp.terminate(nil)
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
        case "close_game_before_update": return "Quit Overwatch first, then choose Update Now."
        case "client_close_failed": return "Battle.net couldn’t be closed. Quit it from the Dock, then try again."
        case "update_location_read_only": return "This copy of the app is in a folder you can’t change. Download the update from the release page instead."
        case "update_signature_invalid": return "The download couldn’t be verified as an official release, so nothing was changed."
        case "update_hash_mismatch", "update_download_failed": return "The download didn’t complete correctly. Nothing was changed. Try again."
        default: return "The update couldn’t be installed. Nothing was changed. You can try again or download it from the release page."
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
        panel.title="Choose Install Location";panel.prompt="Choose"
        panel.message="Choose a drive or folder. Overwatch, Battle.net and their files go in an “\(InstallLocation.folderName)” folder inside it."
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
        launchStarted=Date();stage=value == .launching ? "Waiting for the Battle.net window" : "Preparing your game environment"
        failure=SetupFailure(code:"insufficient_disk_space")
        // Setup screens show the location dropdown as for a new installation.
        if value == .readyToInstall { clientInstalled=false;gameInstalled=false;freeBytes=412_000_000_000 }
        update = .upToDate
        state["onboarding_complete"]=value != .welcome && value != .readyToInstall && value != .installer
        if value == .moveApp { moveReplaces=["Overwatch 2 Mac"] }
        let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--preview-sheet"),args.indices.contains(i+1),let preview=Sheet(rawValue:args[i+1]) {
            if preview == .update {
                update = .available(AvailableUpdate(version:"1.0.1",notes:["Fixes an issue that could stop Battle.net from opening after a Blizzard update.","Smoother first matches after installing."],page:Brand.releases,download:Brand.releases,size:242_000_000,sha256:"",checksum:nil))
            }
            DispatchQueue.main.async { self.sheet=preview }
        }
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
            self.screen = .readyToInstall
        }
    }
    func setup() { perform { try await self.setupSteps() } }
    private func setupSteps() async throws {
        guard let release else { throw SetupFailure(code:"release_unavailable") }
        _ = try await service.run("preflight")
        try await refresh()
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
            let initial=MainDisplay.current?.shape == .monitor ? DisplayResolution(shape:.monitor,size:.standard) : .standard
            _ = try await service.run("display",["--width",String(initial.width),"--height",String(initial.height)])
        }
        if clientInstalled { screen = .ready;return }
        stage="Downloading Battle.net"
        let progress=Task { @MainActor in
            while !Task.isCancelled {
                let file=self.root.appendingPathComponent("downloads/"+release.installerSHA256+".part")
                self.downloadedBytes=(try? self.fm.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.uint64Value ?? 0
                try? await Task.sleep(for:.seconds(0.5))
            }
        }
        defer { progress.cancel() }
        _ = try await service.run("download",["--url",release.installerURL,"--sha256",release.installerSHA256],event:receive)
        if paused { throw SetupFailure(code:"cancelled") }
        canCancel=false
        _ = try await service.run("install-battlenet",["--installer",root.appendingPathComponent("downloads/"+release.installerSHA256).path,"--sha256",release.installerSHA256],event:receive)
        screen = .installer
    }
    /// Closes Overwatch and Battle.net at once (wineserver -k), for a game that
    /// stopped responding. The player confirms first.
    func forceQuit() {
        perform {
            _ = try await self.service.run("stop")
            self.screen = .ready
            self.notice="Overwatch and Battle.net were closed."
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
            self.notice="Repair finished. Overwatch, its settings and your Battle.net sign-in were kept."
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
        screen = .launching;stage="Checking your running session"
        launchStarted=Date();stopLaunchWait=false;closeOnStop=false;canCancel=true
        // Cancelling here ends the worker, and with it the graphics preparation, before
        // Battle.net opens (the preparation keeps its finished work; the next launch resumes).
        let launchEvents:[[String:Any]]
        do {
            launchEvents=try await service.run("launch",(play ? ["--play","1"] : [])+["--battlenet-scale",largeBattleNet ? "2" : "1"],event:receive)
        } catch {
            guard stopLaunchWait else { throw error }
            canCancel=false;screen = .ready;notice="Cancelled. Battle.net wasn’t opened."
            return
        }
        // A Cancel that arrived as Battle.net was starting.
        if stopLaunchWait { try await stopLaunch(launchEvents);return }
        // The chosen resolution is larger than this main display allows (see MainDisplay.fits).
        if let fitted=launchEvents.last(where:{ $0["stage"] as? String == "display_fitted" }),
           let width=fitted["width"] as? Int,let height=fitted["height"] as? Int {
            notice="Your main display is too small for \(resolution.label), so Overwatch uses \(width) × \(height) this time."
        }
        // Battle.net was open from before a display was connected, unplugged or rearranged.
        if launchEvents.contains(where:{ $0["stage"] as? String == "displays_changed" }) {
            notice="Your displays changed since Battle.net opened, so \(Brand.name) reopened it."
        }
        canCancel=false
        _ = try await service.run("onboarded")
        state["onboarding_complete"]=true
        stage="Waiting for the Battle.net window";canCancel=true
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
            notice="No Battle.net window was detected after 90 seconds. It may still be starting or be on another desktop. Check the Dock, or choose Open Battle.net to check again."
        case .stopped: break
        }
    }
    /// After a stopped launch: Cancel closes the Battle.net this launch opened; quitting
    /// the app, or a Battle.net that was already open, leaves it running.
    private func stopLaunch(_ launchEvents:[[String:Any]]) async throws {
        canCancel=false
        let opened=launchEvents.contains { $0["stage"] as? String == "battlenet_open" }
        if closeOnStop && opened {
            stage="Closing Battle.net"
            _ = try await service.run("close-client",event:receive)
            screen = .ready;notice="Cancelled. Battle.net was closed."
        } else {
            screen = .ready
            notice="Battle.net has been left running. Select it in the Dock, or choose Open Battle.net to check its window again."
        }
    }
    func launch() { perform { try await self.openClient() } }
    /// Opens Battle.net (or uses the open one) and has it start Overwatch.
    func play() { perform { try await self.openClient(play:true) } }
    func reopen() {
        guard !busy && clientInstalled && sheet == nil else { return }
        perform {
            // A Dock click while Battle.net or Overwatch already runs shows this
            // window (Settings, Help, About) instead of hiding behind them.
            let sessions=try await self.service.run("session")
            let processes=sessions.last?["processes"] as? [[String:Any]] ?? []
            if !processes.isEmpty { self.showSession(processes);return }
            guard self.autoOpenBattleNet else { return }
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
            } catch let error as SetupFailure where error.code == "install_location_unavailable" {
                failure=error;screen = .driveMissing
            } catch {}
        }
    }
    private func showSession(_ processes:[[String:Any]]) {
        guard !processes.isEmpty else { screen = .ready;return }
        existingName=processes.contains { $0["kind"] as? String == "game" } ? "Overwatch" : "Battle.net"
        screen = .running
    }
    /// The launching screen's Cancel.
    func cancelLaunch() { guard canCancel && screen == .launching else { return };closeOnStop=true;cancel() }
    func cancel() { guard canCancel else { return };if screen == .launching { stopLaunchWait=true;canCancel=false;service.cancel();return };paused=true;canCancel=false;stage="Pausing safely";service.cancel() }
    /// Settings saves a resolution as soon as it is chosen. The worker records it and
    /// writes it into the game's settings, and every launch writes it again, so a choice
    /// made while Overwatch is open takes effect the next time it starts.
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
        let allowedCodes:Set<String>=["cancelled","insufficient_disk_space","rosetta_required","download_hash_mismatch","download_interrupted_retry_to_resume","battlenet_not_installed","session_membership_unknown","invalid_game_settings","process_failed","runtime_missing","close_game_before_maintenance","close_game_before_setup","install_location_unavailable","app_move_failed","app_name_taken","unsupported_volume_format","case_sensitive_volume","read_only_volume"]
        let data:[String:Any]=["schema":1,"app_version":release?.appVersion ?? "unknown","runtime_version":state["active_runtime"] as? String ?? "not_installed","macos":ProcessInfo.processInfo.operatingSystemVersionString,"memory_gib":ProcessInfo.processInfo.physicalMemory>>30,"architecture":"arm64","free_gib":freeBytes>>30,"game_installed":gameInstalled,"display_resolution":"\(resolution.width)x\(resolution.height)","install_location":InstallLocation.isStandard(root) ? "default" : (InstallLocation.isInternal(root) ? "other_internal" : "external"),"recent_stages":lastEvents,"last_error":failure.code.isEmpty ? "none" : (allowedCodes.contains(failure.code) ? failure.code:"other_setup_error")]
        report=String(data:(try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys])) ?? Data(),encoding:.utf8) ?? ""
    }
    func saveReport() {
        let panel=NSSavePanel();panel.nameFieldStringValue="\(Brand.name)-support.json";panel.title="Save support report"
        if panel.runModal() == .OK,let url=panel.url { do { try report.write(to:url,atomically:true,encoding:.utf8) } catch { notice="The report couldn’t be saved. Choose another location and try again." } }
    }
}
