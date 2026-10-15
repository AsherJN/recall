import SwiftUI
import AppKit

struct SetupView: View {
    @Bindable var model:AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing:0) {
                    VStack(spacing:24) {
                        if model.screen == .welcome {
                            VStack(spacing:18) {
                                Wordmark(height:84)
                                Text(subtitle).font(LauncherStyle.font(16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        } else {
                            Wordmark(height:84,badge:model.screen == .failure ? (model.failure.code == "cancelled" ? "pause.fill" : "exclamationmark") : (model.screen == .driveMissing ? "externaldrive" : nil))
                            LauncherHeading(title:model.title,subtitle:subtitle)
                        }
                        details
                        VStack(spacing:12) { actions }
                        if !model.notice.isEmpty { LauncherNotice(text:model.notice) }
                        // Below Cancel, above the support card: collapsed to one line by default.
                        if model.screen == .launching && model.graphics.phase != nil { GraphicsDetails(progress:model.graphics) }
                    }.frame(maxWidth:LauncherStyle.contentWidth).padding(.top,model.screen == .welcome ? 28 : 34)
                    Spacer(minLength:28)
                    Group { if model.showsDiscord { DiscordLink() } else { GitHubHelpLink() } }
                        .frame(maxWidth:LauncherStyle.contentWidth).padding(.bottom,supportPlacement == nil ? 20 : 14)
                    if let placement=supportPlacement {
                        SupportCard(placement:placement).frame(maxWidth:LauncherStyle.contentWidth).padding(.bottom,20)
                    }
                    VersionStatus(model:model).padding(.bottom,12)
                    HStack(spacing:12) {
                        FooterTile(title:L("Settings"),symbol:"gearshape") { model.sheet = .settings }.disabled(model.screen == .moveApp)
                        FooterTile(title:L("Help & FAQ"),symbol:"questionmark.circle") { model.openHelp() }
                        FooterTile(title:L("About"),symbol:"info.circle") { model.sheet = .about }
                    }.frame(maxWidth:LauncherStyle.contentWidth).padding(.bottom,24)
                }.padding(.horizontal,36).frame(maxWidth:.infinity).frame(minHeight:geometry.size.height)
            }.scrollIndicators(.hidden)
        }
        .background { LauncherBackground() }
        .font(LauncherStyle.font(14)).tint(.primary)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.20),value:model.screen)
        .sheet(item:$model.sheet) { sheet in
            switch sheet {
            case .settings: SettingsSheet(model:model)
            case .help: HelpSheet(model:model)
            case .about: AboutSheet(model:model)
            case .uninstall: UninstallSheet(model:model).interactiveDismissDisabled(model.uninstall == .working)
            case .update: UpdateSheet(model:model).interactiveDismissDisabled(model.update == .installing)
                .onDisappear { model.updateSheetClosed() }
            case .whatsNew: WhatsNewSheet().onDisappear { model.whatsNewClosed() }
            case .shaderUpdate: ShaderUpdateSheet(model:model)
            case .china: ChinaBattleNetSheet(confirm:model.confirmBattleNet)
            case .changeRegion: ChangeRegionSheet(model:model).interactiveDismissDisabled(model.regionChange == .working)
            }
        }
        .task { model.startup() }
        // While the after-match status shows, look again every few seconds to see it finish.
        .task(id:model.showsAfterMatch) {
            while model.showsAfterMatch && !Task.isCancelled {
                try? await Task.sleep(for:.seconds(3))
                model.checkAfterMatch()
            }
        }
        .onChange(of:model.screen) { _,screen in if screen == .ready || screen == .running { model.checkAfterMatch() } }
    }
    /// Josh's support card, once Battle.net has opened for the first time.
    private var supportPlacement:Brand.Placement? {
        guard model.onboarded else { return nil }
        switch model.screen {
        case .ready: return .home
        case .running: return .running
        case .checking, .preparing, .launching: return .loading
        default: return nil
        }
    }
    private var subtitle:String {
        switch model.screen {
        case .welcome: return L("Set up Battle.net, then install Overwatch.")
        case .moveApp:
            if let copy=model.installedCopy { return L("Version {0} is in your Applications folder. Open it from there; this disk image is ejected for you.",copy.version) }
            return L("{0} runs from your Applications folder. It copies itself there, ejects this disk image and opens again.",Brand.name)
        case .checking: return L("Checking your installation and available storage.")
        case .battleNet: return L("{0} installs the Battle.net that matches your account.",Brand.name)
        case .readyToInstall: return model.clientInstalled ? L("Finish preparing your installation. Your game files and sign-in will be kept.") : L("Install the game components, then continue in Blizzard’s installer.")
        case .preparing: return model.stage.isEmpty ? L("Preparing your game environment.") : model.stage
        case .launching: return model.stage == L("Opening Battle.net") ? L("Waiting for its window to appear.") : model.stage
        case .installer: return L("Complete setup in the Battle.net installer.")
        case .running: return model.existingName == "Overwatch" ? L("Can’t find the game window? Choose Show Overwatch or check your other desktops.") : L("Play from the Battle.net window. Can’t find it? Choose Show Battle.net.")
        case .ready: return model.gameInstalled ? (AppModel.playEnabled ? L("Battle.net opens and starts Overwatch for you.") : L("Open Battle.net, select Overwatch and click Play.")) : L("Sign in to Battle.net and install Overwatch.")
        case .driveMissing: return L("Overwatch is installed on “{0}”. Connect the drive and this app picks up where it left off.",model.driveName)
        case .failure: return model.failure.message
        }
    }
    @ViewBuilder private var details:some View {
        switch model.screen {
        case .welcome:
            LauncherPanel {
                VStack(alignment:.leading,spacing:12) {
                    Text(L("Requirements")).font(LauncherStyle.font(14,.semibold))
                    VStack(alignment:.leading,spacing:8) {
                        requirement(L("Mac"), L("Apple Silicon · macOS 26.5 or later"))
                        requirement(L("Memory"), L("16 GB recommended"))
                        requirement(L("Storage"), L("85–95 GB free, on this Mac or an external SSD"))
                        requirement(L("Also"), L("Blizzard account, internet and Rosetta"))
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:5) {
                        Text(L("Recommended · tested setup")).font(LauncherStyle.font(13,.semibold))
                        Text(L("M1 Pro with 16 GB memory. Other Apple Silicon Macs may perform differently."))
                            .font(LauncherStyle.font(13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
        case .moveApp:
            if model.busy {
                HStack(spacing:12) {
                    ProgressView().controlSize(.small).accessibilityLabel(L("Moving"))
                    Text(model.stage).foregroundStyle(.secondary)
                }
            } else if model.installedCopy == nil && !model.moveReplaces.isEmpty {
                LauncherNotice(text:L("This replaces {0}, which moves to the Trash. Your game, settings and Battle.net sign-in are kept.",model.moveReplaces.formatted(.list(type:.and))))
            }
        case .checking:
            ProgressView().controlSize(.small).accessibilityLabel(L("Checking your Mac"))
        case .battleNet:
            battleNetPanel
        case .preparing:
            HStack(spacing:12) {
                ProgressView().controlSize(.small).accessibilityLabel(L("Setup in progress"))
                if model.downloadedBytes>0 {
                    Text(L("{0} downloaded",ByteCountFormatter.string(fromByteCount:Int64(model.downloadedBytes),countStyle:.file)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
        case .launching:
            TimelineView(.periodic(from:model.launchStarted,by:1)) { context in
                let seconds=max(0,Int(context.date.timeIntervalSince(model.launchStarted)))
                VStack(spacing:20) {
                    HStack(spacing:12) {
                        ProgressView().controlSize(.small).accessibilityLabel(L("Opening Battle.net"))
                        Text(L("{0} elapsed",String(format:"%d:%02d",seconds / 60,seconds % 60)))
                            .font(LauncherStyle.font(14,.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if seconds >= 30 {
                        Text(L("Taking longer than usual. Check the Dock for a Battle.net window."))
                            .font(LauncherStyle.font(13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    PerformanceTip()
                    if model.showKoreanTip { KoreanAccountTip(open:model.openAdvancedSettings) { model.koreanTipDismissed=true } }
                    if !model.firstMatchTipDismissed { FirstMatchTip { model.firstMatchTipDismissed=true } }
                }
            }
        case .readyToInstall:
            VStack(spacing:16) {
                if !model.clientInstalled { battleNetSummary }
                if model.canChangeLocation { locationPanel }
                if model.lowStorage { storageWarning }
                else if !model.gameInstalled && !model.canChangeLocation { Text(L("A new installation needs about 85–95 GB of free space.")).foregroundStyle(.secondary).font(LauncherStyle.font(13)) }
                if model.lowMemory && !model.gameInstalled { memoryWarning }
            }
        case .installer:
            // Blizzard's installer opens Battle.net without this app's renderer
            // settings, so its sign-in window can load blank until reopened here.
            LauncherNotice(text:L("When setup finishes, close any Battle.net window it opens. Then choose Continue here.\n\nIf the Battle.net sign-in window is blank or white, that’s expected at this step. Close it and choose Continue. This app reopens Battle.net with the right display settings, and you can sign in there."))
        case .failure:
            if model.failure.code == "rosetta_required" {
                Text(L("macOS will guide you through Apple’s installation.")).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
            }
        case .ready:
            VStack(spacing:16) {
                if model.lowStorage { storageWarning }
                if model.showsAfterMatch { AfterMatchStatus(progress:model.afterMatchProgress,updating:model.updatingShaderCache) } else { PerformanceTip() }
                if model.showKoreanTip { KoreanAccountTip(open:model.openAdvancedSettings) { model.koreanTipDismissed=true } }
                if !model.gameInstalled { SignInNote(model:model) }
                if !model.firstMatchTipDismissed { FirstMatchTip { model.firstMatchTipDismissed=true } }
            }
        case .running:
            VStack(spacing:16) {
                if model.existingName == "Overwatch" && model.gameWindowHidden { GameClosingNote() }
                if model.showsAfterMatch { AfterMatchStatus(progress:model.afterMatchProgress,updating:model.updatingShaderCache) } else { PerformanceTip() }
                if model.showKoreanTip { KoreanAccountTip(open:model.openAdvancedSettings) { model.koreanTipDismissed=true } }
                if !model.gameInstalled { SignInNote(model:model) }
                if !model.firstMatchTipDismissed { FirstMatchTip { model.firstMatchTipDismissed=true } }
            }
        case .driveMissing: EmptyView()
        }
    }
    /// Choose your Battle.net: the region and the language Battle.net installs in, both filled in
    /// from the Mac (BattleNetChoice.swift) and confirmed with Continue. China's Battle.net is
    /// Simplified Chinese only; going back to Global goes back to the Mac's language.
    private var battleNetPanel:some View {
        LauncherPanel {
            VStack(alignment:.leading,spacing:14) {
                Text(L("Which Battle.net do you play on?")).font(LauncherStyle.font(14,.semibold))
                VStack(spacing:8) { ForEach(BattleNetRegion.allCases) { regionOption($0) } }
                Divider()
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(L("Battle.net language")).font(LauncherStyle.font(14,.semibold))
                        Text(model.battleNetRegion == .china ? L("China’s Battle.net is in Simplified Chinese.") : L("Battle.net installs in this language. You can change it later in Battle.net’s settings."))
                            .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:8)
                    Picker(L("Battle.net language"),selection:$model.battleNetLanguage) {
                        ForEach(BattleNetLanguage.allCases) { Text(verbatim:$0.name).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(model.battleNetRegion == .china || model.busy)
                }
                Text(L("Accounts don’t carry over between Global and China’s Battle.net."))
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private func regionOption(_ region:BattleNetRegion) -> some View {
        let selected=model.battleNetRegion == region
        let shape=RoundedRectangle(cornerRadius:14,style:.continuous)
        return Button {
            guard region != model.battleNetRegion else { return }
            model.battleNetRegion=region
            model.battleNetLanguage = region == .china ? .simplifiedChinese : .suggested
        } label: {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:selected ? "checkmark.circle.fill" : "circle").font(.system(size:18))
                    .foregroundStyle(selected ? AnyShapeStyle(LauncherStyle.accent) : AnyShapeStyle(.secondary)).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2) {
                    Text(region.title).font(LauncherStyle.font(14,.semibold))
                    Text(region.detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(selected ? AnyShapeStyle(LauncherStyle.accent.opacity(0.10)) : AnyShapeStyle(.primary.opacity(0.04)),in:shape)
                .overlay { shape.strokeBorder(selected ? LauncherStyle.accent.opacity(0.6) : .clear,lineWidth:1.5) }
                .contentShape(shape)
        }.buttonStyle(.plain).disabled(model.busy).accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// The Battle.net setup installs, as chosen on the screen before; Change goes back to it.
    private var battleNetSummary:some View {
        LauncherPanel(inset:16) {
            HStack(alignment:.center,spacing:12) {
                VStack(alignment:.leading,spacing:2) {
                    Text(L("Battle.net")).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    Text(L("{0} · {1}",model.battleNetRegion.title,model.battleNetLanguage.name)).font(LauncherStyle.font(14,.semibold))
                }
                Spacer(minLength:8)
                Button(L("Change"),action:model.editBattleNet).buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(model.busy)
            }
        }
    }
    // Already filled in with the internal default: an optional change, not a
    // required decision. "Choose Another Location…" opens a folder picker.
    private enum LocationChoice: Hashable { case standard, current, other }
    private var locationPanel:some View {
        let choice=Binding<LocationChoice>(
            get: { InstallLocation.isStandard(model.root) ? .standard : .current },
            set: { value in
                switch value {
                case .standard: model.useLocation(InstallLocation.standard)
                case .other: DispatchQueue.main.async { model.chooseOtherLocation() }
                case .current: break
                }
            })
        return LauncherPanel {
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:12) {
                    Text(L("Install location")).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    Spacer(minLength:8)
                    Picker(L("Install location"),selection:choice) {
                        Label(InstallLocation.title(InstallLocation.standard),systemImage:"internaldrive").tag(LocationChoice.standard)
                        if !InstallLocation.isStandard(model.root) {
                            Label(InstallLocation.title(model.root),systemImage:InstallLocation.symbol(model.root)).tag(LocationChoice.current)
                        }
                        Divider()
                        Text(L("Choose Another Location…")).tag(LocationChoice.other)
                    }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(model.busy)
                        .help(model.root.path)
                }
                Text(L("Needs about 85–95 GB · {0} available",ByteCountFormatter.string(fromByteCount:Int64(model.freeBytes),countStyle:.file)))
                    .font(LauncherStyle.font(13)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
    private var storageWarning:some View {
        let free=ByteCountFormatter.string(fromByteCount:Int64(model.freeBytes),countStyle:.file)
        let has=InstallLocation.isStandard(model.root) ? L("Your Mac has {0} free.",free) : L("“{0}” has {1} free.",model.driveName,free)
        let fix=InstallLocation.isInternal(model.root)
            ? (model.canChangeLocation ? L("Free up space in System Settings › General › Storage, or choose another install location.") : L("Free up space in System Settings › General › Storage."))
            : (model.canChangeLocation ? L("Free up space on the drive, or choose another install location.") : L("Free up space on the drive."))
        return LauncherNotice(text:sentences(has,L("We recommend 85–95 GB for Overwatch and its updates. You can continue, but the download may stop if storage runs out."),fix),symbol:"exclamationmark.triangle")
    }
    private var memoryWarning:some View {
        LauncherNotice(text:L("Your Mac has {0} GB of memory. We recommend 16 GB. You can continue, but Overwatch may load slowly or stutter. Quitting other apps before you play helps.",String(model.memoryBytes>>30)),symbol:"exclamationmark.triangle")
    }
    private func requirement(_ title:String,_ value:String)->some View {
        HStack(alignment:.top,spacing:12) {
            Text(title).foregroundStyle(.secondary).frame(width:60,alignment:.leading)
            Text(value).frame(maxWidth:.infinity,alignment:.leading)
        }.font(LauncherStyle.font(13)).fixedSize(horizontal:false,vertical:true)
    }
    @ViewBuilder private var actions:some View {
        switch model.screen {
        case .welcome:
            LauncherPrimaryAction(title:L("Get Started"),action:model.check).keyboardShortcut(.defaultAction).disabled(model.busy)
        case .battleNet:
            LauncherPrimaryAction(title:L("Continue"),action:model.chooseBattleNet).keyboardShortcut(.defaultAction).disabled(model.busy)
        case .moveApp:
            if model.installedCopy != nil {
                LauncherPrimaryAction(title:L("Open {0}",Brand.name),action:model.openInstalledCopy).keyboardShortcut(.defaultAction).disabled(model.busy)
            } else {
                LauncherPrimaryAction(title:L("Move to Applications"),action:model.moveToApplications).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
            Button(L("Quit")) { model.quit() }.buttonStyle(.borderless).disabled(model.busy)
        case .readyToInstall:
            LauncherPrimaryAction(title:model.clientInstalled ? L("Finish Setup") : L("Install Battle.net"),action:model.setup).keyboardShortcut(.defaultAction).disabled(model.busy)
        case .checking: EmptyView()
        case .preparing:
            if model.canCancel { Button(L("Pause Setup"),action:model.cancel).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction) }
        case .launching:
            LauncherCancelAction(title:L("Cancel"),action:model.cancelLaunch).keyboardShortcut(.cancelAction).disabled(!model.canCancel)
        case .installer:
            LauncherPrimaryAction(title:L("Continue"),action:model.finishInstaller).keyboardShortcut(.defaultAction).disabled(model.busy)
        case .running:
            if model.existingName == "Battle.net" {
                BattleNetAction(title:L("Show Battle.net"),executable:model.battleNetExecutable,action:model.launch).keyboardShortcut(.defaultAction).disabled(model.busy)
            } else {
                LauncherPrimaryAction(title:L("Show {0}",L(model.existingName)),action:model.launch).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        case .ready:
            if AppModel.playEnabled && model.gameInstalled {
                LauncherPrimaryAction(title:L("Play Overwatch"),action:model.play).keyboardShortcut(.defaultAction).disabled(model.busy)
                Button(L("Open Battle.net"),action:model.launch).buttonStyle(.borderless).disabled(model.busy)
            } else {
                BattleNetAction(title:L("Open Battle.net"),executable:model.battleNetExecutable,action:model.launch).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        case .driveMissing:
            LauncherPrimaryAction(title:L("Try Again"),action:model.recheck).keyboardShortcut(.defaultAction).disabled(model.busy)
            Button(L("Set Up on This Mac Instead"),action:model.useThisMac).buttonStyle(.borderless).disabled(model.busy)
        case .failure:
            if model.failure.code == "rosetta_required" {
                LauncherPrimaryAction(title:L("Install Rosetta"),action:model.installRosetta).keyboardShortcut(.defaultAction).disabled(model.busy)
                Button(L("Check Again"),action:retry).buttonStyle(.borderless).disabled(model.busy)
            } else {
                LauncherPrimaryAction(title:model.failure.code == "cancelled" ? L("Resume Setup") : L("Try Again"),action:retry).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
    }
    private func retry() {
        if model.failure.code == "close_installer_client" { model.finishInstaller() }
        else if ["run_from_installed_app","app_move_failed","app_name_taken"].contains(model.failure.code) { model.moveToApplications() }
        else if model.failure.code == "install_location_unavailable" { model.recheck() }
        else if model.clientInstalled && model.state["prepared_runtime"] as? String != model.release?.runtimeVersion { model.setup() }
        else if model.clientInstalled { model.launch() }
        else if model.state["active_runtime"] != nil { model.setup() }
        else { model.check() }
    }
}

// The installed version and update status, above the footer. Quiet when up to
// date; an available update is one click away.
struct VersionStatus: View {
    @Bindable var model:AppModel
    var body:some View {
        HStack(spacing:6) {
            Text(L("Version {0}",UpdateCheck.installed))
            switch model.update {
            case .available(let item):
                Text("·")
                Button { model.sheet = .update } label: {
                    Label { Text(L("Update to {0}",item.version)).fontWeight(.semibold) } icon: { Image(systemName:"arrow.down.circle.fill").foregroundStyle(LauncherStyle.accent) }
                }.buttonStyle(.borderless).foregroundStyle(.primary).help(L("See what’s new and install the update"))
            case .downloading, .installing:
                Text("·")
                Button(L("Updating…")) { model.sheet = .update }.buttonStyle(.borderless)
            case .upToDate:
                Text("·");Text(L("Up to date"))
            default: EmptyView()
            }
            Text("·")
            Button(L("What’s New")) { model.sheet = .whatsNew }.buttonStyle(.borderless)
        }.font(LauncherStyle.font(12)).foregroundStyle(.secondary)
    }
}
// Every launch: other apps compete with Overwatch for the GPU, CPU and memory; players
// who kept theirs open reported stutters.
struct PerformanceTip: View {
    var body:some View {
        Label(L("For the best performance, close other apps while you play."),systemImage:"bolt")
            .font(LauncherStyle.font(13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .fixedSize(horizontal:false,vertical:true)
    }
}
// Shown until dismissed on the Play, opening and running screens, from the first
// session (while Overwatch downloads): first matches compile the game's shaders on
// this Mac.
struct FirstMatchTip: View {
    /// A community custom game that shows Overwatch's effects in a few minutes, so
    /// the Mac builds their shaders before a real match.
    static let workshopCode="929PJ"
    let dismiss:()->Void
    @State private var copied=false
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            Label {
                VStack(alignment:.leading,spacing:10) {
                    Text(L("Your first matches can stutter briefly while your Mac prepares Overwatch’s graphics. To get ahead of it, play Workshop code {0} once from Custom Games before you queue.",Self.workshopCode))
                        .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                    HStack(spacing:10) {
                        Button(copied ? L("Copied") : L("Copy Code")) {
                            NSPasteboard.general.clearContents();NSPasteboard.general.setString(Self.workshopCode,forType:.string);copied=true
                        }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                            .accessibilityLabel(copied ? L("Copied") : L("Copy Workshop code {0}",Self.workshopCode))
                        Text(L("Shader warm-up by u/Working_Dealer_5102")).font(LauncherStyle.font(12)).foregroundStyle(.tertiary)
                    }
                }
            } icon: { Image(systemName:"sparkles") }
            Spacer(minLength:0)
            Button(action:dismiss) { Image(systemName:"xmark").font(.system(size:11,weight:.bold)).frame(width:22,height:22).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Dismiss this tip")).accessibilityLabel(L("Dismiss tip"))
        }.font(LauncherStyle.font(13)).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(LauncherStyle.accent.opacity(0.09),in:RoundedRectangle(cornerRadius:16,style:.continuous))
            .task(id:copied) { if copied { try? await Task.sleep(for:.seconds(2));copied=false } }
    }
}
// Overwatch is running with its window out of sight (AppModel.gameWindowHidden): usually
// still closing after Exit to Desktop. Force Quit asks first (AppDelegate.forceQuit).
struct GameClosingNote: View {
    var body:some View {
        LauncherNotice(text:L("Just exited Overwatch? It can take up to a minute to close after its window goes away. If it doesn’t, choose Force Quit."),
                       symbol:"hourglass",action:(L("Force Quit…"),{ NSApp.sendAction(#selector(AppDelegate.forceQuit),to:nil,from:nil) }))
    }
}
// Before Overwatch is installed, while the player signs in to Battle.net (issue #33). China's
// Battle.net signs in with a NetEase account through the browser, with the same hand-off back.
struct SignInNote: View {
    let model:AppModel
    var body:some View {
        if model.battleNetRegion == .china {
            LauncherNotice(text:L("Signing in with NetEase? If Battle.net keeps waiting after your browser says to return, see Help › Troubleshooting."),
                           symbol:"person.badge.key",action:(L("Open Help"),{ model.openHelp(.troubleshooting,topic:"netease") }))
        } else {
            LauncherNotice(text:L("Signing in with Xbox? If Battle.net keeps waiting after your browser says to return, see Help › Troubleshooting."),
                           symbol:"person.badge.key",action:(L("Open Help"),{ model.openHelp(.troubleshooting,topic:"xbox") }))
        }
    }
}
// Korean accounts linked to Nexon need Korean account support (Settings › Advanced). Shown
// on the Play, opening and running screens once the game folder holds Nexon's files and the
// option is off, until dismissed; the option itself stays in Settings either way. In Korean
// too, since Recall has no Korean interface yet.
struct KoreanAccountTip: View {
    let open:()->Void
    let dismiss:()->Void
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            Label {
                VStack(alignment:.leading,spacing:10) {
                    Text(L("Playing on a Korean account linked to Nexon? Turn on Korean account support in Settings › Advanced."))
                        .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                    Text("넥슨과 연동된 한국 계정으로 플레이하시나요? 설정 › 고급에서 한국 계정 지원을 켜세요.")
                        .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                    Button(L("Open Settings 설정 열기"),action:open).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                }
            } icon: { Image(systemName:"person.crop.circle.badge.questionmark") }
            Spacer(minLength:0)
            Button(action:dismiss) { Image(systemName:"xmark").font(.system(size:11,weight:.bold)).frame(width:22,height:22).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Dismiss this tip")).accessibilityLabel(L("Dismiss tip"))
        }.font(LauncherStyle.font(13)).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(LauncherStyle.accent.opacity(0.09),in:RoundedRectangle(cornerRadius:16,style:.continuous))
    }
}
// The footer's three destinations, sized as buttons.
struct FooterTile: View {
    let title:String
    let symbol:String
    let action:()->Void
    var body:some View {
        Button(action:action) {
            VStack(spacing:6) {
                Image(systemName:symbol).font(.system(size:18,weight:.medium)).accessibilityHidden(true)
                Text(title).font(LauncherStyle.font(12,.semibold))
            }.frame(maxWidth:.infinity,minHeight:58)
        }.buttonStyle(FooterTileStyle())
    }
}
private struct FooterTileStyle: ButtonStyle {
    func makeBody(configuration:Configuration)->some View { FooterTileBody(configuration:configuration) }
}
private struct FooterTileBody: View {
    let configuration:ButtonStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering=false
    var body:some View {
        configuration.label.foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background(LauncherStyle.surface(scheme).opacity(hovering ? 1 : 0.72),in:RoundedRectangle(cornerRadius:16,style:.continuous))
            .overlay { RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(focused ? Color.primary.opacity(0.8) : Color.primary.opacity(hovering ? 0.16 : 0.08),lineWidth:focused ? 2 : 1) }
            .contentShape(RoundedRectangle(cornerRadius:16,style:.continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering=$0 }
    }
}
