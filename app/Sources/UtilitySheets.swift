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
    /// Shader memory's slider: how many of the shader cache's parts Overwatch loads.
    @State private var shaderParts=1.0
    /// Follows System Settings: the main display can change while Settings is open.
    @State private var main=MainDisplay.current
    /// Also follows System Settings, where the player turns the microphone on or off.
    @State private var microphoneAccess=Microphone.access
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
                model.checkRunning();microphoneAccess=Microphone.access
            }
            .alert(L("Force quit Overwatch and Battle.net?"),isPresented:$confirmForceQuit) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Force Quit"),role:.destructive,action:model.forceQuit)
            } message: { Text(L("Use this when the game stops responding. If you’re in a match, you’ll leave it.")) }
            .alert(L("Repair game files?"),isPresented:$confirmRepair) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Repair"),action:model.repair)
            } message: { Text(L("Overwatch and Battle.net must be closed. This reinstalls the files this app adds and refreshes the Windows environment. Overwatch, its settings and your Battle.net sign-in are kept.")) }
            .sheet(isPresented:$confirmKorean) { KoreanSupportSheet { model.setAdvanced(.koreanSupport,true) } }
            .alert(L("Reset display settings?"),isPresented:$confirmResetDisplay) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Reset"),action:model.resetDisplay)
            } message: { Text(model.rememberEachDisplay ? L("Overwatch will open full screen at {0} on this display the next time it starts. Your graphics quality and FPS settings stay as they are.",DisplayResolution.initial(for:main).label)
                                                          : L("Overwatch will open full screen at {0} the next time it starts. Your graphics quality and FPS settings stay as they are.",DisplayResolution.initial(for:main).label)) }
            .alert(L("Delete shaders?"),isPresented:$confirmDeleteShaders) {
                Button(L("Cancel"),role:.cancel) {}
                Button(L("Delete"),role:.destructive,action:model.deleteShaders)
            } message: { Text(L("Do you really want to delete the shader cache? You might experience stuttering until the shaders are rebuilt again.")) }
    }
    @ViewBuilder private var page:some View {
        switch model.settingsTab {
        case .general:
            updates
            battleNet
        case .display:
            display
            resetDisplay
        case .graphics:
            upscaling
            metalHUD
            shaderMemory
            deleteShaders
        case .audio:
            microphone
            sound
        case .advanced:
            troubleshooting
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
                // Global or China's Battle.net (BattleNetChoice.swift); changing it sets up again.
                if model.clientInstalled {
                    Divider().padding(.vertical,6)
                    HStack(alignment:.center,spacing:12) {
                        VStack(alignment:.leading,spacing:2) {
                            Text(L("Battle.net region")).font(LauncherStyle.font(14,.semibold))
                            Text(model.installedRegion.title).font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:12)
                        Button(L("Change…")) { model.regionChange = .idle;model.sheet = .changeRegion }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(model.busy || model.uninstall == .working)
                    }
                }
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
                        .popover(isPresented:$aboutUpscaling,arrowEdge:.bottom) { MetalFXInfo() }
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
    /// Delete Shaders, under the Shader memory panel: empty the prepared shader cache so
    /// every shader builds again from scratch after the next match. The confirmation asks.
    private var deleteShaders:some View {
        LauncherPanel(inset:16) {
            action(L("Delete Shaders"),detail:L("Clears your shader cache. Use this if you experience shader related issues."),button:L("Delete")) { confirmDeleteShaders=true }
        }
    }
    /// A setting Battle.net carries from when it opens: change it once it's closed.
    private func closeFirst(_ running:AppModel.Running, several:Bool) -> some View {
        HStack(spacing:12) {
            Text(running == .game ? (several ? L("Quit Overwatch to change these.") : L("Quit Overwatch to change this."))
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
    /// Wine picks the sound output once, as Overwatch starts, and keeps it.
    private var sound:some View {
        LauncherPanel(inset:16) {
            note(L("Speakers and headphones"),L("Overwatch keeps the sound output that was selected when it started. Connect your headphones and select them on your Mac before you press Play; to switch later, quit Overwatch and play again."))
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
    private func action(_ title:String, detail:String, button:String, _ perform:@escaping ()->Void) -> some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(LauncherStyle.font(14,.medium))
                Text(detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:12)
            Button(button,action:perform).buttonStyle(.bordered).buttonBorderShape(.capsule)
                .disabled(model.busy || !model.clientInstalled)
        }
    }
    /// Rarely needed: a network that hands out its proxy automatically (Recall connects
    /// directly, issue #15), and Korean accounts linked to Nexon (#16). Battle.net and
    /// Overwatch carry both from when they start.
    private var advanced:some View {
        let locked=model.running != nil || !model.canChangeAdvanced
        return LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                SettingSwitch(title:L("Detect network proxy automatically"),detail:L("Only needed on some work or school networks."),
                              isOn:Binding(get:{ model.proxyAutoDetect },set:{ model.setAdvanced(.proxyAutoDetect,$0) }),disabled:locked)
                Divider().padding(.vertical,6)
                // Turning it on asks first (account risk); turning it off doesn't.
                SettingSwitch(title:L("Korean account support (한국 계정 지원)"),detail:L("For Korean accounts linked to Nexon. Experimental."),
                              isOn:Binding(get:{ model.koreanSupport },set:{ on in
                                  if on { confirmKorean=true } else { model.setAdvanced(.koreanSupport,false) }
                              }),disabled:locked)
                if let running=model.running { closeFirst(running,several:true) }
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
/// Asked before Korean account support turns on: what it changes and the account risk, in
/// Recall's language and in Korean (Recall has no Korean interface yet). Return doesn't confirm.
struct KoreanSupportSheet:View {
    let turnOn:()->Void
    @Environment(\.dismiss) private var dismiss
    static var english:[String] { [
        L("This experimental option lets Overwatch run on Korean accounts linked to Nexon. Recall adds a security certificate the game checks when it starts. Nexon’s anti-cheat also takes screenshots of the game now and then, which Wine on a Mac can’t take, so the game crashes. Recall hands the anti-cheat a blank image instead."),
        L("This doesn’t turn off Nexon’s anti-cheat, but Nexon doesn’t support playing on a Mac, so using it could affect your account.")] }
    static let korean=[
        "이 실험적 기능을 켜면 넥슨과 연동된 한국 계정으로 오버워치를 플레이할 수 있습니다. Recall은 게임이 시작할 때 확인하는 보안 인증서를 추가합니다. 또한 넥슨의 안티치트는 가끔 게임 화면을 캡처하는데, Mac의 Wine에서는 이 캡처를 할 수 없어 게임이 강제 종료됩니다. 그래서 Recall은 대신 빈 이미지를 전달합니다.",
        "이 기능은 넥슨의 안티치트를 끄지 않습니다. 하지만 넥슨은 Mac에서의 플레이를 지원하지 않으므로, 이 기능을 사용하면 계정에 영향이 있을 수 있습니다."]
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"exclamationmark.shield",title:L("Turn on Korean account support?"),subtitle:"한국 계정 지원을 켜시겠습니까?")
            LauncherPanel(inset:20) {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(Self.english,id:\.self,content:paragraph)
                    Divider().padding(.vertical,4)
                    ForEach(Self.korean,id:\.self,content:paragraph)
                }
            }
            HStack(spacing:16) {
                Button(L("Cancel 취소")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.cancelAction)
                Spacer()
                Button { turnOn();dismiss() } label: { Text(L("Turn On 켜기")).font(LauncherStyle.font(15,.semibold)).padding(.horizontal,8) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .tint(LauncherStyle.accent).foregroundStyle(LauncherStyle.ink)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
    private func paragraph(_ text:String) -> some View {
        Text(text).font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary)
            .frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
    }
}
/// Shown when China's Battle.net is chosen (Choose your Battle.net's Continue): how signing in
/// works and the account risk, as Korean account support asks. Return doesn't confirm.
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
/// Settings › General › Battle.net region › Change: what switching does, then the installation
/// going to the Trash (AppModel.changeRegion), after which setup starts at Choose your Battle.net
/// with the other region. Return never switches.
struct ChangeRegionSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    private var target:BattleNetRegion { model.installedRegion == .china ? .global : .china }
    var body:some View {
        VStack(spacing:24) {
            switch model.regionChange {
            case .idle, .failed:
                SheetHero(symbol:"globe",title:target == .china ? L("Switch to China’s Battle.net?") : L("Switch to Global Battle.net?"),
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
            LauncherPanel {
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
                }
            }
            HStack(spacing:16) {
                Link(L("Release Notes"),destination:Brand.releases).font(LauncherStyle.font(13))
                Spacer()
                LauncherPrimaryAction(title:L("Continue")) { dismiss() }.keyboardShortcut(.defaultAction).closesOnEscape { dismiss() }
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:LauncherStyle.sheetWidth)
            .tint(.primary).background { LauncherBackground() }
    }
}
