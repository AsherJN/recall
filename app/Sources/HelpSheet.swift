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
        case .questions: return L("FAQ")
        case .troubleshooting: return L("Troubleshooting")
        case .support: return L("Support")
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
/// A topic with regions shows only to players on one of them (AppModel.currentRegion).
struct HelpTopic:Identifiable {
    enum Action { case settings(SettingsTab), displays, workshopCode }
    let id:String
    let symbol:String
    let title:String
    var answer:String?=nil
    var steps:[String]=[]
    var note:String?=nil
    var action:Action?=nil
    var regions:[BattleNetRegion]=[]
}
extension HelpTopic {
    /// The first-matches stutter, as the Play screen's tip tells it (FirstMatchTip; REC-13): how
    /// long it lasts by players' reports, two ways to speed it up, and when it isn't the warm-up.
    static var stutterAnswer:String { L("Your Mac builds each shader the first time Overwatch uses it, which causes a stutter. After each match, {0} prepares what it learned, so matches get smoother. Most players are smooth within 5 to 10 matches, or about 10,000 to 15,000 shaders.",Brand.name) }
    static var hitchesAnswer:String { L("Stutters in your first 5 to 10 matches are normal while your Mac learns Overwatch.") }
    static var closeApps:String { L("Close other apps while you play. They compete with Overwatch for your Mac’s graphics, processor and memory.") }
    static func fiveHundred(or:Bool)->String {
        or ? L("Or open **Play › Custom Games**, search for **500%** and join a game.")
           : L("Open **Play › Custom Games**, search for **500%** and join a game.")
    }
    static var pastWarmUp:String { L("Still stuttering after 15,000 shaders? Send a report from the **Support** tab.") }
    static let questions:[HelpTopic]=[
        HelpTopic(id:"stutter",symbol:"hourglass",title:L("Why do my first matches stutter?"),
                  answer:HelpTopic.stutterAnswer,
                  note:L("To speed it up, play Workshop code **{0}** for 5 to 10 minutes: choose **Play › Custom Games › Create › Settings › Import Code**, paste the code and start. Or open **Play › Custom Games**, search for **500%** and join a game.",FirstMatchTip.workshopCode)+"\n\n"+HelpTopic.pastWarmUp,
                  action:.workshopCode,regions:[.global,.korea]),
        // China's servers don't take the global 929PJ code (NetEase): custom games' 500% alone.
        HelpTopic(id:"stutter",symbol:"hourglass",title:L("Why do my first matches stutter?"),
                  answer:HelpTopic.stutterAnswer,
                  note:L("To speed it up, open **Play › Custom Games**, search for **500%** and join a game.")+"\n\n"+HelpTopic.pastWarmUp,
                  regions:[.china]),
        HelpTopic(id:"shaders",symbol:"square.stack.3d.up",title:L("What do the shader numbers mean?"),
                  answer:ShaderInfo.what+"\n\n"+L("**Learned:** {0}",ShaderInfo.learned)+"\n\n"+L("**Ready:** {0}",ShaderInfo.ready),
                  note:ShaderInfo.interrupted),
        HelpTopic(id:"settings",symbol:"slider.horizontal.3",title:L("What are the best Overwatch settings?"),
                  steps:[L("In Overwatch, open **Options › Video**."),
                         L("Set **Render Scale** to 100%, **Dynamic Render Scale** to Off and **Frame Rate** to Custom."),
                         L("Restart Overwatch.")],
                  note:L("Changing the graphics quality preset resets these, so check them again afterwards.")),
        // In a match the window driver aims with GCMouse's counts; trackpads keep pointer events
        // (patches/wine-mouselook.patch, wine-winemac-activation.patch).
        HelpTopic(id:"acceleration",symbol:"computermouse",title:L("Should I turn off mouse acceleration?"),
                  answer:L("You don’t need to. In a match, {0} reads your mouse’s own movement, as Windows does for games, so macOS’s mouse acceleration and tracking speed don’t change your aim. Your sensitivity in Overwatch does.",Brand.name),
                  note:L("They still move the pointer in Overwatch’s menus. A trackpad aims with the macOS pointer, acceleration included.")),
        HelpTopic(id:"metalfx",symbol:"wand.and.stars",title:L("How do I use MetalFX upscaling?"),
                  answer:L("Overwatch draws each frame at a lower resolution and Apple’s MetalFX rebuilds it at full resolution, so you get more FPS with a picture close to full resolution."),
                  steps:[L("Close Battle.net."),
                         L("Turn on **Settings › Graphics › MetalFX upscaling**."),
                         L("Play, then choose **NVIDIA DLSS** and a mode in Overwatch’s **Options › Video**.")],
                  note:L("Quality looks closest to full resolution; Performance and Ultra Performance give the most FPS."),
                  action:.settings(.graphics)),
        HelpTopic(id:"fps",symbol:"gauge.with.dots.needle.bottom.50percent",title:L("How do I see my FPS?"),
                  answer:L("Turn on Apple’s Metal Performance HUD. It shows your FPS and frame times over the game, and when your Mac is preparing shaders."),
                  steps:[L("Close Battle.net."),
                         L("Turn on **Settings › Graphics › Metal Performance HUD**."),
                         L("Play from {0}.",Brand.name)],
                  note:L("Battle.net picks up the setting when it opens. To hide the HUD, quit Overwatch, close Battle.net, turn the setting off and play again."),
                  action:.settings(.graphics)),
        HelpTopic(id:"monitor",symbol:"rectangle.connected.to.line.below",title:L("How do I play on an external monitor?"),
                  steps:[L("In **System Settings › Displays**, select the monitor and set **Use as** to Main display."),
                         L("In Overwatch, choose the monitor’s resolution under **Options › Video**, for example 2560 × 1440 on a 1440p monitor.")],
                  note:L("{0} remembers the resolution for that monitor, and your MacBook screen keeps its own.",Brand.name),
                  action:.displays),
        HelpTopic(id:"resolution",symbol:"aspectratio",title:L("Which resolution should I choose?"),
                  answer:L("Your display’s own resolution gives the sharpest picture. A smaller one runs faster and is scaled up to fill the screen."),
                  note:L("Change it in Overwatch under **Options › Video**, or in **Settings › Display**, which shows how each size looks on your main display."),
                  action:.settings(.display)),
        HelpTopic(id:"gpu",symbol:"cpu",title:L("Why does Overwatch show an RTX 4090?"),
                  answer:L("That’s MetalFX upscaling. While it’s on, {0} presents your Mac to Overwatch as an NVIDIA graphics card so the DLSS option appears. Your Mac’s own GPU does all the work.",Brand.name),
                  note:L("NVIDIA Reflex has no effect while it’s on. Turning MetalFX upscaling off puts your Mac’s GPU back and keeps your other video settings."),
                  action:.settings(.graphics)),
        HelpTopic(id:"voice",symbol:"mic",title:L("How do I use voice chat?"),
                  steps:[L("Turn on the microphone in **Settings › Audio**."),
                         L("Set up voice chat in Overwatch’s **Options › Sound**.")],
                  note:L("With AirPods or other Bluetooth headphones, voice chat uses your Mac’s built-in microphone when it has one, so your headphones keep their full sound quality."),
                  action:.settings(.audio)),
        HelpTopic(id:"account",symbol:"lock.shield",title:L("Is it safe for my Blizzard account?"),
                  answer:L("You sign in to Battle.net itself, and {0} never asks for your password. {0} doesn’t modify Overwatch’s game files, inject code into the game or read its memory.",Brand.name),
                  note:L("Blizzard doesn’t officially support playing Overwatch on a Mac, with {0} or with anything else.",Brand.name),
                  regions:[.global]),
        HelpTopic(id:"account-korea",symbol:"lock.shield",title:L("Is it safe for my Korean account?"),
                  answer:L("You sign in to Battle.net itself, and {0} never asks for your password. {0} doesn’t modify Overwatch’s game files, inject code into the game or read its memory.",Brand.name),
                  note:L("Overwatch in Korea includes Nexon’s anti-cheat. {0} doesn’t turn it off, but Nexon doesn’t support playing on a Mac, so playing this way could affect your account.",Brand.name),
                  regions:[.korea]),
        HelpTopic(id:"account-china",symbol:"lock.shield",title:L("Is it safe for my NetEase account?"),
                  answer:L("You sign in to Battle.net itself, and {0} never asks for your password. {0} doesn’t modify Overwatch’s game files, inject code into the game or read its memory.",Brand.name),
                  note:L("Overwatch in China includes NetEase’s anti-cheat. Recall doesn’t turn it off, but NetEase doesn’t support playing on a Mac, so playing this way could affect your account."),
                  regions:[.china]),
        HelpTopic(id:"updates",symbol:"arrow.down.circle",title:L("How do updates work?"),
                  answer:L("Overwatch updates through Battle.net, as usual. If a Blizzard or macOS update needs a fix on the Mac side, it arrives as a {0} update. {0} checks for new versions when it opens and lets you choose when to install them.",Brand.name)),
        // REC-40: logging (Settings › Advanced) and Save Logs (LogBundle).
        HelpTopic(id:"logs",symbol:"doc.text.magnifyingglass",title:L("How do I save logs for a bug report?"),
                  steps:[L("Close Battle.net."),
                         L("In **Settings › Advanced › Logging**, choose the kind of problem."),
                         L("Play until the problem happens again, then quit Overwatch."),
                         L("Choose **Save Logs** in Settings › Advanced or Help › Support, and attach the file to your GitHub issue."),
                         L("Turn logging off again.")],
                  note:L("Logging can lower your FPS while it’s on. Save Logs also works with logging off, with the logs Battle.net and Overwatch keep. Before saving, {0} removes personal details such as your Mac’s name and your Battle.net account numbers.",Brand.name),
                  action:.settings(.advanced)),
        HelpTopic(id:"china",symbol:"globe.asia.australia",title:L("How do I play on China’s Battle.net (国服)?"),
                  answer:L("China’s Battle.net uses NetEase accounts. Choose China when you set up {0}, or later in **Settings › General › Battle.net region**.",Brand.name),
                  note:L("Accounts don’t carry over between Global and China’s Battle.net, so switching sets up Battle.net and Overwatch again."),
                  action:.settings(.general)),
        HelpTopic(id:"korea",symbol:"person.crop.circle.badge.checkmark",title:L("How do I play on a Korean account?"),
                  answer:L("Korean accounts linked to Nexon need {0}’s Korea region. Choose Korea when you set up {0}, or later in **Settings › General › Battle.net region**.",Brand.name),
                  note:L("Korea uses Global’s Battle.net, so switching between them keeps your installation."),
                  action:.settings(.general)),
        HelpTopic(id:"language",symbol:"character.bubble",title:L("How do I change {0}’s language?",Brand.name),
                  answer:L("{0} uses your Mac’s language: English, Simplified Chinese or Korean.",Brand.name),
                  steps:[L("Open **System Settings › General › Language & Region**."),
                         L("Under **Applications**, add {0} and choose a language for it.",Brand.name),
                         L("Quit {0} and open it again.",Brand.name)],
                  note:L("Battle.net and Overwatch keep their own language settings, in Battle.net’s settings.")),
        HelpTopic(id:"macs",symbol:"laptopcomputer",title:L("Which Macs can play?"),
                  answer:L("Macs with Apple silicon on macOS 26.5 or later, with Rosetta. 16 GB of memory is recommended, and a new installation needs about 85–95 GB of storage.")),
        HelpTopic(id:"uninstall",symbol:"trash",title:L("How do I uninstall?"),
                  answer:L("Choose **Settings › Uninstall {0}**. {0}, Battle.net and Overwatch move to the Trash; your Blizzard account isn’t affected.",Brand.name)),
    ]
    static let troubleshooting:[HelpTopic]=[
        HelpTopic(id:"black",symbol:"rectangle.dashed",title:L("The game is black or the wrong size"),
                  steps:[L("Quit Overwatch."),
                         L("Choose **Settings › Display › Reset Display Settings**."),
                         L("Play again.")],
                  note:L("Your graphics quality and FPS settings stay as they are."),
                  action:.settings(.display)),
        HelpTopic(id:"frozen",symbol:"hand.raised",title:L("The game stopped responding"),
                  steps:[L("Choose **Settings › Advanced › Force Quit**."),
                         L("Play again.")],
                  note:L("You can also right-click {0} in the Dock and choose **Force Quit Overwatch & Battle.net**.",Brand.name),
                  action:.settings(.advanced)),
        HelpTopic(id:"start",symbol:"xmark.octagon",title:L("Overwatch won’t start"),
                  steps:[L("Quit Overwatch and close Battle.net."),
                         L("Choose **Settings › Advanced › Repair Game Files**."),
                         L("Play again.")],
                  note:L("Repair reinstalls the files {0} adds and takes a minute or two. Overwatch, its settings and your Battle.net sign-in are kept.",Brand.name),
                  action:.settings(.advanced)),
        HelpTopic(id:"crashes",symbol:"exclamationmark.triangle",title:L("Overwatch crashes or shows graphics glitches"),
                  steps:[L("Quit Overwatch and close Battle.net."),
                         L("Choose **Settings › Graphics › Clear Shader Cache**."),
                         L("Play again.")],
                  note:L("Your next few matches stutter again while your Mac relearns your shaders. Your game files and settings stay as they are."),
                  action:.settings(.graphics)),
        HelpTopic(id:"hitches",symbol:"waveform.path.ecg",title:L("Matches stutter or freeze"),
                  answer:HelpTopic.hitchesAnswer,
                  steps:[HelpTopic.closeApps,
                         L("Play Workshop code **{0}** for 5 to 10 minutes, so your Mac prepares shaders ahead of time. In Overwatch, choose **Play › Custom Games › Create › Settings › Import Code**, paste the code, then start the game.",FirstMatchTip.workshopCode),
                         HelpTopic.fiveHundred(or:true)],
                  note:HelpTopic.pastWarmUp,
                  action:.workshopCode,regions:[.global,.korea]),
        HelpTopic(id:"hitches",symbol:"waveform.path.ecg",title:L("Matches stutter or freeze"),
                  answer:HelpTopic.hitchesAnswer,
                  steps:[HelpTopic.closeApps,HelpTopic.fiveHundred(or:false)],
                  note:HelpTopic.pastWarmUp,
                  regions:[.china]),
        // The long form of the Play screen's busy note (PerformanceTip, REC-5).
        HelpTopic(id:"slower",symbol:"gauge.with.dots.needle.33percent",title:L("My FPS is lower than usual"),
                  answer:L("Other apps, Low Power Mode and a hot Mac all take speed away from Overwatch. {0} names each one on the Play screen when it finds it.",Brand.name),
                  steps:[L("Quit apps that are using a lot of your Mac, such as browsers playing video, other games or apps exporting video. {0} lists them with a **Quit** button.",Brand.name),
                         L("Turn off Low Power Mode in **System Settings › Battery** (**Energy** on a Mac without a battery). It slows your Mac down to save energy."),
                         L("Let a hot Mac cool down. When it’s very warm, macOS slows it down to cool it, and your FPS stays lower until it cools.")]),
        // October 20: a 16 GB Mac up six days kept Overwatch's memory squeezed; movement and aim
        // answered late while FPS held, until a restart (BusyApps.lowMemory, the Play screen's note).
        HelpTopic(id:"delayed",symbol:"keyboard",title:L("My controls feel delayed"),
                  answer:L("When your Mac runs low on memory, Overwatch has to wait for it. Your movement and aim then respond late even though your FPS looks normal, most in your first minute in a map or when you come back from another app."),
                  steps:[L("Quit apps you aren’t using. When your Mac is low on memory, {0} lists the apps using the most on the Play screen, with a **Quit** button.",Brand.name),
                         L("If you haven’t restarted your Mac in days, restart it. Over time macOS itself can hold on to memory, and a restart frees it.")]),
        HelpTopic(id:"window",symbol:"macwindow.on.rectangle",title:L("I can’t find the game window"),
                  answer:L("Choose **Show Overwatch** in {0}, or select Overwatch in the Dock. If it’s still hidden, check your other desktops.",Brand.name)),
        HelpTopic(id:"blank",symbol:"macwindow",title:L("Battle.net shows a blank window"),
                  answer:L("Close Battle.net, then open it again from {0}.",Brand.name)),
        // Issue #33: the page that hands an Xbox sign-in back to Battle.net reports to
        // Battle.net on 127.0.0.1, and Safari blocks that as mixed content.
        HelpTopic(id:"xbox",symbol:"person.badge.key",title:L("Battle.net keeps waiting after I sign in with Xbox"),
                  steps:[L("Set Firefox as your default browser."),
                         L("In Firefox, allow **account.battle.net** to access apps on this device, and pause extensions and tracking protection."),
                         L("Sign in again from Battle.net.")],
                  note:L("Safari blocks the page that hands your sign-in back to Battle.net. You stay signed in afterwards, so you can switch everything back."),
                  regions:[.global,.korea]),
        // China's Battle.net signs in with a NetEase account in the browser and hands it back
        // the same way; players report Chrome and Firefox work and Safari doesn't (issue #23).
        HelpTopic(id:"netease",symbol:"person.badge.key",title:L("Battle.net keeps waiting after I sign in with NetEase"),
                  steps:[L("In **System Settings › Desktop & Dock**, set Chrome or Firefox as your default web browser."),
                         L("Sign in again from Battle.net. If your browser asks to access apps or devices on your network, choose **Allow**.")],
                  note:L("Safari blocks the page that hands your sign-in back to Battle.net. You stay signed in afterwards, so you can switch everything back."),
                  regions:[.china]),
        HelpTopic(id:"size",symbol:"arrow.up.left.and.arrow.down.right",title:L("Battle.net looks too big or too small"),
                  answer:L("This can happen after you connect, unplug or rearrange displays while Battle.net is open. Close Battle.net, then open it again from {0}.",Brand.name)),
        HelpTopic(id:"hardware",symbol:"display.trianglebadge.exclamationmark",title:L("“No compatible graphics hardware was found”"),
                  answer:L("This can happen after you connect or unplug a display while Battle.net is open. Open Battle.net from {0}, not from the Dock: {0} reopens it for your current displays.",Brand.name)),
        HelpTopic(id:"mic",symbol:"mic.slash",title:L("My team can’t hear me"),
                  steps:[L("In **Settings › Audio**, if the microphone is off, choose **Turn On…**."),
                         L("Switch on {0} in System Settings, then open {0} again.",Brand.name),
                         L("Check the voice chat settings in Overwatch’s **Options › Sound**.")],
                  action:.settings(.audio)),
        HelpTopic(id:"output",symbol:"speaker.wave.2",title:L("Sound plays from the wrong speakers"),
                  answer:L("Overwatch keeps the sound output that was selected when it started."),
                  steps:[L("Quit Overwatch."),
                         L("Connect your headphones and select them on your Mac."),
                         L("Play again.")]),
        HelpTopic(id:"proxy",symbol:"network",title:L("Battle.net can’t connect on a work or school network"),
                  answer:L("Some of these networks set up their proxy automatically."),
                  steps:[L("Close Battle.net."),
                         L("Turn on **Settings › Advanced › Detect network proxy automatically**."),
                         L("Open Battle.net again from {0}.",Brand.name)],
                  action:.settings(.advanced)),
        HelpTopic(id:"korean",symbol:"person.crop.circle.badge.exclamationmark",title:L("Overwatch closes as it starts on a Korean account"),
                  answer:L("Korean accounts linked to Nexon need {0}’s Korea region.",Brand.name),
                  steps:[L("Close Battle.net."),
                         L("In **Settings › General › Battle.net region**, choose **Korea**."),
                         L("Play from {0}.",Brand.name)],
                  action:.settings(.general),
                  regions:[.global]),
    ]
    /// What a search looks through: the question and its whole answer, as the player reads them.
    var searchText:String { HelpTopic.folded(([title,answer ?? ""]+steps+[note ?? ""]).joined(separator:"\n")) }
    /// The topics where every word of the query appears, those with it in the question first.
    /// Chinese and Korean match as typed, spaces or not.
    static func search(_ query:String,in topics:[HelpTopic])->[HelpTopic] {
        let words=folded(query).split(whereSeparator:\.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let found=topics.filter { topic in words.allSatisfy { topic.searchText.contains($0) } }
        let inTitle=found.filter { topic in words.allSatisfy { folded(topic.title).contains($0) } }
        return inTitle+found.filter { topic in !inTitle.contains { $0.id == topic.id } }
    }
    /// Ignores case, accents and full- or half-width forms, the ** that marks bold, and curly
    /// quotes (players type "won't", answers say "won’t").
    static func folded(_ text:String)->String {
        text.replacingOccurrences(of:"**",with:"").replacingOccurrences(of:"’",with:"'").replacingOccurrences(of:"‘",with:"'")
            .replacingOccurrences(of:"“",with:"\"").replacingOccurrences(of:"”",with:"\"")
            .folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:nil)
    }
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
    /// A search looks through FAQ and Troubleshooting together, whichever tab is open.
    private var query:String { get { model.helpQuery } nonmutating set { model.helpQuery=newValue } }
    @FocusState private var searchFocused:Bool
    private var searching:Bool { !query.trimmingCharacters(in:.whitespaces).isEmpty }
    /// Quieter than the answers, still easy to read (secondary text is too faint here).
    private static let quiet=Color.primary.opacity(0.72)
    var body:some View {
        VStack(spacing:16) {
            LauncherHeading(title:L("Help & FAQ"),subtitle:"",compact:true)
            // Choosing a tab, even the one already chosen, ends a search.
            LauncherTabs(tabs:HelpTab.allCases,selection:Binding(get:{ model.helpTab },set:{ query="";model.helpTab=$0 }),
                         width:118,showsSelection:!searching,title:\.title,symbol:\.symbol)
            searchField
            ScrollView {
                page.padding(.bottom,2)
            }.scrollIndicators(.never)
            HStack {
                if model.helpTab != .support || searching {
                    Button { query="";model.helpTab = .support } label: {
                        Label(L("Still stuck? Get Support"),systemImage:"lifepreserver").font(LauncherStyle.font(13,.medium))
                    }.buttonStyle(.borderless).help(model.showsDiscord ? L("Ask on Discord or report a bug") : L("Ask or report a bug on GitHub"))
                }
                Spacer()
                // Return in the search field opens the first answer instead of closing Help.
                Button(L("Done")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                    .keyboardShortcut(searchFocused ? nil : .defaultAction)
                    // Esc clears a search first (Main.swift), then closes Help.
                    .closesOnEscape { dismiss() }
            }
        }.font(LauncherStyle.font(14)).padding(.horizontal,32).padding(.vertical,28)
            .frame(width:LauncherStyle.sheetWidth,height:LauncherStyle.largeSheetHeight)
            .tint(.primary).background { LauncherBackground() }
            .background {
                Button("") { searchFocused=true }.keyboardShortcut("f",modifiers:.command)
                    .opacity(0).frame(width:0,height:0).accessibilityHidden(true)
            }
            .onAppear { open=model.helpTopic;model.helpTopic=nil }
            .onChange(of:model.helpTab) { open=nil;showReport=false }
            .onChange(of:searching) { open=nil }
            .task(id:copied) { if copied != nil { try? await Task.sleep(for:.seconds(2));copied=nil } }
    }
    private static let searchShape=RoundedRectangle(cornerRadius:18,style:.continuous)
    /// Cmd-F to start, Esc to clear; Return opens the first answer found.
    private var searchField:some View {
        HStack(spacing:8) {
            Image(systemName:"magnifyingglass").font(.system(size:13,weight:.medium)).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L("Search Help"),text:$model.helpQuery).textFieldStyle(.plain).font(LauncherStyle.font(14))
                .focused($searchFocused).accessibilityLabel(L("Search Help"))
                .onSubmit { open=results.first?.topics.first?.id }
            if !query.isEmpty {
                Button { query="";searchFocused=true } label: {
                    Image(systemName:"xmark.circle.fill").font(.system(size:13)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel(L("Clear Search"))
            }
        }.padding(.horizontal,14).frame(height:36)
            .background(.primary.opacity(0.05),in:Self.searchShape)
            .overlay { Self.searchShape.strokeBorder(searchFocused ? LauncherStyle.accent.opacity(0.7) : .primary.opacity(0.06),lineWidth:searchFocused ? 1.5 : 1) }
    }
    @ViewBuilder private var page:some View {
        if searching { found }
        else {
            switch model.helpTab {
            case .questions: topics(HelpTopic.questions.filter(shows))
            case .troubleshooting: topics(HelpTopic.troubleshooting.filter(shows))
            case .support: support
            }
        }
    }
    private struct Found:Identifiable { let tab:HelpTab;let topics:[HelpTopic];var id:HelpTab { tab } }
    /// Matches for the player's Battle.net, under the tab each lives in.
    private var results:[Found] {
        [Found(tab:.questions,topics:HelpTopic.questions),Found(tab:.troubleshooting,topics:HelpTopic.troubleshooting)]
            .map { Found(tab:$0.tab,topics:HelpTopic.search(query,in:$0.topics.filter(shows))) }.filter { !$0.topics.isEmpty }
    }
    @ViewBuilder private var found:some View {
        let results=results
        if results.isEmpty {
            VStack(spacing:8) {
                Image(systemName:"magnifyingglass").font(.system(size:22,weight:.medium)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(L("No answers match your search.")).font(LauncherStyle.font(14,.medium)).foregroundStyle(Self.quiet)
            }.frame(maxWidth:.infinity).padding(.top,48)
        } else {
            VStack(alignment:.leading,spacing:16) {
                ForEach(results) { group in
                    VStack(alignment:.leading,spacing:8) {
                        Text(group.tab.title).font(LauncherStyle.font(12,.semibold)).foregroundStyle(.secondary)
                            .padding(.leading,20).accessibilityAddTraits(.isHeader)
                        topics(group.topics)
                    }
                }
            }
        }
    }
    /// Topics for every player, and those for the Battle.net they're on.
    private func shows(_ topic:HelpTopic)->Bool { topic.regions.isEmpty || topic.regions.contains(model.currentRegion) }
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
            }.buttonStyle(.plain).accessibilityValue(isOpen ? L("Expanded") : L("Collapsed"))
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
            Button(L("Open {0} Settings",tab.title)) { model.settingsTab=tab;model.sheet = .settings }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(model.screen == .moveApp)
        case .displays:
            Button(L("Open Displays in System Settings"),action:SettingsSheet.openDisplaySettings)
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
        case .workshopCode:
            Button(copied == "code" ? L("Copied") : L("Copy Code {0}",FirstMatchTip.workshopCode)) {
                copy(FirstMatchTip.workshopCode);copied="code"
            }.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
    /// Where to ask (the community, or GitHub on China's Battle.net) and how to report a bug
    /// (GitHub, with the report).
    private var support:some View {
        VStack(spacing:16) {
            if model.showsDiscord { DiscordLink() } else { GitHubHelpLink() }
            LauncherPanel(inset:20) {
                VStack(alignment:.leading,spacing:16) {
                    HStack(spacing:12) {
                        Image(systemName:"ladybug").font(.system(size:17,weight:.medium)).foregroundStyle(LauncherStyle.accent)
                            .frame(width:22).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:2) {
                            Text(L("Report a bug")).font(LauncherStyle.font(15,.semibold)).accessibilityAddTraits(.isHeader)
                            Text(L("Bugs go on GitHub, where they can be tracked and fixed.")).font(LauncherStyle.font(13)).foregroundStyle(Self.quiet)
                        }
                    }
                    Divider()
                    reportStep(1,L("Save or copy your support report"),
                               L("It lists your Mac, your macOS and {0} versions, your display, a few settings, other apps that were using a lot of your Mac, and the last setup steps. Never account details. Nothing is uploaded.",Brand.name)) {
                        HStack(spacing:8) {
                            Button(copied == "report" ? L("Copied") : L("Copy")) { model.makeReport();copy(model.report);copied="report" }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityLabel(copied == "report" ? L("Copied") : L("Copy support report"))
                            Button(L("Save…")) { model.makeReport();model.saveReport() }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityLabel(L("Save support report"))
                            Spacer(minLength:8)
                            Button(showReport ? L("Hide Report") : L("Show Report")) {
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
                            .padding(.leading,29).accessibilityLabel(L("Support report preview"))
                    }
                    reportStep(2,L("Save your logs"),
                               L("If something went wrong in Battle.net or Overwatch, add your logs too. For more detail, turn on logging in Settings › Advanced, then play until it happens again.")) {
                        VStack(alignment:.leading,spacing:6) {
                            Button(model.savingLogs ? L("Saving…") : L("Save Logs…"),action:model.saveLogs)
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(model.savingLogs)
                            if let saved=model.savedLogs {
                                Text(L("Saved {0} ({1}). Attach it to your GitHub issue.",saved.name,ByteCountFormatter.string(fromByteCount:saved.bytes,countStyle:.file)))
                                    .font(LauncherStyle.font(12)).foregroundStyle(Self.quiet).fixedSize(horizontal:false,vertical:true)
                            }
                        }
                    }
                    reportStep(3,L("Open an issue on GitHub and attach your files"),L("Say what you did and what happened.")) {
                        Button { openURL(Brand.issues) } label: {
                            Label(L("Report on GitHub"),systemImage:"arrow.up.right")
                        }.buttonStyle(.bordered).buttonBorderShape(.capsule).help(L("Open a new issue on GitHub in your browser"))
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
