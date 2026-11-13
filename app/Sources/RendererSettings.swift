import SwiftUI

/// Settings › Advanced › Custom renderer settings (1.6.4, REC-85): the player's own dxmt.conf lines
/// for the graphics engine (DXMT), added at each launch while the setting is on
/// (AppModel.rendererCustomOn; worker: launch --renderer-custom, scripts/portable_renderer.h).
/// Recall writes dxmt.conf afresh before each launch, so edits to the file itself never lasted.
/// The engine silently ignores a name it doesn't read, even one with a letter in the wrong case, so
/// each line is checked as the player types against the names this release's engine reads
/// (RendererEngineSettings.swift, generated from the engine's source): an unknown name, with the
/// nearest one it does read; a value it can't read; and the lines the worker leaves out (Recall's
/// resolution and sharpening, section headers, anything that isn't name = value). A flag doesn't
/// stop Save: the lines are the player's to experiment with (owner, November 9).
enum RendererSettings {
    /// The kinds of value DXMT's parsers read (scripts/renderer_settings.py).
    enum Kind:Equatable { case bool, int, float, text, tristate }
    /// Recall's own, from Settings › Display's resolution and Settings › Graphics' Sharpening; the
    /// worker leaves the player's lines for them out.
    static let canvas:Set<String>=["dxgi.fullscreenCanvasWidth","dxgi.fullscreenCanvasHeight"]
    static let sharpening="d3d11.metalfxSharpness"
    static func recalls(_ name:String)->Bool { canvas.contains(name) || name == sharpening }
    /// The most text the setting holds; the worker gets the lines as one launch argument.
    static let limit=4000

    enum Problem:Equatable {
        case unknown(String, suggestion:String?)
        case recalls(String)
        case value(String, Kind)
        case section
        case unreadable
    }
    struct Line:Equatable {
        let number:Int
        let text:String
        let problem:Problem?
    }
    /// Each line of TEXT that says something (not blank, not a # comment), numbered as the player
    /// sees them, with what's wrong with it.
    static func check(_ text:String)->[Line] {
        var result:[Line]=[]
        for (index,raw) in text.split(omittingEmptySubsequences:false,whereSeparator:\.isNewline).enumerated() {
            let line=raw.trimmingCharacters(in:.whitespaces)
            guard !line.isEmpty,!line.hasPrefix("#") else { continue }
            result.append(Line(number:index+1,text:line,problem:problem(line)))
        }
        return result
    }
    private static func problem(_ line:String)->Problem? {
        if line.hasPrefix("[") { return .section }
        guard let (name,value)=parse(line) else { return .unreadable }
        if recalls(name) { return .recalls(name) }
        guard let kind=engine[name] else { return .unknown(name,suggestion:suggestion(for:name)) }
        return valid(engineValue(value),kind) ? nil : .value(name,kind)
    }
    /// A name = value line's name and value, as the worker reads them; nil for anything else.
    static func parse(_ line:String)->(String,String)? {
        guard let equals=line.firstIndex(of:"=") else { return nil }
        let name=line[..<equals].trimmingCharacters(in:.whitespaces)
        guard name.range(of:"^[A-Za-z0-9._]+$",options:.regularExpression) != nil else { return nil }
        return (name,line[line.index(after:equals)...].trimmingCharacters(in:.whitespaces))
    }
    /// The lines a launch passes on: every name = value line but Recall's own, as the worker keeps them.
    static func used(_ text:String)->[String] {
        check(text).compactMap { line in
            guard let (name,value)=parse(line.text),!recalls(name) else { return nil }
            return "\(name) = \(value)"
        }
    }
    /// The value DXMT reads: up to the first space outside quotes, without the quotes.
    static func engineValue(_ raw:String)->String {
        var value="",quoted=false
        for character in raw {
            if !quoted && (character == " " || character == "\t") { break }
            if character == "\"" { quoted.toggle() } else { value.append(character) }
        }
        return value
    }
    /// Whether DXMT's parser for KIND reads VALUE (src/util/config/config.cpp): true or false in
    /// any case; a whole number with an optional minus; a number with an optional fraction.
    static func valid(_ value:String,_ kind:Kind)->Bool {
        let lower=value.lowercased()
        switch kind {
        case .bool: return ["true","false"].contains(lower)
        case .tristate: return ["true","false","auto"].contains(lower)
        case .int: return value.range(of:"^-?[0-9]+$",options:.regularExpression) != nil
        case .float: return value.range(of:"^-?[0-9]+(\\.[0-9]+)?$",options:.regularExpression) != nil
        case .text: return !value.isEmpty
        }
    }
    /// The setting a mistyped NAME most likely meant: the same name in another case; the same
    /// setting under another prefix; a name a letter or two away; or, for a frame rate cap, the one
    /// Overwatch's renderer reads. Overwatch draws with Direct3D 11, so d3d12's settings are
    /// suggested only for their own name in another case.
    static func suggestion(for name:String)->String? {
        let lower=name.lowercased()
        let known=engine.keys.sorted()+[sharpening]+canvas.sorted()
        if let same=known.first(where:{ $0.lowercased() == lower }) { return same }
        let candidates=known.filter { !$0.hasPrefix("d3d12.") }
        let last=lower.split(separator:".").last.map(String.init) ?? lower
        if let moved=candidates.first(where:{ $0.lowercased().split(separator:".").last.map(String.init) == last }) { return moved }
        let near=candidates.map { ($0,distance(lower,$0.lowercased())) }.filter { $0.1 <= 2 }.min { $0.1 < $1.1 }
        if let near { return near.0 }
        if ["framerate","fps","framelimit","framecap"].contains(where:{ lower.contains($0) }) { return "d3d11.preferredMaxFrameRate" }
        return nil
    }
    /// How many letters to add, remove or change to turn A into B (Levenshtein).
    static func distance(_ a:String,_ b:String)->Int {
        let a=Array(a),b=Array(b)
        guard !a.isEmpty,!b.isEmpty else { return max(a.count,b.count) }
        var previous=Array(0...b.count)
        for i in 1...a.count {
            var current=[i]+Array(repeating:0,count:b.count)
            for j in 1...b.count { current[j]=min(previous[j]+1,current[j-1]+1,previous[j-1]+(a[i-1] == b[j-1] ? 0 : 1)) }
            previous=current
        }
        return previous[b.count]
    }
    /// What the sheet says about a line's problem.
    static func message(_ line:Line)->String? {
        guard let problem=line.problem else { return nil }
        let number=String(line.number)
        switch problem {
        case .unknown(let name,let suggestion?): return L("Line {0}: {1} isn’t a setting. Did you mean {2}?",number,name,suggestion)
        case .unknown(let name,nil): return L("Line {0}: {1} isn’t a setting the renderer reads, so it does nothing.",number,name)
        case .recalls(let name) where canvas.contains(name): return L("Line {0}: {1} follows your resolution in Settings › Display, so this line isn’t used.",number,name)
        case .recalls(let name): return L("Line {0}: {1} follows Sharpening in Settings › Graphics, so this line isn’t used.",number,name)
        case .value(let name,.bool): return L("Line {0}: {1} takes True or False.",number,name)
        case .value(let name,.tristate): return L("Line {0}: {1} takes True, False or Auto.",number,name)
        case .value(let name,.int): return L("Line {0}: {1} takes a whole number.",number,name)
        case .value(let name,.float): return L("Line {0}: {1} takes a number, such as 0.5.",number,name)
        case .value(let name,.text): return L("Line {0}: {1} has no value.",number,name)
        case .section: return L("Line {0}: Sections aren’t needed here. Your lines always apply to Overwatch, so this one isn’t used.",number)
        case .unreadable: return L("Line {0}: Not a setting. Write it as name = value.",number)
        }
    }
    /// The settings Recall gave the last launch (its dxmt.conf without the player's lines), or the
    /// engine's own before the first: one line each, the last word for each name, with no comments.
    static func recallsLines(root:URL, runtime:String?)->[String] {
        let launched=root.appendingPathComponent("dxmt.conf")
        let engine=runtime.map { root.appendingPathComponent("runtimes/\($0)/config/dxmt.conf") }
        guard let text=(try? String(contentsOf:launched,encoding:.utf8)) ?? engine.flatMap({ try? String(contentsOf:$0,encoding:.utf8) }) else { return [] }
        let recalls=text.components(separatedBy:"\n# Custom renderer settings")[0]
        var names:[String]=[],values:[String:String]=[:]
        for raw in recalls.split(whereSeparator:\.isNewline) {
            let line=raw.trimmingCharacters(in:.whitespaces)
            guard !line.hasPrefix("#"),!line.hasPrefix("["),let (name,value)=parse(line) else { continue }
            if values[name] == nil { names.append(name) }
            values[name]=value
        }
        return names.map { "\($0) = \(values[$0]!)" }
    }
    /// Display sync as the last launch used it, for the support report (REC-93): "on" when that
    /// launch's dxmt.conf turned it on (the worker does on a Mac with an iPhone chip, the MacBook
    /// Neo, ahead of the player's lines, so a player's own line wins), "off" when it didn't (the
    /// engine's default), and "not_launched" before a launch wrote one. DXMT keeps the last value
    /// it reads and ignores one it can't.
    static func displaySync(root:URL)->String {
        guard let text=try? String(contentsOf:root.appendingPathComponent("dxmt.conf"),encoding:.utf8) else { return "not_launched" }
        var on=false
        for raw in text.split(whereSeparator:\.isNewline) {
            let line=raw.trimmingCharacters(in:.whitespaces)
            guard !line.hasPrefix("#"),let (name,value)=parse(line),name == "dxgi.displaySyncEnabled" else { continue }
            switch engineValue(value).lowercased() {
            case "true": on=true
            case "false": on=false
            default: continue
            }
        }
        return on ? "on" : "off"
    }
}

/// Custom renderer settings' editor (REC-85; the design the owner approved on November 9): the
/// switch apart from the text, so turning the lines off keeps them; the text, checked line by line
/// as it's typed; the risk in one line; Recall's own settings to copy from; Clear, Cancel and Save.
/// Nothing changes until Save.
struct RendererSettingsSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var on:Bool
    @State private var text:String
    @State private var showRecalls=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model:AppModel) {
        self.model=model
        _on=State(initialValue:model.rendererCustomOn)
        _text=State(initialValue:model.rendererCustom)
    }
    var body:some View {
        let lines=RendererSettings.check(text)
        let messages=lines.compactMap(RendererSettings.message)
        let tooLong=text.count > RendererSettings.limit
        FittedSheet(spacing:18) {
            SheetHero(symbol:"slider.horizontal.3",title:L("Custom renderer settings"),subtitle:L("Your own dxmt.conf lines, added at each launch."))
            LauncherPanel(inset:16) {
                VStack(alignment:.leading,spacing:12) {
                    SettingSwitch(title:L("Use these settings"),detail:L("Turn off to rule them out without losing what you typed."),isOn:$on)
                    editor
                    if tooLong {
                        problem(L("That’s more than {0} characters. Remove some lines to save.",RendererSettings.limit.formatted()))
                    } else if !messages.isEmpty {
                        VStack(alignment:.leading,spacing:4) { ForEach(messages,id:\.self) { problem($0) } }
                    } else if !lines.isEmpty {
                        Label(L("Every line is a setting the renderer reads."),systemImage:"checkmark.circle.fill")
                            .font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                    }
                }
            }
            Label {
                Text(sentences(L("These change how Overwatch is drawn and can cause stutter, input lag or a black screen. Resolution and sharpening always come from {0}’s settings.",Brand.name),
                               L("Changes take effect the next time you press Play.")))
                    .fixedSize(horizontal:false,vertical:true)
            } icon: { Image(systemName:"exclamationmark.triangle").accessibilityHidden(true) }
                .font(LauncherStyle.font(12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            recalls
        } actions: {
            HStack(spacing:12) {
                Button(L("Clear")) { text="" }.buttonStyle(.borderless).disabled(text.isEmpty)
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.cancelAction)
                Button(L("Save")) { model.saveRendererCustom(on:on,text:text);dismiss() }.buttonStyle(AccentButtonStyle(large:true))
                    .disabled(tooLong)
            }
        }.font(LauncherStyle.font(14))
            .tint(.primary).background { LauncherBackground() }
    }
    private var editor:some View {
        TextEditor(text:$text)
            .font(.system(size:12,design:.monospaced)).autocorrectionDisabled().scrollContentBackground(.hidden)
            .padding(6).frame(height:132)
            .background(.background.opacity(0.6),in:RoundedRectangle(cornerRadius:8,style:.continuous))
            .overlay(alignment:.topLeading) {
                if text.isEmpty {
                    Text(L("name = value")).font(.system(size:12,design:.monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal,11).padding(.vertical,6).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay { RoundedRectangle(cornerRadius:8,style:.continuous).strokeBorder(.primary.opacity(0.12),lineWidth:1) }
            .accessibilityLabel(L("Your dxmt.conf lines"))
    }
    private func problem(_ message:String)->some View {
        Label { Text(message).fixedSize(horizontal:false,vertical:true) } icon: {
            Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
        }.font(LauncherStyle.font(12))
    }
    /// Recall's own settings, closed until the player opens them, to copy a line from.
    private var recalls:some View {
        VStack(alignment:.leading,spacing:8) {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration:0.15)) { showRecalls.toggle() } } label: {
                HStack(spacing:4) {
                    Text(L("Show {0}’s settings",Brand.name)).font(LauncherStyle.font(12,.medium))
                    Image(systemName:"chevron.down").font(.system(size:10,weight:.semibold)).rotationEffect(.degrees(showRecalls ? 180 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityAddTraits(showRecalls ? .isSelected : [])
            if showRecalls {
                let shown=model.rendererRecallsLines
                VStack(alignment:.leading,spacing:6) {
                    if shown.isEmpty {
                        Text(L("They appear here once Overwatch is set up.")).font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim:shown.joined(separator:"\n")).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal:false,vertical:true)
                        Text(L("Resolution and sharpening are set at each launch from your settings.")).font(LauncherStyle.font(11)).foregroundStyle(.secondary)
                    }
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                    .background(.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:10,style:.continuous))
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
