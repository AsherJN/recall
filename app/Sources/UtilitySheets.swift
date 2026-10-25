import SwiftUI
import AppKit

/// Settings' categories, in tabs across the top: everyday choices first, rarely needed ones in
/// Advanced. Settings reopens on the tab shown last (AppModel.settingsTab).
enum SettingsTab:String, CaseIterable, Identifiable {
    case general, display, graphics, audio, advanced
    var id:String { rawValue }
    var title:String {
        switch self {
        case .general: return L("General")
        case .display: return L("Display")
        case .graphics: return L("Graphics")
        case .audio: return L("Audio")
        case .advanced: return L("Advanced")
        }
    }
    var symbol:String {
        switch self {
        case .general: return "gearshape"
        case .display: return "display"
        case .graphics: return "cube"
        case .audio: return "speaker.wave.2"
        case .advanced: return "gearshape.2"
        }
    }
}
// Updates, the display setting the app owns, what Battle.net and Overwatch start with, and
// recovery actions, in tabs. Driver tuning is deliberately absent: FPS, quality and
// sensitivity live in Overwatch.
struct SettingsSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForceQuit=false
    @State private var confirmRepair=false
    @State private var confirmResetDisplay=false
    @State private var confirmDeleteShaders=false
    @State private var confirmKorean=false
    @State private var aboutUpscaling=false
    /// Logging: the setting waiting for the FPS warning's Turn On, and Custom's text being typed.
    @State private var confirmLogging:LoggingSetting?
    @State private var customDraft:String?
    /// Shader memory's slider: how many of the shader cache's parts Overwatch loads.
    @State private var shaderParts=1.0
    /// Follows System Settings: the main display can change while Settings is open.
    @State private var main=MainDisplay.current
    /// Also follows System Settings, where the player turns the microphone on or off.
    @State private var microphoneAccess=Microphone.access
    /// And Input Monitoring, for the high-precision mouse, which explains itself before it's chosen.
    @State private var inputMonitoring=InputMonitoring.access
    @State private var explainHighPrecision=false
    var body:some View {
        VStack(spacing:16) {
            LauncherHeading(title:L("Settings"),subtitle:"",compact:true)
            LauncherTabs(tabs:SettingsTab.allCases,selection:$model.settingsTab,title:\.title,symbol:\.symbol)
            // One size on every tab, so the tabs, Done and Uninstall never move. The page sits
            // under the tabs; a page (or a page and a notice) taller than the room scrolls.
            ScrollView {
                VStack(spacing:12) {
                    page
                    if !model.notice.isEmpty { LauncherNotice(text:model.notice) }
                }
            }.scrollBounceBehavior(.basedOnSize).frame(maxHeight:.infinity,alignment:.top)
            HStack {
                // Uninstall lives here, always visible and apart from the
                // everyday settings; it opens its own confirmation.
                Button(role:.destructive) { model.sheet = .uninstall } label: {
                    Label(L("Uninstall {0}…",Brand.name),systemImage:"trash").font(LauncherStyle.font(13,.medium))
                }.buttonStyle(.borderless).foregroundStyle(.red).disabled(model.uninstall == .working)
                    .help(L("Move {0}, Battle.net and Overwatch to the Trash",Brand.name))
                Spacer()
                Button(L("Done")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
            }
        }.font(LauncherStyle.font(14)).padding(.horizontal,32).padding(.vertical,28)
            .frame(width:LauncherStyle.sheetWidth,height:LauncherStyle.largeSheetHeight)
            .tint(.primary).background { LauncherBackground() }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification)) { _ in
                main=MainDisplay.current
                model.refreshDisplay()
            }
            // Battle.net or Overwatch may have opened or closed while the player was away,
            // and the microphone been turned on or off in System Settings.
            .onAppear { model.checkRunning() }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in
                model.checkRunning();microphoneAccess=Microphone.access;inputMonitoring=InputMonitoring.access
            }
            .alert(L("Force quit Overwatch and Battle.net?"),isPresented:$confirmForceQuit) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Force Quit"),role:.destructive,action:model.forceQuit)
            } message: { Text(L("Use this when the game stops responding. If you’re in a match, you’ll leave it.")) }
            .alert(L("Repair game files?"),isPresented:$confirmRepair) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Repair"),action:model.repair)
            } message: { Text(L("Overwatch and Battle.net must be closed. This reinstalls the files this app adds and refreshes the Windows environment. Overwatch, its settings and your Battle.net sign-in are kept.")) }
            .sheet(isPresented:$confirmKorean) { KoreanSupportSheet { model.chooseRegion(.korea) } }
            .sheet(isPresented:$explainHighPrecision) {
                HighPrecisionMouseSheet(discord:model.showsDiscord) {
                    model.mouseInput = .highPrecision
                    if inputMonitoring == .undecided { InputMonitoring.ask() }
                }
            }
            .alert(L("Reset display settings?"),isPresented:$confirmResetDisplay) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Reset"),action:model.resetDisplay)
            } message: { Text(model.rememberEachDisplay ? L("Overwatch will open full screen at {0} on this display the next time it starts. Your graphics quality and FPS settings stay as they are.",DisplayResolution.initial(for:main).label)
                                                         : L("Overwatch will open full screen at {0} the next time it starts. Your graphics quality and FPS settings stay as they are.",DisplayResolution.initial(for:main).label)) }
            .alert(L("Turn on logging?"),isPresented:Binding(get:{ confirmLogging != nil },set:{ if !$0 { confirmLogging=nil } })) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Turn On")) { if let next=confirmLogging { turnOnLogging(next) } }
            } message: { Text(L("Logging can lower your FPS while it’s on. {0} shows a reminder on its home screen until you turn it off.",Brand.name)) }
            .alert(L("Clear shader cache?"),isPresented:$confirmDeleteShaders) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Clear"),role:.destructive,action:model.deleteShaders)
            } message: { Text(clearShaderCacheMessage) }
    }
    @ViewBuilder private var page:some View {
        switch model.settingsTab {
        case .general:
            updates
            battleNet
            mouse
            if model.otherInstallation != nil { otherInstallation }
        case .display:
            display
            resetDisplay
        case .graphics:
            upscaling
            metalHUD
            gameModeSetting
            shaderMemory
            clearShaderCache
        case .audio:
            microphone
            sound
        case .advanced:
            troubleshooting
            logs
            advanced
        }
    }
    private var updates:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(L("Updates")).font(LauncherStyle.font(14,.semibold))
                        Text(L("{0} · Nothing about you or your Mac is sent.",status)).font(LauncherStyle.font(12))
                            .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:12)
                    if case .available=model.update {
                        Button(L("Update…")) { model.sheet = .update }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(LauncherStyle.accent)
                            .foregroundStyle(LauncherStyle.ink)
                    } else {
                        Button(L("Check Now")) { model.checkForUpdates(manual:true,present:false) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .disabled(model.update == .checking || model.update == .installing)
                    }
                }
                Divider().padding(.vertical,6)
                SettingSwitch(title:L("Check for updates automatically"),isOn:$model.automaticUpdates)
            }
        }
    }
    private var status:String {
        switch model.update {
        case .available(let item): return L("Version {0} is available",item.version)
        case .upToDate: return L("Version {0} · up to date",UpdateCheck.installed)
        case .checking: return L("Checking…")
        case .downloading, .installing: return L("Updating…")
        case .failed: return L("Couldn’t reach GitHub; check your connection")
        default: return L("Version {0}",UpdateCheck.installed)
        }
    }
    private var battleNet:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                SettingSwitch(title:L("Open Battle.net when {0} opens",Brand.name),detail:L("Turn off to start Battle.net yourself with Open Battle.net."),
                              isOn:$model.autoOpenBattleNet)
                // Global, Korea or China's Battle.net (BattleNetChoice.swift, AppModel.chooseRegion):
                // Korea asks first; to or from China, setup starts again. Battle.net carries Korean
                // account support from when it opens, so the region changes while it's closed.
                if model.clientInstalled {
                    Divider().padding(.vertical,6)
                    HStack(alignment:.center,spacing:12) {
                        VStack(alignment:.leading,spacing:2) {
                            Text(L("Battle.net region")).font(LauncherStyle.font(14,.semibold))
                            Text(model.installedRegion.detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:12)
                        Picker(L("Battle.net region"),selection:Binding(get:{ model.installedRegion },set:{ next in
                            if next == .korea && model.installedRegion == .global { confirmKorean=true } else { model.chooseRegion(next) }
                        })) {
                            ForEach(BattleNetRegion.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                            .disabled(model.busy || model.uninstall == .working || model.running != nil)
                    }
                    if let running=model.running { closeFirst(running,several:false) }
                }
            }
        }
    }
    /// How Overwatch gets the mouse (AppModel.MouseInput; REC-52, REC-57): one of three. Overwatch's
    /// window driver reads it as Battle.net opens, so like the HUD it changes while Battle.net is
    /// closed. High-precision is experimental: choosing it first explains it and why macOS will ask
    /// for Input Monitoring (HighPrecisionMouseSheet), whose Continue chooses it and shows macOS's
    /// prompt the first time. Until the player allows it in System Settings, the mouse works as
    /// Standard does and the panel says what to do; while it's chosen, the panel asks for feedback.
    private var mouse:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                VStack(alignment:.leading,spacing:2) {
                    Text(L("Mouse")).font(LauncherStyle.font(14,.semibold))
                    Text(L("How Overwatch gets your mouse’s movement and clicks.")).font(LauncherStyle.font(12))
                        .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                VStack(alignment:.leading,spacing:10) {
                    MouseChoice(title:L("Standard"),detail:L("Clicks and movement reach Overwatch together, for precise aim."),
                                selected:model.mouseInput == .standard,disabled:model.running != nil) { model.mouseInput = .standard }
                    MouseChoice(title:L("Classic"),detail:L("The mouse as it worked in {0} 1.4. Try it if your mouse feels different since 1.5.",Brand.name),
                                selected:model.mouseInput == .classic,disabled:model.running != nil) { model.mouseInput = .classic }
                    MouseChoice(title:L("High-precision"),detail:L("Overwatch reads every movement straight from your mouse. Needs Input Monitoring."),
                                experimental:true,selected:model.mouseInput == .highPrecision,disabled:model.running != nil) {
                        if model.mouseInput != .highPrecision { explainHighPrecision=true }
                    }
                }.padding(.top,8)
                if model.mouseInput == .highPrecision {
                    if inputMonitoring != .allowed {
                        HStack(spacing:12) {
                            Text(L("Needs Input Monitoring: turn on {0} in System Settings › Privacy & Security › Input Monitoring. Until then, the mouse works as Standard does.",Brand.name))
                                .font(LauncherStyle.font(12,.medium)).fixedSize(horizontal:false,vertical:true)
                            Spacer(minLength:8)
                            Button(L("Open System Settings")) { NSWorkspace.shared.open(InputMonitoring.privacySettings) }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }.padding(.top,6)
                    }
                    HStack(spacing:16) {
                        Text(L("How does it feel?")).font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                        MouseFeedbackLinks(discord:model.showsDiscord)
                    }.padding(.top,6)
                }
                if let running=model.running { closeFirst(running,several:false) }
            }
        }
    }
    /// REC-44: the installation the player moved away from, after setup here has gone past the
    /// setup screens that offer it.
    private var otherInstallation:some View {
        let name=model.otherInstallation.map(InstallLocation.driveName) ?? ""
        return LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(L("Install location")).font(LauncherStyle.font(14,.semibold))
                        Text(L("Your installation on “{0}” is still there.",name)).font(LauncherStyle.font(12))
                            .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:12)
                    Button(L("Use “{0}”…",name),action:model.chooseOtherInstallation).buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(model.busy || model.uninstall == .working || model.running != nil)
                }
                if let running=model.running { closeFirst(running,several:false) }
            }
        }
    }
    /// Overwatch's own Video settings are where players usually change resolution; Recall
    /// keeps their choice. This shows it, with sizes for players who set it from here.
    private var display:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:12) {
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(L("Fullscreen resolution")).font(LauncherStyle.font(14,.semibold))
                        Text(L("Set it in game under Options › Video, or here."))
                            .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:8)
                    Text(model.resolution.label).font(LauncherStyle.font(13,.medium)).monospacedDigit()
                }.accessibilityElement(children:.combine)
                displayOptions
            }
        }
    }
    private var displayOptions:some View {
        // A size chosen in Overwatch that Settings doesn't list selects nothing here;
        // the sizes shown are then those in the main display's shape.
        let current=model.resolution
        let shape=current.isSupported ? current.shape : DisplayResolution.initial(for:main).shape
        return VStack(alignment:.leading,spacing:12) {
            if let main {
                mainDisplay(main)
                if let note=main.scalingNote {
                    LauncherNotice(text:note,symbol:"exclamationmark.triangle",action:(L("Open Display Settings"),Self.openDisplaySettings))
                }
            }
            Text(L("Overwatch opens on the main display, the one with the menu bar. To use another, choose Displays… and set it as the main display."))
                .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:10) {
                GridRow {
                    Text(L("Shape")).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    HStack(spacing:8) {
                        choice(L("16:10 · MacBook"),selected:current.isSupported && current.shape == .macBook) {
                            model.chooseResolution(DisplayResolution(shape:.macBook,size:current.size))
                        }
                        choice(L("16:9 · Monitor & TV"),selected:current.isSupported && current.shape == .monitor) {
                            model.chooseResolution(DisplayResolution(shape:.monitor,size:current.size))
                        }
                    }
                }
                GridRow {
                    Text(L("Size")).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    HStack(spacing:8) {
                        ForEach(DisplayResolution.Size.allCases,id:\.self) { size in
                            let option=DisplayResolution(shape:shape,size:size)
                            choice(option.label,selected:current == option,dimmed:main.map { !$0.fits(option) } ?? false) {
                                model.chooseResolution(option)
                            }.help(main.map { $0.fits(option) } ?? true ? "" : L("Larger than your main display can show"))
                        }
                    }
                }
            }
            Text(caption).font(LauncherStyle.font(13)).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:6) {
                if model.displaySaved {
                    Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text(L("Saved")).font(LauncherStyle.font(12,.medium))
                    Text("·").foregroundStyle(.secondary)
                }
                Text(model.rememberEachDisplay ? L("Changes save for this display and apply the next time Overwatch starts.") : L("Changes save as you choose and apply the next time Overwatch starts."))
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.font(LauncherStyle.font(12)).animation(.easeOut(duration:0.15),value:model.displaySaved)
            Divider().padding(.vertical,2)
            SettingSwitch(title:L("Remember a resolution for each display"),detail:L("Your MacBook screen and each monitor open at the resolution you last used on them."),
                          isOn:Binding(get:{ model.rememberEachDisplay },set:{ model.setRememberEachDisplay($0) }),disabled:model.busy)
        }
    }
    private func mainDisplay(_ main:MainDisplay) -> some View {
        HStack(spacing:12) {
            Image(systemName:main.builtIn ? "laptopcomputer" : "display").font(.system(size:20)).foregroundStyle(.secondary).frame(width:30)
            VStack(alignment:.leading,spacing:2) {
                Text(main.name).font(LauncherStyle.font(14,.medium)).lineLimit(1)
                Text(L("Main display · {0} · {1}",main.size,main.aspect)).font(LauncherStyle.font(12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength:8)
            Button(L("Displays…"),action:Self.openDisplaySettings).buttonStyle(.bordered).buttonBorderShape(.capsule).help(L("Open System Settings › Displays"))
        }.padding(12).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:14,style:.continuous))
            .accessibilityElement(children:.combine)
    }
    static func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
    private func choice(_ title:String, selected:Bool, dimmed:Bool=false, _ action:@escaping ()->Void) -> some View {
        Button(action:action) {
            Text(title).font(LauncherStyle.font(13,selected ? .semibold : .medium)).monospacedDigit().lineLimit(1)
                .padding(.horizontal,12).frame(height:30)
                .foregroundStyle(selected ? LauncherStyle.ink : (dimmed ? .secondary : .primary))
                .background(selected ? AnyShapeStyle(LauncherStyle.accent) : AnyShapeStyle(.primary.opacity(0.06)),in:Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).disabled(model.busy).accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// What the player will see with the current resolution on the main display.
    private var caption:String {
        let choice=model.resolution
        let source=choice.isSupported ? "" : L("{0} was chosen in Overwatch.",choice.label)
        guard let main else { return sentences(source,L("Larger sizes look sharper and lower your frame rate.")) }
        return sentences(source,main.caption(for:choice))
    }
    private var resetDisplay:some View {
        LauncherPanel(inset:16) {
            action(L("Reset Display Settings…"),detail:L("If Overwatch opens to a black screen or at the wrong size."),button:L("Reset")) { confirmResetDisplay=true }
        }
    }
    /// MetalFX upscaling and its sharpening. Battle.net carries both from when it opens, like
    /// the HUD; sharpening applies only with upscaling on, so it waits until then.
    private var upscaling:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                SettingSwitch(title:L("MetalFX upscaling"),detail:L("Adds NVIDIA DLSS to Overwatch’s Video options. Recall runs it on Apple’s MetalFX."),
                              isOn:$model.metalFXUpscaling,disabled:model.running != nil) {
                    Text(L("New")).font(LauncherStyle.font(12,.semibold)).foregroundStyle(LauncherStyle.accent)
                    Button { aboutUpscaling=true } label: {
                        Image(systemName:"info.circle").font(.system(size:14))
                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help(L("About MetalFX upscaling")).accessibilityLabel(L("About MetalFX upscaling"))
                        .infoPopover(isPresented:$aboutUpscaling) { MetalFXInfo() }
                }
                Divider().padding(.vertical,6)
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(L("Sharpening")).font(LauncherStyle.font(14,.semibold))
                            .foregroundStyle(model.metalFXUpscaling ? .primary : .secondary)
                        Text(model.metalFXUpscaling ? L("Makes the upscaled picture crisper.") : L("Available with MetalFX upscaling on."))
                            .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:12)
                    Picker(L("Sharpening"),selection:$model.metalFXSharpening) {
                        Text(L("Off")).tag(AppModel.Sharpening.off)
                        Text(L("Low")).tag(AppModel.Sharpening.low)
                        Text(L("High")).tag(AppModel.Sharpening.high)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        .disabled(!model.metalFXUpscaling || model.running != nil)
                }
                if let running=model.running { closeFirst(running,several:true) }
            }
        }
    }
    /// Overwatch gets the HUD from Battle.net, which starts it; so the switch changes only
    /// while Battle.net is closed, and Settings offers to close it.
    private var metalHUD:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                SettingSwitch(title:L("Metal Performance HUD"),
                              detail:L("Shows Apple’s performance overlay in Overwatch: FPS, frame times, and when your Mac is compiling shaders, the cause of first-match stutters."),
                              isOn:$model.metalHUD,disabled:model.running != nil)
                if let running=model.running { closeFirst(running,several:false) }
            }
        }
    }
    /// macOS Game Mode (AppModel.gameMode; on by default). Overwatch gets it from Battle.net,
    /// which starts it, so like the HUD it changes only while Battle.net is closed.
    private var gameModeSetting:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                SettingSwitch(title:L("Game Mode"),
                              detail:L("macOS gives Overwatch priority on your Mac’s processor and graphics while it fills the screen, and holds back other apps."),
                              isOn:$model.gameMode,disabled:model.running != nil)
                if let running=model.running { closeFirst(running,several:false) }
            }
        }
    }
    /// How much of the shader cache Overwatch loads when it starts (ShaderMemory): its parts
    /// load in order, slowest shaders first, and the slider picks how many. Overwatch reads the
    /// choice as it starts, so it can change while Battle.net or the game is open.
    private var shaderMemory:some View {
        let parts=model.shaderPack
        let count=parts.count > 1 ? Int(shaderParts) : parts.count
        let loaded=parts.prefix(count),total=parts.reduce(0) { $0+$1.shaders }
        let shaders=loaded.reduce(0) { $0+$1.shaders }
        let bytes=loaded.reduce(Int64(0)) { $0+$1.bytes }
        let caption=parts.isEmpty ? L("{0} builds your shader cache after your first match.",Brand.name)
            : count >= parts.count ? L("Loads all {0} shaders.",total.formatted())
            : count == 1 ? L("Loads the {0} slowest shaders, as earlier versions did. The rest come from macOS’s shader cache.",shaders.formatted())
            : L("Loads {0} of {1} shaders, slowest first. The rest come from macOS’s shader cache.",shaders.formatted(),total.formatted())
        return LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:10) {
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(L("Shader memory")).font(LauncherStyle.font(14,.semibold))
                        Text(L("How much of your shader cache Overwatch loads when it starts. All of it means the fewest stutters."))
                            .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:12)
                    if !parts.isEmpty {
                        Text(ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)).font(LauncherStyle.font(13,.medium)).monospacedDigit()
                    }
                }.accessibilityElement(children:.combine)
                if parts.count > 1 {
                    HStack(spacing:10) {
                        Text(L("Slowest only")).font(LauncherStyle.font(12)).foregroundStyle(.secondary).accessibilityHidden(true)
                        Slider(value:$shaderParts,in:1...Double(parts.count),step:1) {
                            Text(L("Shader memory"))
                        } onEditingChanged: { editing in
                            if !editing { model.chooseShaderMemory(ShaderMemory.choice(loading:Int(shaderParts),of:parts)) }
                        }.labelsHidden().tint(LauncherStyle.accent).accessibilityValue(caption)
                        Text(L("All")).font(LauncherStyle.font(12)).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
                Text(caption).font(LauncherStyle.font(13)).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                Text(sentences(model.running == .game ? L("Applies the next time Overwatch starts.") : "",
                               L("Only lower this if your Mac runs short of memory during matches; it’s meant for Macs with 8 GB.")))
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }.onAppear {
            model.loadShaderPack()
            shaderParts=Double(max(1,ShaderMemory.loaded(model.shaderMemory,model.shaderPack)))
        }
    }
    /// Clear Shader Cache, under Shader memory (owner, October 17; from @dagadtwok's pull
    /// request, #37): for crashes and glitches a damaged cache can cause. Its confirmation says
    /// how much goes and what the next matches are like. Battle.net and Overwatch must be closed,
    /// and a preparation after a match left to finish; with nothing saved yet there's nothing to clear.
    private var clearShaderCache:some View {
        let empty=model.shaderCacheBytes.map { $0 < 1<<20 } ?? false
        return LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                action(L("Clear Shader Cache…"),detail:empty ? L("Nothing to clear yet.") : L("If Overwatch crashes or shows graphics glitches."),button:L("Clear"),
                       disabled:empty || model.running != nil || model.preparingAfterMatch) { confirmDeleteShaders=true }
                if let running=model.running { closeFirst(running,several:false,clearing:true) }
                else if model.preparingAfterMatch && !empty {
                    Text(L("Available once {0} finishes preparing shaders.",Brand.name))
                        .font(LauncherStyle.font(12,.medium)).fixedSize(horizontal:false,vertical:true).padding(.top,6)
                }
            }
        }.onAppear { model.measureShaderCache();model.checkAfterMatch() }
    }
    private var clearShaderCacheMessage:String {
        let rebuild=L("Your next few matches will stutter again while your Mac relearns them. Your game files and settings stay as they are.")
        guard let bytes=model.shaderCacheBytes,bytes >= 1<<20 else { return sentences(L("{0} will delete the shaders it has saved for Overwatch.",Brand.name),rebuild) }
        return sentences(L("{0} will delete the {1} of shaders it has saved for Overwatch.",Brand.name,ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)),rebuild)
    }
    /// A setting Battle.net carries from when it opens: change it once it's closed.
    private func closeFirst(_ running:AppModel.Running, several:Bool, clearing:Bool=false) -> some View {
        HStack(spacing:12) {
            Text(clearing ? (running == .game ? L("Quit Overwatch and close Battle.net to clear it.") : L("Close Battle.net to clear it."))
                 : running == .game ? (several ? L("Quit Overwatch to change these.") : L("Quit Overwatch to change this."))
                                  : (several ? L("Close Battle.net to change these.") : L("Close Battle.net to change this.")))
                .font(LauncherStyle.font(12,.medium)).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:8)
            if running == .client {
                Button(L("Close Battle.net"),action:model.closeBattleNet).buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(model.busy)
            }
        }.padding(.top,6)
    }
    /// macOS lets only the player switch the permission, in System Settings, which then
    /// asks to reopen the app; the button opens that switch (or, before the first answer,
    /// shows macOS's prompt). With Bluetooth headphones the worker picks the Mac's own
    /// microphone at launch (portable_voice.h).
    private var microphone:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(L("Microphone")).font(LauncherStyle.font(14,.semibold))
                        Text(microphoneDetail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:12)
                    Button(microphoneAccess == .allowed ? L("Turn Off…") : microphoneAccess == .denied ? L("Turn On…") : L("Allow…")) {
                        guard microphoneAccess == .undecided else { NSWorkspace.shared.open(Microphone.privacySettings);return }
                        Task { await Microphone.ask();microphoneAccess=Microphone.access }
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .help(microphoneAccess == .undecided ? L("Shows macOS’s microphone prompt") : L("Opens Privacy & Security › Microphone in System Settings"))
                }
                Divider().padding(.vertical,6)
                note(L("Bluetooth headphones"),L("With AirPods or other Bluetooth headphones, voice chat uses your Mac’s built-in microphone when it’s available. Their own microphone would switch them to a lower-quality mode for all sound."))
            }
        }
    }
    private var microphoneDetail:String {
        switch microphoneAccess {
        case .allowed: return L("On. Your team can hear you in voice chat.")
        case .denied: return L("Off. Your team can’t hear you in voice chat.")
        case .undecided: return L("Lets your team hear you in voice chat.")
        }
    }
    /// Wine follows the Mac's sound output while Overwatch runs (wine-audio-devices.patch, 1.6).
    private var sound:some View {
        LauncherPanel(inset:16) {
            note(L("Speakers and headphones"),L("Overwatch plays through the sound output selected on your Mac. You can connect headphones or switch outputs at any time, even during a match."))
        }
    }
    private func note(_ title:String,_ text:String) -> some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(LauncherStyle.font(14,.semibold))
            Text(text).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.accessibilityElement(children:.combine)
    }
    private var troubleshooting:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:10) {
                Text(L("Troubleshooting")).font(LauncherStyle.font(14,.semibold))
                action(L("Force Quit Overwatch & Battle.net"),detail:L("If the game stops responding."),button:L("Force Quit")) { confirmForceQuit=true }
                action(L("Repair Game Files…"),detail:L("If Overwatch won’t start. Takes a minute or two."),button:L("Repair")) { confirmRepair=true }
            }
        }
    }
    /// Logging (LoggingSetting) and Save Logs (LogBundle). Battle.net carries the setting from when it
    /// opens, so it changes while Battle.net is closed; turning it on warns about FPS first. Any mix of
    /// presets can be on (REC-51). Custom takes Wine's own text, checked as it's typed, and joins the
    /// setting once its text is turned on. Save Logs works any time, logging on or off.
    private var logs:some View {
        let locked=model.running != nil || !model.canChangeAdvanced
        return LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                VStack(alignment:.leading,spacing:2) {
                    Text(L("Logging")).font(LauncherStyle.font(14,.semibold))
                    Text(sentences(L("Records more of what Battle.net and Overwatch do, for a bug report. Turn on any of these."),L("Can lower your FPS while it’s on.")))
                        .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }.accessibilityElement(children:.combine)
                VStack(alignment:.leading,spacing:8) {
                    ForEach(LoggingPreset.allCases) { preset in
                        Toggle(isOn:Binding(get:{ shows(preset) },set:{ choose(preset,on:$0) })) {
                            VStack(alignment:.leading,spacing:1) {
                                Text(preset.title).font(LauncherStyle.font(13,.medium))
                                Text(preset.detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            }
                        }.toggleStyle(.checkbox).disabled(locked)
                        if preset == .custom && shows(.custom) { customLogging.padding(.leading,20) }
                    }
                }.padding(.top,8)
                if let running=model.running { closeFirst(running,several:false) }
                Divider().padding(.vertical,6)
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(L("Save Logs")).font(LauncherStyle.font(14,.medium))
                        Text(savedLogs ?? L("Your recent sessions’ logs in one file for a bug report, with personal details removed. Works with logging off too."))
                            .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:12)
                    Button(model.savingLogs ? L("Saving…") : L("Save…"),action:model.saveLogs).buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(model.savingLogs).accessibilityLabel(L("Save logs"))
                }
            }
        }
    }
    private var savedLogs:String? {
        model.savedLogs.map { L("Saved {0} ({1}). Attach it to your GitHub issue.",$0.name,ByteCountFormatter.string(fromByteCount:$0.bytes,countStyle:.file)) }
    }
    /// Custom: Wine's WINEDEBUG text, as the player would type it in Terminal. It's used once it's
    /// valid and turned on (or updated); until then the setting stays as it was.
    private var customLogging:some View {
        let draft=customDraft ?? model.loggingCustom
        let text=LoggingSetting.normalized(draft)
        let valid=LoggingSetting.valid(text)
        let on=model.logging.contains(.custom)
        let changed=text != model.loggingCustom || !on
        return VStack(alignment:.leading,spacing:8) {
            TextField(L("Logging settings"),text:Binding(get:{ customDraft ?? model.loggingCustom },set:{ customDraft=$0 }),prompt:Text(verbatim:"fixme-all,+seh,+loaddll"))
                .font(.system(size:12,design:.monospaced)).textFieldStyle(.roundedBorder).disabled(model.running != nil)
                .onSubmit { if valid && changed { applyCustom(text) } }
            Text(text.isEmpty || valid ? L("As you’d set WINEDEBUG in Terminal: items separated by commas, such as +seh or warn+all.")
                                       : L("Wine wouldn’t understand this. Use items separated by commas, such as +seh or warn+all."))
                .font(LauncherStyle.font(12)).foregroundStyle(text.isEmpty || valid ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).fixedSize(horizontal:false,vertical:true)
            if changed {
                HStack(spacing:8) {
                    Button(on ? L("Update") : L("Turn On")) { applyCustom(text) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(!valid || model.running != nil)
                    if customDraft != nil { Button(L("Cancel")) { customDraft=nil }.buttonStyle(.borderless) }
                }
            }
        }.padding(.top,2)
    }
    /// Custom shows ticked while its text is being typed, before it's turned on.
    private func shows(_ preset:LoggingPreset)->Bool { model.logging.contains(preset) || (preset == .custom && customDraft != nil) }
    private func choose(_ preset:LoggingPreset, on:Bool) {
        if preset == .custom {
            if !on { customDraft=nil;model.logging=model.logging.with(.custom,on:false) }
            else if !model.logging.contains(.custom) { customDraft=model.loggingCustom }
            return
        }
        let next=model.logging.with(preset,on:on)
        if on && model.logging.isOff { confirmLogging=next } else { model.logging=next }
    }
    private func applyCustom(_ text:String) {
        guard LoggingSetting.valid(text) else { return }
        model.loggingCustom=text
        let next=model.logging.with(.custom,on:true)
        if model.logging.isOff { confirmLogging=next } else { model.logging=next;customDraft=nil }
    }
    private func turnOnLogging(_ next:LoggingSetting) {
        model.logging=next
        if next.contains(.custom) { customDraft=nil }
    }
    private func action(_ title:String, detail:String, button:String, disabled:Bool=false, _ perform:@escaping ()->Void) -> some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(LauncherStyle.font(14,.medium))
                Text(detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:12)
            Button(button,action:perform).buttonStyle(.bordered).buttonBorderShape(.capsule)
                .disabled(disabled || model.busy || !model.clientInstalled)
        }
    }
    /// Rarely needed: a network that hands out its proxy automatically (Recall connects
    /// directly, issue #15). Battle.net and Overwatch carry it from when they start. Korean
    /// accounts linked to Nexon (#16) are the Korea region, in General, from 1.4.1.
    private var advanced:some View {
        let locked=model.running != nil || !model.canChangeAdvanced
        return LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                SettingSwitch(title:L("Detect network proxy automatically"),detail:L("Only needed on some work or school networks."),
                              isOn:Binding(get:{ model.proxyAutoDetect },set:{ model.setAdvanced(.proxyAutoDetect,$0) }),disabled:locked)
                if let running=model.running { closeFirst(running,several:false) }
            }
        }
    }
}
/// A setting with its switch at the trailing edge, as in System Settings: title (and anything
/// beside it, such as New) over an optional explanation.
private struct SettingSwitch<Accessory:View>:View {
    let title:String
    var detail:String?=nil
    @Binding var isOn:Bool
    var disabled=false
    @ViewBuilder var accessory:Accessory
    var body:some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:2) {
                HStack(spacing:8) {
                    Text(title).font(LauncherStyle.font(14,.semibold))
                    accessory
                }
                if let detail {
                    Text(detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            Spacer(minLength:12)
            Toggle(title,isOn:$isOn).labelsHidden().toggleStyle(.switch).tint(LauncherStyle.accent).disabled(disabled)
                .accessibilityHint(detail ?? "")
        }
    }
}
extension SettingSwitch where Accessory == EmptyView {
    init(title:String, detail:String?=nil, isOn:Binding<Bool>, disabled:Bool=false) {
        self.init(title:title,detail:detail,isOn:isOn,disabled:disabled) { EmptyView() }
    }
}
/// One of Settings › General › Mouse's choices: a radio button, its name (and Experimental) over
/// what it does. The whole row chooses.
private struct MouseChoice:View {
    let title:String
    let detail:String
    var experimental=false
    let selected:Bool
    let disabled:Bool
    let choose:()->Void
    var body:some View {
        Button(action:choose) {
            HStack(alignment:.firstTextBaseline,spacing:10) {
                Image(systemName:selected ? "largecircle.fill.circle" : "circle").font(.system(size:14))
                    .foregroundStyle(selected ? LauncherStyle.accent : .secondary).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2) {
                    HStack(spacing:8) {
                        Text(title).font(LauncherStyle.font(13,.semibold))
                        if experimental { ExperimentalLabel() }
                    }
                    Text(detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.6 : 1)
            .accessibilityElement(children:.combine).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
/// Marks High-precision as experimental, beside its name: a small grey label.
private struct ExperimentalLabel:View {
    var body:some View {
        Text(L("Experimental")).font(LauncherStyle.font(11,.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal,7).padding(.vertical,2).background(Color.primary.opacity(0.08),in:Capsule())
    }
}
/// High-precision's feedback, in its explanation and in Settings while it's chosen: the Discord post
/// for it, and the invite for players not yet in the server. On China's Battle.net, where Discord is
/// blocked, GitHub instead (AppModel.showsDiscord).
private struct MouseFeedbackLinks:View {
    let discord:Bool
    @Environment(\.openURL) private var openURL
    var body:some View {
        HStack(spacing:14) {
            Button { openURL(discord ? Brand.mouseFeedback : Brand.issues) } label: {
                Label(discord ? L("Share Feedback") : L("Share Feedback on GitHub"),systemImage:"bubble.left")
            }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                .help(discord ? L("Open the High-precision mouse feedback post in Discord") : L("Open a new issue on GitHub in your browser"))
            if discord {
                Link(L("Join the Discord"),destination:Brand.discord).buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(L("Open the {0} Discord invite in your browser",Brand.name))
            }
        }.font(LauncherStyle.font(12,.medium))
    }
}
/// Shown when High-precision is chosen in Settings › General › Mouse (REC-52): what it does, how it
/// might help, why macOS will ask for Input Monitoring and how to undo it, before macOS's prompt
/// (owner, October 24), and where to say how it feels. Continue chooses it; Return doesn't.
struct HighPrecisionMouseSheet:View {
    let discord:Bool
    let confirm:()->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"cursorarrow.motionlines",title:L("High-precision mouse"),subtitle:L("Experimental"))
            LauncherPanel(inset:20) {
                VStack(alignment:.leading,spacing:12) {
                    paragraph(L("What it does."),L("Overwatch reads your mouse’s movement and buttons straight from the mouse, instead of through macOS’s input for games, which can drop some of your movement while you play."))
                    paragraph(L("How it might help."),L("If your aim sometimes feels slower or inconsistent, especially after clicking, this can make every movement count. It’s new, so it may not help on every Mac."))
                    paragraph(L("Why macOS asks for permission."),L("Reading a mouse directly needs Input Monitoring. macOS calls it “receiving keystrokes” because the same permission covers keyboards. {0} reads only your mouse, never your keyboard, and its code is public on GitHub.",Brand.name))
                    paragraph(L("How to undo it."),L("Switch back to Standard at any time, and turn {0} off in System Settings › Privacy & Security › Input Monitoring.",Brand.name))
                    VStack(alignment:.leading,spacing:6) {
                        paragraph(L("Tell us how it feels."),discord ? L("Share your feedback in {0}’s Discord.",Brand.name) : L("Share your feedback on GitHub."))
                        MouseFeedbackLinks(discord:discord)
                    }
                }
            }
            HStack(spacing:16) {
                Button(L("Cancel")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.cancelAction)
                Spacer()
                Button { confirm();dismiss() } label: { Text(L("Continue")).font(LauncherStyle.font(15,.semibold)).padding(.horizontal,8) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .tint(LauncherStyle.accent).foregroundStyle(LauncherStyle.ink)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
    private func paragraph(_ lead:String,_ text:String) -> some View {
        Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(.primary))\(AppLanguage.gap)\(Text(text).foregroundStyle(.secondary))")
            .font(LauncherStyle.font(13)).lineSpacing(3).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
    }
}
/// Settings › Graphics' info button: what MetalFX upscaling is, how Recall provides it, and
/// how to use it in Overwatch.
struct MetalFXInfo:View {
    private let steps=[L("Close Battle.net, turn on MetalFX upscaling, then press Play."),
                       L("In Overwatch’s Video settings, choose NVIDIA DLSS."),
                       L("Choose a mode. Quality looks closest to full resolution; Performance and Ultra Performance give the most FPS.")]
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("MetalFX upscaling")).font(LauncherStyle.font(15,.semibold)).accessibilityAddTraits(.isHeader)
            paragraph(L("What it is."),L("MetalFX is Apple’s upscaling technology, built into macOS. It runs on your Mac’s GPU."))
            paragraph(L("How it works."),L("Overwatch renders each frame at a lower resolution, which takes less work. MetalFX then rebuilds the frame at full resolution, using detail from earlier frames and how things have moved since. You get a higher frame rate with a picture close to full resolution. Sharpening, if you turn it on, runs after MetalFX."))
            paragraph(L("How Recall does it."),L("Overwatch offers this kind of upscaling as NVIDIA DLSS, and only on NVIDIA graphics cards. With this setting on, Recall presents your Mac to Overwatch as an NVIDIA card, so the DLSS option appears. Overwatch only loads a signed DLSS component, so Recall includes a signed stand-in from the open-source DXMT project, which hands each frame to MetalFX. NVIDIA’s DLSS isn’t used; your Mac does all the work."))
            VStack(alignment:.leading,spacing:4) {
                Text(L("Turning it on.")).fontWeight(.semibold)
                ForEach(steps.indices,id:\.self) { index in
                    HStack(alignment:.firstTextBaseline,spacing:6) {
                        Text("\(index+1).").monospacedDigit()
                        Text(steps[index]).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }.lineSpacing(3)
            paragraph(L("Good to know."),L("While it’s on, Overwatch lists your graphics card as an NVIDIA GeForce RTX 4090, and NVIDIA Reflex has no effect. Turning it off puts your Mac’s GPU back and keeps your other video settings."))
        }.font(LauncherStyle.font(13)).padding(20).frame(width:420,alignment:.leading)
    }
    private func paragraph(_ lead:String,_ text:String) -> some View {
        Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(.primary))\(AppLanguage.gap)\(Text(text).foregroundStyle(.secondary))")
            .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
    }
}
/// Shown when Korea is chosen (Choose your Battle.net's Continue, or Settings › General ›
/// Battle.net region): what Recall changes for Korean accounts linked to Nexon (the worker's
/// Korean account support, portable_korea.h) and the account risk. Return doesn't confirm.
struct KoreanSupportSheet:View {
    let confirm:()->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"exclamationmark.shield",title:L("Play on a Korean account?"),subtitle:L("For Korean accounts linked to Nexon."))
            LauncherPanel(inset:20) {
                VStack(alignment:.leading,spacing:12) {
                    paragraph(L("What changes."),L("{0} adds a security certificate the game checks when it starts. Nexon’s anti-cheat also takes screenshots of the game now and then, which Wine on a Mac can’t take, so the game would crash. {0} hands the anti-cheat a blank image instead.",Brand.name))
                    paragraph(L("Your account."),L("Overwatch in Korea includes Nexon’s anti-cheat. {0} doesn’t turn it off, but Nexon doesn’t support playing on a Mac, so playing this way could affect your account.",Brand.name))
                    paragraph(L("Switching later."),L("Korea uses Global’s Battle.net, so you can switch between them in Settings › General › Battle.net region and keep your installation."))
                }
            }
            HStack(spacing:16) {
                Button(L("Cancel")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.cancelAction)
                Spacer()
                Button { confirm();dismiss() } label: { Text(L("Continue")).font(LauncherStyle.font(15,.semibold)).padding(.horizontal,8) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .tint(LauncherStyle.accent).foregroundStyle(LauncherStyle.ink)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
    private func paragraph(_ lead:String,_ text:String) -> some View {
        Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(.primary))\(AppLanguage.gap)\(Text(text).foregroundStyle(.secondary))")
            .font(LauncherStyle.font(13)).lineSpacing(3).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
    }
}
/// Shown when China's Battle.net is chosen (Choose your Battle.net's Continue): how signing in
/// works and the account risk, as Korea's asks. Return doesn't confirm.
struct ChinaBattleNetSheet:View {
    let confirm:()->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"exclamationmark.shield",title:L("Set up China’s Battle.net?"),subtitle:L("Battle.net for mainland China, run by NetEase."))
            LauncherPanel(inset:20) {
                VStack(alignment:.leading,spacing:12) {
                    paragraph(L("Signing in."),L("You sign in with your NetEase account in your web browser. If Safari doesn’t take you back to Battle.net, use Chrome or Firefox."))
                    paragraph(L("Your account."),L("Overwatch in China includes NetEase’s anti-cheat. Recall doesn’t turn it off, but NetEase doesn’t support playing on a Mac, so playing this way could affect your account."))
                    paragraph(L("Switching later."),L("Accounts don’t carry over between Global and China’s Battle.net. To switch, choose Settings › General › Battle.net region."))
                }
            }
            HStack(spacing:16) {
                Button(L("Cancel")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.cancelAction)
                Spacer()
                Button { confirm();dismiss() } label: { Text(L("Continue")).font(LauncherStyle.font(15,.semibold)).padding(.horizontal,8) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .tint(LauncherStyle.accent).foregroundStyle(LauncherStyle.ink)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
    private func paragraph(_ lead:String,_ text:String) -> some View {
        Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(.primary))\(AppLanguage.gap)\(Text(text).foregroundStyle(.secondary))")
            .font(LauncherStyle.font(13)).lineSpacing(3).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
    }
}
/// Settings › General › Battle.net region, to or from China's: what switching does, then the
/// installation going to the Trash (AppModel.changeRegion), after which setup starts at Choose
/// your Battle.net with the region chosen (AppModel.regionTarget). Return never switches.
struct ChangeRegionSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            switch model.regionChange {
            case .idle, .failed:
                SheetHero(symbol:"globe",title:L("Switch to {0}?",model.regionTarget.title),
                          subtitle:L("Accounts don’t carry over between Global and China’s Battle.net, so each needs its own installation."))
                LauncherPanel {
                    VStack(alignment:.leading,spacing:10) {
                        Text(L("{0} moves Overwatch, Battle.net and their settings to the Trash, then sets up again. Overwatch downloads again in Battle.net.",Brand.name))
                        Text(L("Your Blizzard or NetEase account isn’t affected. Empty the Trash to free the storage."))
                    }.font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if case .failed(let message)=model.regionChange { LauncherNotice(text:message) }
                else { LauncherNotice(text:L("Battle.net is closed for you if it’s open. Overwatch itself must be quit first.")) }
                HStack(spacing:16) {
                    Button(L("Cancel")) { model.regionChange = .idle;dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    // Deliberately not the default action: Return never switches.
                    Button(role:.destructive) { model.changeRegion() } label: { Text(L("Switch")).font(LauncherStyle.font(15,.semibold)).padding(.horizontal,8) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(.red)
                }
            case .working:
                SheetHero(symbol:"globe",title:L("Switching Battle.net"),
                          subtitle:model.stage == L("Closing Battle.net") ? L("Closing Battle.net first.") : L("Moving Overwatch and Battle.net to the Trash."))
                ProgressView().controlSize(.small).accessibilityLabel(L("Switching Battle.net"))
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
}
/// REC-44: back to the installation on another drive once setup has installed something here.
/// Whether this setup moves to the Trash is the player's call, with what it takes; kept, it's
/// the one offered back.
struct OtherInstallationSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    /// A setup that stopped part way suggests the Trash; one with Overwatch installed, keeping it.
    @State private var removing:Bool
    @State private var size:Int64?
    init(model:AppModel) { self.model=model;_removing=State(initialValue:!model.gameInstalled) }
    var body:some View {
        let name=model.otherInstallation.map(InstallLocation.driveName) ?? ""
        let here=InstallLocation.isStandard(model.root)
        VStack(spacing:24) {
            SheetHero(symbol:"externaldrive",title:L("Go back to “{0}”?",name),
                      subtitle:L("Your installation on “{0}” is still there. {1} picks up where it left off.",name,Brand.name))
            LauncherPanel {
                VStack(alignment:.leading,spacing:10) {
                    Text(here ? L("What about the setup on this Mac?") : L("What about the setup on “{0}”?",InstallLocation.driveName(model.root)))
                        .font(LauncherStyle.font(14,.semibold))
                    option(true,title:L("Move it to the Trash"),
                           detail:size.map { L("Frees {0} once you empty the Trash.",ByteCountFormatter.string(fromByteCount:$0,countStyle:.file)) } ?? L("Working out its size…"))
                    option(false,title:L("Keep it"),detail:L("You can go back to it later in Settings › General."))
                }
            }
            if model.clientInstalled { LauncherNotice(text:L("Battle.net is closed for you if it’s open. Overwatch itself must be quit first.")) }
            HStack(spacing:16) {
                Button(L("Cancel")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.cancelAction)
                Spacer()
                LauncherPrimaryAction(title:L("Go Back")) { model.useOtherInstallation(removing:removing) }
                    .keyboardShortcut(.defaultAction).disabled(model.busy || model.running == .game)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
            .task {
                let root=model.root
                size=await Task.detached { InstallLocation.size(root) }.value
            }
    }
    private func option(_ value:Bool,title:String,detail:String)->some View {
        let selected=removing == value
        let shape=RoundedRectangle(cornerRadius:14,style:.continuous)
        return Button { removing=value } label: {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:selected ? "checkmark.circle.fill" : "circle").font(.system(size:18))
                    .foregroundStyle(selected ? AnyShapeStyle(LauncherStyle.accent) : AnyShapeStyle(.secondary)).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2) {
                    Text(title).font(LauncherStyle.font(14,.semibold))
                    Text(detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(selected ? AnyShapeStyle(LauncherStyle.accent.opacity(0.10)) : AnyShapeStyle(.primary.opacity(0.04)),in:shape)
                .overlay { shape.strokeBorder(selected ? LauncherStyle.accent.opacity(0.6) : .clear,lineWidth:1.5) }
                .contentShape(shape)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct AboutSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var licenses=false
    private var version:String {
        L("Version {0} · Build {1}",UpdateCheck.installed,String(UpdateCheck.build)) + (model.release?.distribution == "private-preview" ? " · "+L("Private alpha") : "")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(alignment:.center,spacing:18) {
                AppArtwork(size:76)
                VStack(alignment:.leading,spacing:4) {
                    Text(Brand.name).font(LauncherStyle.font(30,.bold)).tracking(-0.8).accessibilityAddTraits(.isHeader)
                    Text(Brand.tagline).font(LauncherStyle.font(14)).foregroundStyle(.secondary)
                    Text(version).font(LauncherStyle.font(11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing:12) {
                RepositoryLink(compact:true)
                VStack(alignment:.leading,spacing:3) {
                    Text(L("Open source. Contributions welcome.")).foregroundStyle(.secondary)
                    Button(L("Licenses")) { licenses=true }.buttonStyle(.plain).underline()
                        .foregroundStyle(.secondary).help(L("Show {0}’s license and notices",Brand.name))
                }.font(LauncherStyle.font(12))
            }
            // The heading, the repository row and the bottom row stay put; the letter and the
            // support section scroll, as Help's content does.
            ScrollView {
            LauncherPanel {
                VStack(alignment:.leading,spacing:18) {
                    HStack(alignment:.center,spacing:16) {
                        AuthorPhoto(size:64)
                        HStack(spacing:8) {
                            Text(L("Author:")).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                            LinkedInLink()
                        }
                    }
                    // The owner's own words (final draft, October 1, 2026).
                    VStack(alignment:.leading,spacing:10) {
                        Text(L("Hey there!")).font(LauncherStyle.font(13,.semibold))
                        Text(L("I’m Josh, I’m a graduate of UCSB’s Master of Technology Management Program and love building tech products! I have also been a part of the PC Overwatch community for 4+ years now and have always been fascinated by the idea of having Overwatch run on Apple Silicon. Mac has historically been known as a terrible place for gamers for many different reasons, but with the introduction of Apple Silicon in 2020, I feel like the tides have shifted and there is no better time than now for developers to refocus attention towards building native games for this platform. Especially with an immense Mac userbase waiting to be captured, I would love to see a day where Blizzard builds a native Overwatch port for Mac, but in the meantime, I hope {0} can fill that place. I hope you enjoy :)",Brand.name))
                            .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                        Text(L("Best,\nJosh")).fixedSize(horizontal:false,vertical:true)
                    }.font(LauncherStyle.font(13)).accessibilityElement(children:.combine)
                    Divider()
                    VStack(alignment:.leading,spacing:8) {
                        Text(L("Support my work")).font(LauncherStyle.font(15,.semibold)).accessibilityAddTraits(.isHeader)
                        Text(L("If {0} has helped you, you can support my work by trying Mosaic News, another free project of mine that shows how different outlets cover the same story, or by buying me a coffee.",Brand.name))
                            .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    HStack(spacing:10) {
                        MosaicButton(placement:.about)
                        CoffeeButton()
                    }
                }
            }
            }.scrollBounceBehavior(.basedOnSize).frame(maxHeight:.infinity,alignment:.top)
            HStack(alignment:.bottom,spacing:20) {
                Text(Brand.trademarks).font(LauncherStyle.font(10.5)).lineSpacing(1).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
                Button(L("Done")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction).closesOnEscape { dismiss() }
            }
        }.padding(28).frame(width:LauncherStyle.sheetWidth,height:LauncherStyle.largeSheetHeight,alignment:.top).tint(.primary)
            .background(LauncherStyle.ground(scheme))
            .sheet(isPresented:$licenses) { LicensesSheet() }
    }
}
/// Recall's own NOTICE and Apache 2.0 license as bundled, and a way to the third-party ones.
struct LicensesSheet:View {
    @Environment(\.dismiss) private var dismiss
    private static func bundled(_ name:String,_ type:String)->String {
        Bundle.main.url(forResource:name,withExtension:type).flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? ""
    }
    private let text=[bundled("NOTICE","txt"),bundled("PROJECT-LICENSE","txt")]
        .map { $0.trimmingCharacters(in:.newlines) }.filter { !$0.isEmpty }.joined(separator:"\n\n\n")
    private var thirdParty:URL? { Bundle.main.url(forResource:"Licenses",withExtension:nil) }
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"doc.text",title:L("Licenses"),
                      subtitle:L("{0} is open source under the Apache License 2.0. Wine, DXMT and the other components it includes keep their own licenses.",Brand.name))
            LauncherPanel {
                ScrollView {
                    Text(text.isEmpty ? L("The license files are missing from this copy of {0}.",Brand.name) : text)
                        .font(.system(size:10.5,design:.monospaced)).lineSpacing(2).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:.infinity)
            }.frame(maxHeight:.infinity)
            HStack(spacing:16) {
                if let thirdParty {
                    Button(L("Third-Party Licenses")) { NSWorkspace.shared.activateFileViewerSelecting([thirdParty]) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                        .help(L("Show the bundled third-party license files in Finder"))
                }
                Spacer()
                Button(L("Done")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction).closesOnEscape { dismiss() }
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth,height:LauncherStyle.largeSheetHeight)
            .tint(.primary).background { LauncherBackground() }
    }
}
struct UninstallSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            switch model.uninstall {
            case .idle, .failed:
                SheetHero(symbol:"trash",title:L("Uninstall {0}?",Brand.name),subtitle:L("This removes the game, Battle.net and {0} from your Mac.",Brand.name))
                LauncherPanel {
                    VStack(alignment:.leading,spacing:14) {
                        Text(L("What will be moved to the Trash")).font(LauncherStyle.font(14,.semibold))
                        VStack(alignment:.leading,spacing:8) {
                            row(L("Overwatch"), L("The installed game and its settings"))
                            row(L("Battle.net"), L("The Battle.net app set up by this app"))
                            row(Brand.name, L("This app and its setup files"))
                        }
                        Divider()
                        Text(L("Your Blizzard account and any other Blizzard software on this Mac are not touched. Everything goes to the Trash, so you can put it back from Finder. Storage is freed once you empty the Trash."))
                            .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
                if case .failed(let message)=model.uninstall { LauncherNotice(text:message) }
                else { LauncherNotice(text:L("Battle.net is closed for you if it’s open. Overwatch itself must be quit first. Nothing is removed until you choose Uninstall.")) }
                HStack(spacing:16) {
                    Button(L("Cancel")) { model.uninstall = .idle;dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    // Deliberately not the default action: Return never uninstalls.
                    Button(role:.destructive) { model.uninstallEverything() } label: { Text(L("Uninstall")).font(LauncherStyle.font(15,.semibold)).padding(.horizontal,8) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(.red)
                }
            case .working:
                SheetHero(symbol:"trash",title:L("Uninstalling"),subtitle:model.stage == L("Closing Battle.net") ? L("Closing Battle.net first.") : L("Moving Overwatch, Battle.net and this app to the Trash."))
                ProgressView().controlSize(.small).accessibilityLabel(L("Uninstalling"))
            case .done(let appRemoved):
                SheetHero(symbol:"checkmark",title:L("Uninstalled"),subtitle:appRemoved ? L("Overwatch, Battle.net and this app are in the Trash.") : L("Overwatch and Battle.net are in the Trash."))
                LauncherNotice(text:appRemoved ? L("Empty the Trash to free the storage. Quit to finish.") : L("{0} couldn’t move itself to the Trash. Quit, then drag {0} from Applications to the Trash and empty it.",Brand.name))
                Button(L("Quit")) { model.quit() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
    private func row(_ name:String,_ detail:String)->some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Text(name).font(LauncherStyle.font(13,.semibold)).frame(width:130,alignment:.leading)
            Text(detail).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
        }
    }
}
// Every update outcome in one place: a check in progress, the newer version
// with its notes, the download, or why nothing changed.
struct UpdateSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            switch model.update {
            case .available(let item):
                SheetHero(symbol:"arrow.down.circle",title:L("Update available"),subtitle:L("{0} {1} is ready to install. You have {2}.",Brand.name,item.version,UpdateCheck.installed))
                LauncherPanel {
                    VStack(alignment:.leading,spacing:10) {
                        Text(L("What’s new")).font(LauncherStyle.font(14,.semibold))
                        if item.notes.isEmpty {
                            Text(L("See the release notes for details.")).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                        }
                        ForEach(item.notes.indices,id:\.self) { index in
                            HStack(alignment:.firstTextBaseline,spacing:8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item.notes[index]).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                            }.font(LauncherStyle.font(13))
                        }
                    }
                }
                if !model.updateNotice.isEmpty { LauncherNotice(text:model.updateNotice,symbol:"exclamationmark.triangle") }
                Text(L("Your game, settings and Battle.net sign-in are kept. The app reopens when it’s done."))
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing:16) {
                    Button(L("Later")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
                    Link(L("Release Notes"),destination:item.page).font(LauncherStyle.font(13))
                    Spacer()
                    LauncherPrimaryAction(title:L("Update Now"),action:model.installUpdate).keyboardShortcut(.defaultAction).disabled(model.busy)
                }
            case .downloading(let fraction):
                SheetHero(symbol:"arrow.down.circle",title:L("Downloading the update"),subtitle:L("{0}% · The app reopens when it’s done.",String(Int(fraction*100))))
                ProgressView(value:fraction).frame(maxWidth:360).accessibilityLabel(L("Download progress"))
                Button(L("Cancel"),action:model.cancelUpdateDownload).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            case .installing:
                SheetHero(symbol:"arrow.down.circle",title:L("Installing the update"),subtitle:L("The app will reopen in a moment."))
                ProgressView().controlSize(.small).accessibilityLabel(L("Installing"))
            case .upToDate:
                SheetHero(symbol:"checkmark",title:L("You’re up to date"),subtitle:L("{0} {1} is the latest version.",Brand.name,UpdateCheck.installed))
                Button(L("Done")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
                    .closesOnEscape { dismiss() }
            case .failed(let message):
                SheetHero(symbol:"exclamationmark",title:L("Couldn’t check for updates"),subtitle:message)
                HStack(spacing:16) {
                    Button(L("Done")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    LauncherPrimaryAction(title:L("Try Again")) { model.checkForUpdates(manual:true) }.keyboardShortcut(.defaultAction)
                }
            case .checking, .idle:
                SheetHero(symbol:"arrow.triangle.2.circlepath",title:L("Checking for updates"),subtitle:L("Asking GitHub for the latest version."))
                ProgressView().controlSize(.small).accessibilityLabel(L("Checking for updates"))
                Button(L("Cancel")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
}
/// After updating to 1.4, once, following What's New (AppModel.whatsNewClosed): the shaders
/// Overwatch has used get prepared for 1.4's shader cache now, or after the next match. Built
/// for a quick yes: the facts in three lines and one large button.
struct ShaderUpdateSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        VStack(spacing:24) {
            VStack(spacing:20) {
                Image(systemName:"square.stack.3d.up.fill").font(.system(size:30,weight:.medium))
                    .foregroundStyle(LauncherStyle.accent)
                    .symbolEffect(.breathe,isActive:!reduceMotion)
                    .frame(width:72,height:72)
                    .background(LauncherStyle.accent.opacity(0.14),in:RoundedRectangle(cornerRadius:22,style:.continuous))
                    .accessibilityHidden(true)
                LauncherHeading(title:L("Update your shader cache"),
                                subtitle:L("{0} 1.4 compiles and loads shaders more efficiently. Update your shader cache once and you’re set.",Brand.name),compact:true)
            }
            LauncherPanel {
                VStack(alignment:.leading,spacing:14) {
                    if model.shaderUpdatePending > 0 { fact("bolt.fill",L("{0} of your shaders to upgrade",model.shaderUpdatePending.formatted())) }
                    fact("clock.fill",L("About 5–15 minutes, one time only"))
                    fact("laptopcomputer",L("Keep using your Mac while it runs"))
                }
            }
            VStack(spacing:12) {
                LauncherPrimaryAction(title:L("Update Now"),wide:true) { model.updateShaderCache() }.keyboardShortcut(.defaultAction)
                Button(L("Maybe later")) { dismiss() }.buttonStyle(.borderless).font(LauncherStyle.font(14,.medium))
                    .foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
    private func fact(_ symbol:String,_ text:String)->some View {
        HStack(spacing:14) {
            Image(systemName:symbol).font(.system(size:16,weight:.semibold)).foregroundStyle(LauncherStyle.accent)
                .frame(width:24).accessibilityHidden(true)
            Text(text).font(LauncherStyle.font(15,.medium)).foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
        }
    }
}
struct WhatsNewSheet:View {
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"sparkles",title:L("What’s new in {0}",WhatsNew.version),subtitle:"\(Brand.name) \(UpdateCheck.installed)")
            // A long list scrolls inside the panel, so the sheet fits the smallest window.
            LauncherPanel {
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        ForEach(WhatsNew.items.indices,id:\.self) { index in
                            let item=WhatsNew.items[index]
                            HStack(alignment:.top,spacing:14) {
                                Image(systemName:item.symbol).font(.system(size:17,weight:.medium)).foregroundStyle(LauncherStyle.accent)
                                    .frame(width:24).accessibilityHidden(true)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(item.title).font(LauncherStyle.font(14,.semibold))
                                    Text(item.detail).font(LauncherStyle.font(13)).lineSpacing(2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                }
                            }
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.scrollBounceBehavior(.basedOnSize).frame(maxHeight:.infinity)
            }.frame(maxHeight:.infinity)
            HStack(spacing:16) {
                Link(L("Release Notes"),destination:Brand.releases).font(LauncherStyle.font(13))
                Spacer()
                LauncherPrimaryAction(title:L("Continue")) { dismiss() }.keyboardShortcut(.defaultAction).closesOnEscape { dismiss() }
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth,height:LauncherStyle.largeSheetHeight)
            .tint(.primary).background { LauncherBackground() }
    }
}
