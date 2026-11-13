import SwiftUI
import AppKit

// REC-82: Settings › General › Move… takes the whole installation (Battle.net, Overwatch, the
// player's settings and learned shaders) to another drive or folder, with no download. The worker
// does it (scripts/portable_move.h): on the same volume a rename; otherwise a copy that is checked
// file by file before the app switches to it, after which the earlier copy goes to the Trash.
// Until then the installation in use is untouched, so a move that is cancelled or interrupted
// leaves the player where they were.

/// Where a move goes.
struct MovePlan: Equatable {
    let destination: URL
    /// On the same volume the folder is renamed: nothing is copied, and nothing goes to the Trash.
    let sameVolume: Bool
}
/// How far the worker's copy, then its check of the copy, have come (move_progress).
struct MoveProgress: Equatable {
    var checking=false
    var bytes: Int64=0
    var total: Int64=0
    /// When this half began, for the time left.
    var began=Date()
    /// One bar for both halves: the copy fills the first, the check the second.
    var fraction: Double {
        guard total > 0 else { return 0 }
        let part=min(1,Double(bytes)/Double(total))/2
        return checking ? 0.5+part : part
    }
    /// Seconds left in this half, once there is enough to judge by.
    func secondsLeft(now: Date=Date())->Int? {
        let elapsed=now.timeIntervalSince(began)
        guard elapsed >= 5,bytes > 0,total > bytes else { return nil }
        return Int(elapsed*Double(total-bytes)/Double(bytes))
    }
    mutating func update(_ value: [String:Any],now: Date=Date()) {
        let nowChecking=value["phase"] as? String == "checking"
        if nowChecking != checking || total == 0 { began=now }
        checking=nowChecking
        bytes=(value["bytes"] as? NSNumber)?.int64Value ?? 0
        total=(value["total"] as? NSNumber)?.int64Value ?? 0
    }
}
struct MoveResult: Equatable {
    let from: URL
    let to: URL
    /// False for a rename on the same volume, which leaves no earlier copy.
    let copied: Bool
    /// The earlier copy is in the Trash. If macOS refused, it is still where it was.
    let trashed: Bool
    let bytes: Int64?
}
enum InstallMove: Equatable {
    case idle
    case ready(MovePlan)
    case working(MovePlan)
    case failed(MovePlan,String)
    case done(MoveResult)
    /// The sheet closes only by its own buttons while a move runs or asks what to do after failing.
    var staysOpen: Bool { switch self { case .working, .failed: return true; default: return false } }
    var isWorking: Bool { if case .working=self { return true };return false }
}

extension AppModel {
    /// The folder picker, then the sheet that says what the move takes. A folder that can't hold
    /// the installation says why in Settings.
    func chooseMoveDestination() {
        guard !isPreview,!busy,!canChangeLocation else { return }
        let panel=NSOpenPanel()
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false
        panel.title=L("Choose Where to Move Overwatch");panel.prompt=L("Choose")
        panel.message=L("Choose a drive or folder. Overwatch, Battle.net and their files move into an “{0}” folder inside it.",InstallLocation.folderName)
        panel.directoryURL=URL(fileURLWithPath:"/Volumes")
        if panel.runModal() == .OK,let folder=panel.url { planMove(to:InstallLocation.root(forChosen:folder)) }
    }
    func planMove(to destination:URL) {
        if let issue=InstallLocation.moveIssue(from:root,to:destination) { notice=issue.message;noticeTopic=issue.helpTopic;return }
        notice=""
        move = .ready(MovePlan(destination:destination,sameVolume:InstallLocation.sameVolume(root,destination)))
        sheet = .moveInstallation
    }
    /// Move, or Try Again after a move that didn't finish (the worker goes on from its part copy).
    func startMove() {
        let plan:MovePlan
        switch move { case .ready(let chosen), .failed(let chosen,_): plan=chosen; default: return }
        move = .working(plan);moveProgress=MoveProgress();moveCancelling=false
        Task {
            // A launch wait is cancellable; let any other step finish first.
            while busy { cancel(); try? await Task.sleep(for:.milliseconds(100)) }
            busy=true;notice="";stage=""
            defer { busy=false }
            let from=root,destination=plan.destination.standardizedFileURL
            // Cancel pressed before the worker started: nothing moved, and a part copy from an
            // earlier try goes, as it does when the worker is cancelled.
            guard !moveCancelling else { await discardPartCopy(destination);moveCancelling=false;move = .idle;sheet = .settings;return }
            // Going on with a move given up on earlier: its part copy is wanted again.
            if UserDefaults.standard.string(forKey:InstallLocation.discardKey) == destination.path { UserDefaults.standard.removeObject(forKey:InstallLocation.discardKey) }
            // Kept until the app has taken the new place, so a move the app doesn't see finish is
            // still found when it next opens (AppModel.init).
            UserDefaults.standard.set(destination.path,forKey:InstallLocation.pendingKey)
            var result=[String:Any]()
            do {
                let events=try await service.run("move",["--to",destination.path]) { value in self.receiveMove(value,destination) }
                result=events.last { $0["stage"] as? String == "moved" } ?? [:]
            } catch {
                // Past move_committed the copy is the installation, whatever stopped the worker after.
                guard root.standardizedFileURL.path == destination.path else {
                    UserDefaults.standard.removeObject(forKey:InstallLocation.pendingKey)
                    let failure=error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")
                    if failure.code == "cancelled" && moveCancelling {
                        // The worker removes the part copy as it stops; one it was cancelled too
                        // early to reach (while Battle.net closed) goes here.
                        await discardPartCopy(destination)
                        move = .idle;sheet = .settings
                    } else { move = .failed(plan,(failure.code == "cancelled" ? SetupFailure(code:"move_copy_failed") : failure).message) }
                    moveCancelling=false
                    // Battle.net was closed for the move.
                    running=nil
                    if screen == .running { screen = .ready }
                    return
                }
                result=["copied":true,"kept":from.path]
            }
            if root.standardizedFileURL.path != destination.path { setRoot(destination) }
            UserDefaults.standard.removeObject(forKey:InstallLocation.pendingKey)
            let copied=result["copied"] as? Bool ?? true,trashed=result["trashed"] != nil
            // An earlier copy macOS wouldn't take to the Trash is still an installation: Settings
            // keeps it one choice away, as after Set Up on This Mac Instead (REC-44).
            if copied && !trashed && InstallLocation.isInstallation(from) { otherRoot=from }
            running=nil
            if screen == .running { screen = .ready }
            try? await refresh()
            move = .done(MoveResult(from:from,to:destination,copied:copied,trashed:trashed,bytes:(result["bytes"] as? NSNumber)?.int64Value))
        }
    }
    private func receiveMove(_ value:[String:Any],_ destination:URL) {
        switch value["stage"] as? String {
        case "move_progress": moveProgress.update(value)
        // The copy has its final name: the app keeps the new place before the original leaves.
        case "move_committed":
            setRoot(destination)
            UserDefaults.standard.removeObject(forKey:InstallLocation.pendingKey)
        default: receive(value)
        }
    }
    /// The worker stops, removes the part copy and reports "cancelled"; the installation is as it was.
    func cancelMove() {
        guard case .working=move,!moveCancelling else { return }
        moveCancelling=true
        service.cancel()
    }
    /// Cancel after a move that didn't finish: the part copy it left goes too.
    func abandonMove() {
        guard case .failed(let plan,_)=move else { return }
        move = .idle;sheet = .settings
        Task {
            while busy { try? await Task.sleep(for:.milliseconds(100)) }
            busy=true
            defer { busy=false }
            await discardPartCopy(plan.destination)
        }
    }
    /// The part copy beside a move's destination goes (the worker's move --discard 1, which only
    /// removes one it made). With that drive unplugged it is remembered instead, and goes when the
    /// drive is next connected. The caller holds `busy`.
    func discardPartCopy(_ destination:URL) async {
        let destination=destination.standardizedFileURL
        guard InstallLocation.isAvailable(destination) else { UserDefaults.standard.set(destination.path,forKey:InstallLocation.discardKey);return }
        if UserDefaults.standard.string(forKey:InstallLocation.discardKey) == destination.path { UserDefaults.standard.removeObject(forKey:InstallLocation.discardKey) }
        guard FileManager.default.fileExists(atPath:InstallLocation.partCopy(for:destination).path) else { return }
        _ = try? await service.run("move",["--to",destination.path,"--discard","1"])
    }
    func discardRememberedPartCopy() async {
        guard let path=UserDefaults.standard.string(forKey:InstallLocation.discardKey) else { return }
        await discardPartCopy(URL(fileURLWithPath:path))
    }
    /// A drive was connected while nothing waits for one: a remembered part copy on it goes.
    func driveConnected() {
        guard !isPreview,!busy,UserDefaults.standard.string(forKey:InstallLocation.discardKey) != nil else { return }
        busy=true
        Task {
            defer { busy=false }
            await discardRememberedPartCopy()
        }
    }
    /// A move the app didn't see finish (InstallLocation.pendingMove), looked at whenever the app
    /// works out where it is (route): at launch, and when a drive it waits for is connected. The
    /// app follows a finished move to the new place, with the folder it came from offered back if
    /// that is still an installation. While the new place's drive is unplugged and the folder in
    /// use holds no installation, the app asks for that drive instead of setting up anew.
    func followPendingMove() {
        guard !move.isWorking,let path=UserDefaults.standard.string(forKey:InstallLocation.pendingKey) else { return }
        let pending=URL(fileURLWithPath:path).standardizedFileURL
        switch InstallLocation.pendingMove(current:rootBeforePending ?? root,pending:pending) {
        case .finished(let left):
            UserDefaults.standard.removeObject(forKey:InstallLocation.pendingKey);rootBeforePending=nil
            setRoot(pending)
            if let left { otherRoot=left }
        case .waiting(let showsDrive):
            // Not saved: only until the drive can say whether the move finished.
            if showsDrive,rootBeforePending == nil { rootBeforePending=root;root=pending;service.root=pending }
        case .unfinished:
            UserDefaults.standard.removeObject(forKey:InstallLocation.pendingKey)
            if let before=rootBeforePending { root=before;service.root=before;rootBeforePending=nil }
        }
    }
    /// Cancel before anything started, or Done after: back to Settings, where Move… is.
    func closeMove() { move = .idle;sheet = .settings }
    /// A private preview's move sheet (--preview-sheet moveInstallation --preview-move <kind>):
    /// ready, same (drive), copying, checking, cancelling, failed, done, kept (out of the Trash)
    /// or renamed. It names the first external drive connected, or one that isn't there.
    func previewMove(_ kind:String) {
        let volumes=FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil,options:[.skipHiddenVolumes]) ?? []
        let drive=(volumes.first { !InstallLocation.isInternal($0) } ?? URL(fileURLWithPath:"/Volumes/T7 Shield")).appendingPathComponent(InstallLocation.folderName)
        let same=kind == "same" || kind == "renamed"
        let plan=MovePlan(destination:same ? URL(fileURLWithPath:"/Users/Shared/Games/\(InstallLocation.folderName)") : drive,sameVolume:same)
        let size:Int64=92_400_000_000
        switch kind {
        case "copying","checking","cancelling":
            move = .working(plan);moveCancelling=kind == "cancelling"
            moveProgress=MoveProgress(checking:kind == "checking",bytes:kind == "checking" ? size*7/10 : size*3/10,total:size,began:Date().addingTimeInterval(-90))
        case "failed": move = .failed(plan,SetupFailure(code:"move_destination_disconnected").message)
        case "done","kept","renamed": move = .done(MoveResult(from:root,to:plan.destination,copied:kind != "renamed",trashed:kind == "done",bytes:size))
        default: move = .ready(plan)
        }
    }
}

struct MoveInstallationSheet:View {
    @Bindable var model:AppModel
    /// What the installation takes and what the destination has free, for a copy to another volume.
    @State private var size:Int64?
    @State private var free:Int64?
    private func bytes(_ value:Int64)->String { ByteCountFormatter.string(fromByteCount:value,countStyle:.file) }
    var body:some View {
        FittedSheet {
            switch model.move {
            case .idle: EmptyView()
            case .ready(let plan): ready(plan)
            case .working(let plan): working(plan)
            case .failed(_,let message):
                SheetHero(symbol:"exclamationmark.triangle",title:L("The move didn’t finish"),subtitle:message)
                LauncherNotice(text:L("Overwatch and Battle.net are still on “{0}” and open as before.",InstallLocation.title(model.root)))
            case .done(let result): done(result)
            }
        } actions: {
            switch model.move {
            case .idle: EmptyView()
            case .ready(let plan):
                HStack(spacing:16) {
                    Button(L("Cancel"),action:model.closeMove).buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    LauncherPrimaryAction(title:L("Move"),action:model.startMove)
                        .keyboardShortcut(.defaultAction).disabled(model.running == .game || !fits(plan))
                }
            case .working(let plan):
                // A rename is over before it could be cancelled.
                if !plan.sameVolume {
                    Button(L("Cancel"),action:model.cancelMove).buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .controlSize(.large).disabled(model.moveCancelling)
                }
            case .failed:
                HStack(spacing:16) {
                    Button(L("Cancel"),action:model.abandonMove).buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    LauncherPrimaryAction(title:L("Try Again"),action:model.startMove).keyboardShortcut(.defaultAction)
                }
            case .done:
                Button(L("Done"),action:model.closeMove).buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction).closesOnEscape(model.closeMove)
            }
        }.font(LauncherStyle.font(14))
            .tint(.primary).background { LauncherBackground() }
            .task {
                guard case .ready(let plan)=model.move,!plan.sameVolume else { return }
                // A preview measures nothing: an installation's usual size, and room for it.
                guard !model.isPreview else { size=92_400_000_000;free=412_000_000_000;return }
                let root=model.root
                free=InstallLocation.freeBytes(at:plan.destination)
                size=await Task.detached { InstallLocation.size(root) }.value
            }
    }
    /// Known not to fit, by the worker's own measure (a little over the size, for the volume's
    /// bookkeeping); the worker checks again itself before it closes Battle.net.
    private func fits(_ plan:MovePlan)->Bool {
        guard !plan.sameVolume,let size,let free else { return true }
        return free >= size+size/50+(8<<20)
    }
    @ViewBuilder private func ready(_ plan:MovePlan)->some View {
        let name=InstallLocation.title(plan.destination),drive=InstallLocation.driveName(plan.destination)
        SheetHero(symbol:InstallLocation.symbol(plan.destination),title:L("Move to “{0}”?",name),
                  subtitle:L("Overwatch, Battle.net, your settings and learned shaders move together. Nothing downloads again."))
        LauncherPanel {
            VStack(alignment:.leading,spacing:8) {
                row(L("From"),InstallLocation.title(model.root))
                row(L("To"),name)
                if !plan.sameVolume {
                    row(L("Size"),size.map(bytes) ?? L("Working out its size…"))
                    if let free { row(L("Free there"),bytes(free)) }
                }
            }
        }
        if model.running == .game {
            LauncherNotice(text:L("Quit Overwatch to move it."),symbol:"exclamationmark.triangle")
        } else if !fits(plan),let size,let free {
            LauncherNotice(text:L("“{0}” needs {1} more free space for this.",drive,bytes(size+size/50+(8<<20)-free)),symbol:"exclamationmark.triangle")
        } else if plan.sameVolume {
            LauncherNotice(text:L("Both are on the same drive, so this takes a moment. Battle.net is closed for you if it’s open."))
        } else {
            LauncherNotice(text:L("Keep “{0}” connected until it’s done. {1} checks the copy, then moves the earlier one to the Trash. Battle.net is closed for you if it’s open.",drive,Brand.name))
        }
    }
    @ViewBuilder private func working(_ plan:MovePlan)->some View {
        let progress=model.moveProgress
        SheetHero(symbol:InstallLocation.symbol(plan.destination),title:L("Moving to “{0}”",InstallLocation.title(plan.destination)),subtitle:status(progress))
        if progress.total > 0 && !model.moveCancelling {
            ProgressView(value:progress.fraction).frame(maxWidth:360).accessibilityLabel(L("Move progress"))
        } else {
            ProgressView().controlSize(.small).accessibilityLabel(L("Moving"))
        }
        if !plan.sameVolume && !model.moveCancelling {
            Text(L("Keep “{0}” connected. Your Mac stays awake until it’s done.",InstallLocation.driveName(plan.destination)))
                .font(LauncherStyle.font(12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        // Quit asked for while the move runs (AppDelegate.applicationShouldTerminate).
        if !model.notice.isEmpty { LauncherNotice(text:model.notice) }
    }
    private func status(_ progress:MoveProgress)->String {
        if model.moveCancelling { return L("Cancelling. Overwatch and Battle.net stay where they were.") }
        guard progress.total > 0 else { return model.stage == L("Closing Battle.net") ? L("Closing Battle.net first.") : L("Getting ready.") }
        let amount=progress.checking ? L("Checking the copy: {0} of {1}.",bytes(progress.bytes),bytes(progress.total))
                                     : L("Copying: {0} of {1}.",bytes(progress.bytes),bytes(progress.total))
        guard let seconds=progress.secondsLeft() else { return amount }
        return sentences(amount,seconds < 60 ? L("Less than a minute left.") : L("About {0} min left.",String((seconds+30)/60)))
    }
    @ViewBuilder private func done(_ result:MoveResult)->some View {
        SheetHero(symbol:"checkmark",title:L("Moved to “{0}”",InstallLocation.title(result.to)),
                  subtitle:L("Overwatch and Battle.net open from there now, with your settings and learned shaders."))
        let earlier=InstallLocation.driveName(result.from)
        if result.copied && result.trashed {
            LauncherNotice(text:result.bytes.map { L("The earlier copy is in the Trash. Empty the Trash to free {0} on “{1}”.",bytes($0),earlier) }
                           ?? L("The earlier copy is in the Trash. Empty the Trash to free its space on “{0}”.",earlier))
        } else if result.copied {
            LauncherNotice(text:L("The earlier copy couldn’t be moved to the Trash, so it’s still on “{0}”. Delete it in Finder to free its space.",earlier),
                           symbol:"exclamationmark.triangle",
                           action:(L("Show in Finder"),{ NSWorkspace.shared.activateFileViewerSelecting([result.from]) }))
        }
        if !InstallLocation.isInternal(result.to) {
            Text(L("Overwatch opens only while “{0}” is connected.",InstallLocation.driveName(result.to)))
                .font(LauncherStyle.font(12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
    private func row(_ name:String,_ value:String)->some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Text(name).font(LauncherStyle.font(13,.semibold)).frame(width:110,alignment:.leading)
            Text(value).font(LauncherStyle.font(13)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
