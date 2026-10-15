import SwiftUI
import AppKit

/// Help's sections, in tabs like Settings': answers to common questions, fixes for when
/// something goes wrong, and where to ask or report. Help opens on the one that fits
/// (AppModel.openHelp).
enum HelpTab:String, CaseIterable, Identifiable {
    case questions, troubleshooting, support
    var id:String { rawValue }
    var title:String {
        switch self {
        case .questions: return "FAQ"
        case .troubleshooting: return "Troubleshooting"
        case .support: return "Support"
        }
    }
    var symbol:String {
        switch self {
        case .questions: return "questionmark.circle"
        case .troubleshooting: return "wrench.and.screwdriver"
        case .support: return "lifepreserver"
        }
    }
}
/// One question or problem: why, what to do in order, anything worth knowing after, and a
/// button to where the steps point. Short, plain sentences; **bold** marks what to choose.
struct HelpTopic:Identifiable {
    enum Action { case settings(SettingsTab), displays, workshopCode }
    let id:String
    let symbol:String
    let title:String
    var answer:String?=nil
    var steps:[String]=[]
    var note:String?=nil
    var action:Action?=nil
}
extension HelpTopic {
    static let questions:[HelpTopic]=[
        HelpTopic(id:"stutter",symbol:"hourglass",title:"Why do my first matches stutter?",
                  answer:"The first time a map, hero or effect appears, your Mac builds the shaders that draw it, which can cause a brief stutter. After you quit Overwatch, \(Brand.name) prepares them for your next match, so stutters get rarer the more you play.",
                  note:"To get ahead of it, play Workshop code **929PJ** from Custom Games for 5 to 10 minutes before you queue.",
                  action:.workshopCode),
        HelpTopic(id:"shaders",symbol:"square.stack.3d.up",title:"What do the shader numbers mean?",
                  answer:ShaderInfo.what+"\n\n**Learned:** "+ShaderInfo.learned+"\n\n**Ready:** "+ShaderInfo.ready,
                  note:ShaderInfo.interrupted),
        HelpTopic(id:"settings",symbol:"slider.horizontal.3",title:"What are the best Overwatch settings?",
                  steps:["In Overwatch, open **Options › Video**.",
                         "Set **Render Scale** to 100%, **Dynamic Render Scale** to Off and **Frame Rate** to Custom.",
                         "Restart Overwatch."],
                  note:"Changing the graphics quality preset resets these, so check them again afterwards."),
        HelpTopic(id:"metalfx",symbol:"wand.and.stars",title:"How do I use MetalFX upscaling?",
                  answer:"Overwatch draws each frame at a lower resolution and Apple’s MetalFX rebuilds it at full resolution, so you get more FPS with a picture close to full resolution.",
                  steps:["Close Battle.net.",
                         "Turn on **Settings › Graphics › MetalFX upscaling**.",
                         "Play, then choose **NVIDIA DLSS** and a mode in Overwatch’s **Options › Video**."],
                  note:"Quality looks closest to full resolution; Performance and Ultra Performance give the most FPS.",
                  action:.settings(.graphics)),
        HelpTopic(id:"fps",symbol:"gauge.with.dots.needle.bottom.50percent",title:"How do I see my FPS?",
                  answer:"Turn on Apple’s Metal Performance HUD. It shows your FPS and frame times over the game, and when your Mac is preparing shaders.",
                  steps:["Close Battle.net.",
                         "Turn on **Settings › Graphics › Metal Performance HUD**.",
                         "Play from \(Brand.name)."],
                  note:"Battle.net picks up the setting when it opens. To hide the HUD, quit Overwatch, close Battle.net, turn the setting off and play again.",
                  action:.settings(.graphics)),
        HelpTopic(id:"monitor",symbol:"rectangle.connected.to.line.below",title:"How do I play on an external monitor?",
                  steps:["In **System Settings › Displays**, select the monitor and set **Use as** to Main display.",
                         "In Overwatch, choose the monitor’s resolution under **Options › Video**, for example 2560 × 1440 on a 1440p monitor."],
                  note:"\(Brand.name) remembers the resolution for that monitor, and your MacBook screen keeps its own.",
                  action:.displays),
        HelpTopic(id:"resolution",symbol:"aspectratio",title:"Which resolution should I choose?",
                  answer:"Your display’s own resolution gives the sharpest picture. A smaller one runs faster and is scaled up to fill the screen.",
                  note:"Change it in Overwatch under **Options › Video**, or in **Settings › Display**, which shows how each size looks on your main display.",
                  action:.settings(.display)),
        HelpTopic(id:"gpu",symbol:"cpu",title:"Why does Overwatch show an RTX 4090?",
                  answer:"That’s MetalFX upscaling. While it’s on, \(Brand.name) presents your Mac to Overwatch as an NVIDIA graphics card so the DLSS option appears. Your Mac’s own GPU does all the work.",
                  note:"NVIDIA Reflex has no effect while it’s on. Turning MetalFX upscaling off puts your Mac’s GPU back and keeps your other video settings.",
                  action:.settings(.graphics)),
        HelpTopic(id:"voice",symbol:"mic",title:"How do I use voice chat?",
                  steps:["Turn on the microphone in **Settings › Audio**.",
                         "Set up voice chat in Overwatch’s **Options › Sound**."],
                  note:"With AirPods or other Bluetooth headphones, voice chat uses your Mac’s built-in microphone when it has one, so your headphones keep their full sound quality.",
                  action:.settings(.audio)),
        HelpTopic(id:"account",symbol:"lock.shield",title:"Is it safe for my Blizzard account?",
                  answer:"You sign in to Battle.net itself, and \(Brand.name) never asks for your password. \(Brand.name) doesn’t modify Overwatch’s game files, inject code into the game or read its memory.",
                  note:"Blizzard doesn’t officially support playing Overwatch on a Mac, with \(Brand.name) or with anything else."),
        HelpTopic(id:"updates",symbol:"arrow.down.circle",title:"How do updates work?",
                  answer:"Overwatch updates through Battle.net, as usual. If a Blizzard or macOS update needs a fix on the Mac side, it arrives as a \(Brand.name) update. \(Brand.name) checks for new versions when it opens and lets you choose when to install them."),
        HelpTopic(id:"macs",symbol:"laptopcomputer",title:"Which Macs can play?",
                  answer:"Macs with Apple silicon on macOS 26.5 or later, with Rosetta. 16 GB of memory is recommended, and a new installation needs about 85–95 GB of storage."),
        HelpTopic(id:"uninstall",symbol:"trash",title:"How do I uninstall?",
                  answer:"Choose **Settings › Uninstall \(Brand.name)**. \(Brand.name), Battle.net and Overwatch move to the Trash; your Blizzard account isn’t affected."),
    ]
    static let troubleshooting:[HelpTopic]=[
        HelpTopic(id:"black",symbol:"rectangle.dashed",title:"The game is black or the wrong size",
                  steps:["Quit Overwatch.",
                         "Choose **Settings › Display › Reset Display Settings**.",
                         "Play again."],
                  note:"Your graphics quality and FPS settings stay as they are.",
                  action:.settings(.display)),
        HelpTopic(id:"frozen",symbol:"hand.raised",title:"The game stopped responding",
                  steps:["Choose **Settings › Advanced › Force Quit**.",
                         "Play again."],
                  note:"You can also right-click \(Brand.name) in the Dock and choose **Force Quit Overwatch & Battle.net**.",
                  action:.settings(.advanced)),
        HelpTopic(id:"start",symbol:"xmark.octagon",title:"Overwatch won’t start",
                  steps:["Quit Overwatch and close Battle.net.",
                         "Choose **Settings › Advanced › Repair Game Files**.",
                         "Play again."],
                  note:"Repair reinstalls the files \(Brand.name) adds and takes a minute or two. Overwatch, its settings and your Battle.net sign-in are kept.",
                  action:.settings(.advanced)),
        HelpTopic(id:"hitches",symbol:"waveform.path.ecg",title:"Matches stutter or freeze",
                  answer:"Brief stutters in your first matches are normal while your Mac prepares Overwatch’s shaders.",
                  steps:["Close other apps while you play. They compete with Overwatch for your Mac’s graphics, processor and memory.",
                         "Play Workshop code **929PJ** from Custom Games for 5 to 10 minutes, so your Mac prepares shaders ahead of time."],
                  action:.workshopCode),
        HelpTopic(id:"window",symbol:"macwindow.on.rectangle",title:"I can’t find the game window",
                  answer:"Choose **Show Overwatch** in \(Brand.name), or select Overwatch in the Dock. If it’s still hidden, check your other desktops."),
        HelpTopic(id:"blank",symbol:"macwindow",title:"Battle.net shows a blank window",
                  answer:"Close Battle.net, then open it again from \(Brand.name)."),
        // Issue #33: the page that hands an Xbox sign-in back to Battle.net reports to
        // Battle.net on 127.0.0.1, and Safari blocks that as mixed content.
        HelpTopic(id:"xbox",symbol:"person.badge.key",title:"Battle.net keeps waiting after I sign in with Xbox",
                  steps:["Set Firefox as your default browser.",
                         "In Firefox, allow **account.battle.net** to access apps on this device, and pause extensions and tracking protection.",
                         "Sign in again from Battle.net."],
                  note:"Safari blocks the page that hands your sign-in back to Battle.net. You stay signed in afterwards, so you can switch everything back."),
        HelpTopic(id:"size",symbol:"arrow.up.left.and.arrow.down.right",title:"Battle.net looks too big or too small",
                  answer:"This can happen after you connect, unplug or rearrange displays while Battle.net is open. Close Battle.net, then open it again from \(Brand.name)."),
        HelpTopic(id:"hardware",symbol:"display.trianglebadge.exclamationmark",title:"“No compatible graphics hardware was found”",
                  answer:"This can happen after you connect or unplug a display while Battle.net is open. Open Battle.net from \(Brand.name), not from the Dock: \(Brand.name) reopens it for your current displays."),
        HelpTopic(id:"mic",symbol:"mic.slash",title:"My team can’t hear me",
                  steps:["In **Settings › Audio**, if the microphone is off, choose **Turn On…**.",
                         "Switch on \(Brand.name) in System Settings, then open \(Brand.name) again.",
                         "Check the voice chat settings in Overwatch’s **Options › Sound**."],
                  action:.settings(.audio)),
        HelpTopic(id:"output",symbol:"speaker.wave.2",title:"Sound plays from the wrong speakers",
                  answer:"Overwatch keeps the sound output that was selected when it started.",
                  steps:["Quit Overwatch.",
                         "Connect your headphones and select them on your Mac.",
                         "Play again."]),
        HelpTopic(id:"proxy",symbol:"network",title:"Battle.net can’t connect on a work or school network",
                  answer:"Some of these networks set up their proxy automatically.",
                  steps:["Close Battle.net.",
                         "Turn on **Settings › Advanced › Detect network proxy automatically**.",
                         "Open Battle.net again from \(Brand.name)."],
                  action:.settings(.advanced)),
        HelpTopic(id:"korean",symbol:"person.crop.circle.badge.exclamationmark",title:"Overwatch closes as it starts on a Korean account",
                  answer:"Korean accounts linked to Nexon need Korean account support (한국 계정 지원), an experimental option.",
                  steps:["Close Battle.net.",
                         "Turn on **Settings › Advanced › Korean account support**.",
                         "Play from \(Brand.name)."],
                  action:.settings(.advanced)),
    ]
}
struct HelpSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One topic open at a time, so a long answer never buries the list.
    @State private var open:String?
    @State private var showReport=false
    /// What was just copied ("report" or "code"), for two seconds of "Copied".
    @State private var copied:String?
    /// Quieter than the answers, still easy to read (secondary text is too faint here).
    private static let quiet=Color.primary.opacity(0.72)
    var body:some View {
        VStack(spacing:16) {
            LauncherHeading(title:"Help & FAQ",subtitle:"",compact:true)
            LauncherTabs(tabs:HelpTab.allCases,selection:$model.helpTab,width:118,title:\.title,symbol:\.symbol)
            ScrollView {
                page.padding(.bottom,2)
            }.scrollIndicators(.never)
            HStack {
                if model.helpTab != .support {
                    Button { model.helpTab = .support } label: {
                        Label("Still stuck? Get Support",systemImage:"lifepreserver").font(LauncherStyle.font(13,.medium))
                    }.buttonStyle(.borderless).help("Ask on Discord or report a bug")
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
                    .closesOnEscape { dismiss() }
            }
        }.font(LauncherStyle.font(14)).padding(.horizontal,32).padding(.vertical,28)
            .frame(width:LauncherStyle.sheetWidth,height:LauncherStyle.largeSheetHeight)
            .tint(.primary).background { LauncherBackground() }
            .onAppear { open=model.helpTopic;model.helpTopic=nil }
            .onChange(of:model.helpTab) { open=nil;showReport=false }
            .task(id:copied) { if copied != nil { try? await Task.sleep(for:.seconds(2));copied=nil } }
    }
    @ViewBuilder private var page:some View {
        switch model.helpTab {
        case .questions: topics(HelpTopic.questions)
        case .troubleshooting: topics(HelpTopic.troubleshooting)
        case .support: support
        }
    }
    private func topics(_ list:[HelpTopic])->some View {
        LauncherPanel(inset:0) {
            VStack(spacing:0) {
                ForEach(list) { topic in
                    if topic.id != list.first?.id { Divider().padding(.leading,54).padding(.trailing,20) }
                    row(topic)
                }
            }
        }
    }
    private func row(_ topic:HelpTopic)->some View {
        let isOpen=open == topic.id
        return VStack(alignment:.leading,spacing:0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration:0.16)) { open = isOpen ? nil : topic.id }
            } label: {
                HStack(spacing:12) {
                    Image(systemName:topic.symbol).font(.system(size:15,weight:.medium)).foregroundStyle(LauncherStyle.accent)
                        .frame(width:22).accessibilityHidden(true)
                    Text(topic.title).font(LauncherStyle.font(14,.semibold)).multilineTextAlignment(.leading)
                    Spacer(minLength:8)
                    Image(systemName:"chevron.down").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0)).accessibilityHidden(true)
                }.padding(.horizontal,20).padding(.vertical,13).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen { detail(topic).padding(.leading,54).padding(.trailing,20).padding(.bottom,18) }
        }
    }
    private func detail(_ topic:HelpTopic)->some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach((topic.answer ?? "").components(separatedBy:"\n\n").filter { !$0.isEmpty },id:\.self) { Text(rich($0)) }
            if !topic.steps.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(topic.steps.indices,id:\.self) { index in step(index+1,topic.steps[index]) }
                }
            }
            if let note=topic.note { Text(rich(note)).foregroundStyle(Self.quiet) }
            if let action=topic.action { button(action).padding(.top,2) }
        }.font(LauncherStyle.font(13)).lineSpacing(3).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
    }
    private func step(_ number:Int,_ text:String)->some View {
        HStack(alignment:.firstTextBaseline,spacing:10) {
            Text("\(number)").font(LauncherStyle.font(11,.bold)).monospacedDigit().foregroundStyle(LauncherStyle.ink)
                .frame(width:19,height:19).background(LauncherStyle.accent,in:Circle())
            Text(rich(text))
        }.accessibilityElement(children:.combine)
    }
    @ViewBuilder private func button(_ action:HelpTopic.Action)->some View {
        switch action {
        case .settings(let tab):
            Button("Open \(tab.title) Settings") { model.settingsTab=tab;model.sheet = .settings }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(model.screen == .moveApp)
        case .displays:
            Button("Open Displays in System Settings",action:SettingsSheet.openDisplaySettings)
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
        case .workshopCode:
            Button(copied == "code" ? "Copied" : "Copy Code \(FirstMatchTip.workshopCode)") {
                copy(FirstMatchTip.workshopCode);copied="code"
            }.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
    /// Where to ask (the community) and how to report a bug (GitHub, with the report).
    private var support:some View {
        VStack(spacing:16) {
            DiscordLink()
            LauncherPanel(inset:20) {
                VStack(alignment:.leading,spacing:16) {
                    HStack(spacing:12) {
                        Image(systemName:"ladybug").font(.system(size:17,weight:.medium)).foregroundStyle(LauncherStyle.accent)
                            .frame(width:22).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:2) {
                            Text("Report a bug").font(LauncherStyle.font(15,.semibold)).accessibilityAddTraits(.isHeader)
                            Text("Bugs go on GitHub, where they can be tracked and fixed.").font(LauncherStyle.font(13)).foregroundStyle(Self.quiet)
                        }
                    }
                    Divider()
                    reportStep(1,"Save or copy your support report",
                               "It lists your Mac, your macOS and \(Brand.name) versions, your display, a few settings and the last setup steps. Never account details. Nothing is uploaded.") {
                        HStack(spacing:8) {
                            Button(copied == "report" ? "Copied" : "Copy") { model.makeReport();copy(model.report);copied="report" }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityLabel(copied == "report" ? "Copied" : "Copy support report")
                            Button("Save…") { model.makeReport();model.saveReport() }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityLabel("Save support report")
                            Spacer(minLength:8)
                            Button(showReport ? "Hide Report" : "Show Report") {
                                if !showReport { model.makeReport() }
                                withAnimation(reduceMotion ? nil : .easeOut(duration:0.15)) { showReport.toggle() }
                            }.buttonStyle(.borderless).font(LauncherStyle.font(13,.medium))
                        }
                    }
                    if showReport {
                        ScrollView {
                            Text(model.report).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                                .frame(maxWidth:.infinity,alignment:.leading).padding(12)
                        }.frame(height:150).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12,style:.continuous))
                            .padding(.leading,29).accessibilityLabel("Support report preview")
                    }
                    reportStep(2,"Open an issue on GitHub and attach the report","Say what you did and what happened.") {
                        Button { openURL(Brand.issues) } label: {
                            Label("Report on GitHub",systemImage:"arrow.up.right")
                        }.buttonStyle(.bordered).buttonBorderShape(.capsule).help("Open a new issue on GitHub in your browser")
                    }
                }
            }
        }
    }
    private func reportStep<Buttons:View>(_ number:Int,_ title:String,_ detail:String,@ViewBuilder buttons:()->Buttons)->some View {
        HStack(alignment:.firstTextBaseline,spacing:10) {
            Text("\(number)").font(LauncherStyle.font(11,.bold)).monospacedDigit().foregroundStyle(LauncherStyle.ink)
                .frame(width:19,height:19).background(LauncherStyle.accent,in:Circle()).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:10) {
                VStack(alignment:.leading,spacing:3) {
                    Text(title).font(LauncherStyle.font(14,.semibold))
                    Text(detail).font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(Self.quiet).fixedSize(horizontal:false,vertical:true)
                }
                buttons()
            }
        }
    }
    private func rich(_ text:String)->AttributedString {
        (try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    private func copy(_ text:String) {
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
    }
}
