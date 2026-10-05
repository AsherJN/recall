import SwiftUI
import AppKit

// Updates, the one display setting the app owns, and recovery actions. Driver
// tuning is deliberately absent: FPS, quality and sensitivity live in Overwatch.
struct SettingsSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForceQuit=false
    @State private var confirmRepair=false
    @State private var confirmResetDisplay=false
    /// Settings opens with the resolution sizes folded away.
    @State private var displayExpanded=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Follows System Settings: the main display can change while Settings is open.
    @State private var main=MainDisplay.current
    var body:some View {
        VStack(spacing:16) {
            LauncherHeading(title:"Settings",subtitle:"",compact:true)
            ScrollView {
                VStack(spacing:12) {
                    updates
                    display
                    battleNet
                    metalHUD
                    troubleshooting
                }
            }.scrollIndicators(.hidden)
            if !model.notice.isEmpty { LauncherNotice(text:model.notice) }
            HStack {
                // Uninstall lives here, always visible and apart from the
                // everyday settings; it opens its own confirmation.
                Button(role:.destructive) { model.sheet = .uninstall } label: {
                    Label("Uninstall \(Brand.name)…",systemImage:"trash").font(LauncherStyle.font(13,.medium))
                }.buttonStyle(.borderless).foregroundStyle(.red).disabled(model.uninstall == .working)
                    .help("Move \(Brand.name), Battle.net and Overwatch to the Trash")
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
            }
        }.font(LauncherStyle.font(14)).padding(.horizontal,32).padding(.vertical,28).frame(width:540,height:860)
            .tint(.primary).background { LauncherBackground() }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification)) { _ in
                main=MainDisplay.current
                model.refreshDisplay()
            }
            // Battle.net or Overwatch may have opened or closed while the player was away.
            .onAppear {
                model.checkRunning()
                // Private previews can open with the resolution sizes shown.
                if model.isPreview && CommandLine.arguments.contains("--preview-resolution-open") { displayExpanded=true }
            }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in model.checkRunning() }
            .alert("Force quit Overwatch and Battle.net?",isPresented:$confirmForceQuit) {
                Button("Cancel",role:.cancel) {}
                Button("Force Quit",role:.destructive,action:model.forceQuit)
            } message: { Text("Use this when the game stops responding. If you’re in a match, you’ll leave it.") }
            .alert("Repair game files?",isPresented:$confirmRepair) {
                Button("Cancel",role:.cancel) {}
                Button("Repair",action:model.repair)
            } message: { Text("Overwatch and Battle.net must be closed. This reinstalls the files this app adds and refreshes the Windows environment. Overwatch, its settings and your Battle.net sign-in are kept.") }
            .alert("Reset display settings?",isPresented:$confirmResetDisplay) {
                Button("Cancel",role:.cancel) {}
                Button("Reset",action:model.resetDisplay)
            } message: { Text("Overwatch will open full screen at \(DisplayResolution.initial(for:main).label)\(model.rememberEachDisplay ? " on this display" : "") the next time it starts. Your graphics quality and FPS settings stay as they are.") }
    }
    private var updates:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("Updates").font(LauncherStyle.font(14,.semibold))
                    Spacer()
                    if case .available=model.update {
                        Button("Update…") { model.sheet = .update }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(LauncherStyle.accent)
                            .foregroundStyle(LauncherStyle.ink)
                    } else {
                        Button("Check Now") { model.checkForUpdates(manual:true,present:false) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .disabled(model.update == .checking || model.update == .installing)
                    }
                }
                Toggle("Check for updates automatically",isOn:$model.automaticUpdates).toggleStyle(.switch).tint(LauncherStyle.accent)
                Text("\(status) · Nothing about you or your Mac is sent.").font(LauncherStyle.font(12))
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private var status:String {
        switch model.update {
        case .available(let item): return "Version \(item.version) is available"
        case .upToDate: return "Version \(UpdateCheck.installed) · up to date"
        case .checking: return "Checking…"
        case .downloading, .installing: return "Updating…"
        case .failed: return "Couldn’t reach GitHub; check your connection"
        default: return "Version \(UpdateCheck.installed)"
        }
    }
    /// Overwatch's own Video settings are where players change resolution; Recall keeps
    /// their choice. This row shows it, and opens Settings' sizes for players who want
    /// to set it from here.
    private var display:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:12) {
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration:0.15)) { displayExpanded.toggle() } } label: {
                    HStack(spacing:10) {
                        VStack(alignment:.leading,spacing:2) {
                            Text("Fullscreen resolution").font(LauncherStyle.font(14,.semibold))
                            Text("Set it in game under Options › Video, or here.")
                                .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:8)
                        Text(model.resolution.label).font(LauncherStyle.font(13,.medium)).monospacedDigit()
                        Image(systemName:"chevron.down").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(displayExpanded ? 180 : 0)).accessibilityHidden(true)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Fullscreen resolution, \(model.resolution.label)")
                    .accessibilityValue(displayExpanded ? "Expanded" : "Collapsed")
                if displayExpanded { displayOptions }
            }
        }
    }
    private var displayOptions:some View {
        // A size chosen in Overwatch that Settings doesn't list selects nothing here;
        // the sizes shown are then those in the main display's shape.
        let current=model.resolution
        let shape=current.isSupported ? current.shape : DisplayResolution.initial(for:main).shape
        return VStack(alignment:.leading,spacing:12) {
            if let main { mainDisplay(main) }
            Text("Overwatch opens on the main display, the one with the menu bar. To use another, choose Displays… and set it as the main display.")
                .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VStack(alignment:.leading,spacing:4) {
                Toggle(isOn:Binding(get:{ model.rememberEachDisplay },set:{ model.setRememberEachDisplay($0) })) {
                    Text("Remember a resolution for each display").font(LauncherStyle.font(13,.medium))
                }.toggleStyle(.switch).tint(LauncherStyle.accent).disabled(model.busy)
                Text("Your MacBook screen and each monitor open at the resolution you last used on them.")
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:10) {
                GridRow {
                    Text("Shape").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    HStack(spacing:8) {
                        choice("16:10 · MacBook",selected:current.isSupported && current.shape == .macBook) {
                            model.chooseResolution(DisplayResolution(shape:.macBook,size:current.size))
                        }
                        choice("16:9 · Monitor & TV",selected:current.isSupported && current.shape == .monitor) {
                            model.chooseResolution(DisplayResolution(shape:.monitor,size:current.size))
                        }
                    }
                }
                GridRow {
                    Text("Size").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    HStack(spacing:8) {
                        ForEach(DisplayResolution.Size.allCases,id:\.self) { size in
                            let option=DisplayResolution(shape:shape,size:size)
                            choice(option.label,selected:current == option,dimmed:main.map { !$0.fits(option) } ?? false) {
                                model.chooseResolution(option)
                            }.help(main.map { $0.fits(option) } ?? true ? "" : "Larger than your main display can show")
                        }
                    }
                }
            }
            Text(caption).font(LauncherStyle.font(13)).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:6) {
                if model.displaySaved {
                    Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text("Saved").font(LauncherStyle.font(12,.medium))
                    Text("·").foregroundStyle(.secondary)
                }
                Text(model.rememberEachDisplay ? "Changes save for this display and apply the next time Overwatch starts." : "Changes save as you choose and apply the next time Overwatch starts.")
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.font(LauncherStyle.font(12)).animation(.easeOut(duration:0.15),value:model.displaySaved)
        }
    }
    private func mainDisplay(_ main:MainDisplay) -> some View {
        HStack(spacing:12) {
            Image(systemName:main.builtIn ? "laptopcomputer" : "display").font(.system(size:20)).foregroundStyle(.secondary).frame(width:30)
            VStack(alignment:.leading,spacing:2) {
                Text(main.name).font(LauncherStyle.font(14,.medium)).lineLimit(1)
                Text("Main display · \(main.size) · \(main.aspect)").font(LauncherStyle.font(12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength:8)
            Button("Displays…") {
                NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
            }.buttonStyle(.bordered).buttonBorderShape(.capsule).help("Open System Settings › Displays")
        }.padding(12).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:14,style:.continuous))
            .accessibilityElement(children:.combine)
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
        let source=choice.isSupported ? "" : "\(choice.label) was chosen in Overwatch. "
        guard let main else { return source+"Larger sizes look sharper and lower your frame rate." }
        return source+main.caption(for:choice)
    }
    private var battleNet:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                Toggle(isOn:$model.largeBattleNet) {
                    Text("Mac-sized Battle.net window").font(LauncherStyle.font(14,.semibold))
                }.toggleStyle(.switch).tint(LauncherStyle.accent)
                Text("Shows Battle.net at twice its Windows size, so it’s easy to read. Overwatch isn’t affected. Takes effect the next time Battle.net opens.")
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Divider().padding(.vertical,6)
                Toggle(isOn:$model.autoOpenBattleNet) {
                    Text("Open Battle.net when \(Brand.name) opens").font(LauncherStyle.font(14,.semibold))
                }.toggleStyle(.switch).tint(LauncherStyle.accent)
                Text("Turn off to start Battle.net yourself with Open Battle.net.")
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    /// Overwatch gets the HUD from Battle.net, which starts it; so the switch changes only
    /// while Battle.net is closed, and Settings offers to close it.
    private var metalHUD:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                Toggle(isOn:$model.metalHUD) {
                    Text("Metal Performance HUD").font(LauncherStyle.font(14,.semibold))
                }.toggleStyle(.switch).tint(LauncherStyle.accent).disabled(model.running != nil)
                Text("Shows Apple’s performance overlay in Overwatch: FPS, frame times, and when your Mac is compiling shaders, the cause of first-match stutters.")
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if let running=model.running {
                    HStack(spacing:12) {
                        Text(running == .game ? "Quit Overwatch to change this." : "Close Battle.net to change this.")
                            .font(LauncherStyle.font(12,.medium)).fixedSize(horizontal:false,vertical:true)
                        Spacer(minLength:8)
                        if running == .client {
                            Button("Close Battle.net",action:model.closeBattleNet).buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(model.busy)
                        }
                    }.padding(.top,6)
                }
            }
        }
    }
    private var troubleshooting:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:10) {
                Text("Troubleshooting").font(LauncherStyle.font(14,.semibold))
                action("Force Quit Overwatch & Battle.net",detail:"If the game stops responding.",button:"Force Quit") { confirmForceQuit=true }
                action("Repair Game Files…",detail:"If Overwatch won’t start. Takes a minute or two.",button:"Repair") { confirmRepair=true }
                action("Reset Display Settings…",detail:"If Overwatch opens to a black screen or at the wrong size.",button:"Reset") { confirmResetDisplay=true }

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
}
struct HelpSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reportExpanded=false
    @State private var expanded=Set<Int>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let questions:[(question:String, answer:String)]=[
        ("What are the best Overwatch settings?","In Overwatch’s Video settings, set Render Scale to 100%, Dynamic Render Scale to Off and Frame Rate to Custom, then restart Overwatch. Overwatch resets these whenever you change the graphics quality preset, so check them again after a preset change."),
        ("Why do my first matches stutter?","Your Mac prepares each of Overwatch’s graphics effects the first time it appears. The stutters fade as you play, and the prepared graphics are kept for next time."),
        ("How do I play on an external monitor?","Overwatch opens on your main display, the one with the menu bar. In System Settings › Displays, select the monitor and set Use as to Main display. Then choose your monitor’s resolution in Overwatch under Options › Video, for example 2560 × 1440 for a 1440p monitor or 5120 × 2160 for a 5K2K ultrawide. \(Brand.name) remembers it for that monitor, and your MacBook screen keeps its own."),
        ("“No compatible graphics hardware was found”","This can follow connecting or unplugging a display while Battle.net was open. Open Battle.net from \(Brand.name) rather than from the Dock: \(Brand.name) reopens it for your current displays."),
        ("Which resolution should I choose?","Your display’s own resolution gives the sharpest picture; a smaller one runs faster and is scaled up to fill the screen. Change it in Overwatch under Options › Video, or in Settings › Fullscreen resolution, which shows what each size looks like on your main display."),
        ("The game is black or the wrong size","Quit Overwatch, choose Settings › Reset Display Settings, then play again. Overwatch opens at 1080p; your graphics and FPS settings stay as they are."),
        ("I can’t find the game window","Select Overwatch or Battle.net in the Dock. If it’s still hidden, check your other desktops."),
        ("Battle.net shows a blank window","Close Battle.net, then open it again from \(Brand.name)."),
        ("Battle.net looks too big or cut off","Turn off Settings › Mac-sized Battle.net window, then close Battle.net and open it again from \(Brand.name)."),
        ("The game stopped responding","Choose Settings › Force Quit, then open Overwatch again. If it still won’t start, choose Settings › Repair Game Files."),
        ("Which Macs can play?","Macs with Apple silicon on macOS 15 or later, with Rosetta. 16 GB of memory is recommended, and a new installation needs about 85–95 GB of storage."),
        ("How do I uninstall?","Choose Settings › Uninstall \(Brand.name). \(Brand.name), Battle.net and Overwatch move to the Trash; your Blizzard account isn’t affected."),
        ("Found a bug?","Choose Report a Problem to open an issue on GitHub, and attach a support report (below): it lists your setup, never account details."),
    ]
    var body:some View {
        VStack(spacing:24) {
            LauncherHeading(title:"Help & FAQ",subtitle:"Quick answers to common questions.",compact:true)
            ScrollView {
                VStack(spacing:16) {
                    LauncherPanel(inset:0) {
                        VStack(spacing:0) {
                            ForEach(questions.indices,id:\.self) { index in
                                if index>0 { Divider().padding(.horizontal,20) }
                                question(index)
                            }
                        }
                    }
                    LauncherPanel(inset:0) {
                        VStack(spacing:0) {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration:0.18)) { reportExpanded.toggle() }
                            } label: {
                                HStack {
                                    Text("Support report").font(LauncherStyle.font(15,.semibold))
                                    Spacer()
                                    Image(systemName:reportExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                                }.padding(20).frame(maxWidth:.infinity).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityValue(reportExpanded ? "Expanded" : "Collapsed")
                                .accessibilityHint("Show or hide the report preview")
                            if reportExpanded {
                            VStack(alignment:.leading,spacing:16) {
                                Text("Review exactly what will be saved. Nothing is uploaded.")
                                    .font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                                Text(model.report).font(LauncherStyle.font(12)).textSelection(.enabled)
                                    .frame(maxWidth:.infinity,alignment:.leading).accessibilityLabel("Support report preview")
                                HStack {
                                    Button("Refresh",action:model.makeReport).buttonStyle(.borderless)
                                    Spacer()
                                    Button("Save Report…",action:model.saveReport).buttonStyle(.bordered).buttonBorderShape(.capsule)
                                }
                            }.padding(.horizontal,20).padding(.bottom,20)
                            }
                        }
                    }
                    RepositoryLink()
                }
            }.scrollIndicators(.hidden)
            HStack {
                Link(destination:Brand.issues) {
                    Label("Report a Problem",systemImage:"exclamationmark.bubble").font(LauncherStyle.font(13,.medium))
                }.buttonStyle(.borderless).help("Open a new issue on GitHub in your browser")
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:540,height:660)
            .tint(.primary).background { LauncherBackground() }
    }
    private func question(_ index:Int)->some View {
        let open=expanded.contains(index)
        return VStack(alignment:.leading,spacing:0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration:0.16)) { if open { expanded.remove(index) } else { expanded.insert(index) } }
            } label: {
                HStack(spacing:12) {
                    Text(questions[index].question).font(LauncherStyle.font(14,.semibold)).multilineTextAlignment(.leading)
                    Spacer(minLength:8)
                    Image(systemName:"chevron.down").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0)).accessibilityHidden(true)
                }.padding(.horizontal,20).padding(.vertical,14).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                Text(questions[index].answer).font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                    .padding(.horizontal,20).padding(.bottom,16)
            }
        }
    }
}
struct AboutSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var licenses=false
    private var version:String {
        "Version \(UpdateCheck.installed) · Build \(UpdateCheck.build)" + (model.release?.distribution == "private-preview" ? " · Private alpha" : "")
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
                    Text("Open source. Contributions welcome.").foregroundStyle(.secondary)
                    Button("Licenses") { licenses=true }.buttonStyle(.plain).underline()
                        .foregroundStyle(.secondary).help("Show \(Brand.name)’s license and notices")
                }.font(LauncherStyle.font(12))
            }
            LauncherPanel {
                VStack(alignment:.leading,spacing:18) {
                    HStack(alignment:.center,spacing:16) {
                        AuthorPhoto(size:64)
                        HStack(spacing:8) {
                            Text("Author:").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                            LinkedInLink()
                        }
                    }
                    // The owner's own words (final draft, October 1, 2026).
                    VStack(alignment:.leading,spacing:10) {
                        Text("Hey there!").font(LauncherStyle.font(13,.semibold))
                        Text("I’m Josh, I’m a graduate of UCSB’s Master of Technology Management Program and love building tech products! I have also been a part of the PC Overwatch community for 4+ years now and have always been fascinated by the idea of having Overwatch run on Apple Silicon. Mac has historically been known as a terrible place for gamers for many different reasons, but with the introduction of Apple Silicon in 2020, I feel like the tides have shifted and there is no better time than now for developers to refocus attention towards building native games for this platform. Especially with an immense Mac userbase waiting to be captured, I would love to see a day where Blizzard builds a native Overwatch port for Mac, but in the meantime, I hope \(Brand.name) can fill that place. I hope you enjoy :)")
                            .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                        Text("Best,\nJosh").fixedSize(horizontal:false,vertical:true)
                    }.font(LauncherStyle.font(13)).accessibilityElement(children:.combine)
                    Divider()
                    VStack(alignment:.leading,spacing:8) {
                        Text("Support my work").font(LauncherStyle.font(15,.semibold)).accessibilityAddTraits(.isHeader)
                        Text("If \(Brand.name) has helped you, you can support my work by trying Mosaic News, another free project of mine that shows how different outlets cover the same story, or by buying me a coffee.")
                            .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    HStack(spacing:10) {
                        MosaicButton(placement:.about)
                        CoffeeButton()
                    }
                }
            }
            Spacer(minLength:0)
            HStack(alignment:.bottom,spacing:20) {
                Text(Brand.trademarks).font(LauncherStyle.font(10.5)).lineSpacing(1).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width:520,height:880,alignment:.top).tint(.primary)
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
            SheetHero(symbol:"doc.text",title:"Licenses",
                      subtitle:"\(Brand.name) is open source under the Apache License 2.0. Wine, DXMT and the other components it includes keep their own licenses.")
            LauncherPanel {
                ScrollView {
                    Text(text.isEmpty ? "The license files are missing from this copy of \(Brand.name)." : text)
                        .font(.system(size:10.5,design:.monospaced)).lineSpacing(2).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }.frame(height:340)
            }
            HStack(spacing:16) {
                if let thirdParty {
                    Button("Third-Party Licenses") { NSWorkspace.shared.activateFileViewerSelecting([thirdParty]) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                        .help("Show the bundled third-party license files in Finder")
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:660)
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
                SheetHero(symbol:"trash",title:"Uninstall \(Brand.name)?",subtitle:"This removes the game, Battle.net and \(Brand.name) from your Mac.")
                LauncherPanel {
                    VStack(alignment:.leading,spacing:14) {
                        Text("What will be moved to the Trash").font(LauncherStyle.font(14,.semibold))
                        VStack(alignment:.leading,spacing:8) {
                            row("Overwatch", "The installed game and its settings")
                            row("Battle.net", "The Battle.net app set up by this app")
                            row(Brand.name, "This app and its setup files")
                        }
                        Divider()
                        Text("Your Blizzard account and any other Blizzard software on this Mac are not touched. Everything goes to the Trash, so you can put it back from Finder. Storage is freed once you empty the Trash.")
                            .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
                if case .failed(let message)=model.uninstall { LauncherNotice(text:message) }
                else { LauncherNotice(text:"Battle.net is closed for you if it’s open. Overwatch itself must be quit first. Nothing is removed until you choose Uninstall.") }
                HStack(spacing:16) {
                    Button("Cancel") { model.uninstall = .idle;dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    // Deliberately not the default action: Return never uninstalls.
                    Button(role:.destructive) { model.uninstallEverything() } label: { Text("Uninstall").font(LauncherStyle.font(15,.semibold)).padding(.horizontal,8) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(.red)
                }
            case .working:
                SheetHero(symbol:"trash",title:"Uninstalling",subtitle:model.stage == "Closing Battle.net" ? "Closing Battle.net first." : "Moving Overwatch, Battle.net and this app to the Trash.")
                ProgressView().controlSize(.small).accessibilityLabel("Uninstalling")
            case .done(let appRemoved):
                SheetHero(symbol:"checkmark",title:"Uninstalled",subtitle:appRemoved ? "Overwatch, Battle.net and this app are in the Trash." : "Overwatch and Battle.net are in the Trash.")
                LauncherNotice(text:appRemoved ? "Empty the Trash to free the storage. Quit to finish." : "\(Brand.name) couldn’t move itself to the Trash. Quit, then drag \(Brand.name) from Applications to the Trash and empty it.")
                Button("Quit") { model.quit() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:520)
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
                SheetHero(symbol:"arrow.down.circle",title:"Update available",subtitle:"\(Brand.name) \(item.version) is ready to install. You have \(UpdateCheck.installed).")
                LauncherPanel {
                    VStack(alignment:.leading,spacing:10) {
                        Text("What’s new").font(LauncherStyle.font(14,.semibold))
                        if item.notes.isEmpty {
                            Text("See the release notes for details.").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
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
                Text("Your game, settings and Battle.net sign-in are kept. The app reopens when it’s done.")
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing:16) {
                    Button("Later") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
                    Link("Release Notes",destination:item.page).font(LauncherStyle.font(13))
                    Spacer()
                    LauncherPrimaryAction(title:"Update Now",action:model.installUpdate).keyboardShortcut(.defaultAction).disabled(model.busy)
                }
            case .downloading(let fraction):
                SheetHero(symbol:"arrow.down.circle",title:"Downloading the update",subtitle:"\(Int(fraction*100))% · The app reopens when it’s done.")
                ProgressView(value:fraction).frame(maxWidth:360).accessibilityLabel("Download progress")
                Button("Cancel",action:model.cancelUpdateDownload).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            case .installing:
                SheetHero(symbol:"arrow.down.circle",title:"Installing the update",subtitle:"The app will reopen in a moment.")
                ProgressView().controlSize(.small).accessibilityLabel("Installing")
            case .upToDate:
                SheetHero(symbol:"checkmark",title:"You’re up to date",subtitle:"\(Brand.name) \(UpdateCheck.installed) is the latest version.")
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
            case .failed(let message):
                SheetHero(symbol:"exclamationmark",title:"Couldn’t check for updates",subtitle:message)
                HStack(spacing:16) {
                    Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    LauncherPrimaryAction(title:"Try Again") { model.checkForUpdates(manual:true) }.keyboardShortcut(.defaultAction)
                }
            case .checking, .idle:
                SheetHero(symbol:"arrow.triangle.2.circlepath",title:"Checking for updates",subtitle:"Asking GitHub for the latest version.")
                ProgressView().controlSize(.small).accessibilityLabel("Checking for updates")
                Button("Cancel") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:520)
            .tint(.primary).background { LauncherBackground() }
    }
}
struct WhatsNewSheet:View {
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"sparkles",title:"What’s new in \(WhatsNew.version)",subtitle:"\(Brand.name) \(UpdateCheck.installed)")
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
                Link("Release Notes",destination:Brand.releases).font(LauncherStyle.font(13))
                Spacer()
                LauncherPrimaryAction(title:"Continue") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:520)
            .tint(.primary).background { LauncherBackground() }
    }
}
