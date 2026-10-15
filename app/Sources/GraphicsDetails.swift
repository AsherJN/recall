import SwiftUI

/// "Preparing graphics" before Battle.net opens, as the worker reports it (graphics
/// events from the pipeline helper, scripts/portable_pipeline.swift). Before each
/// session Recall keeps the shaders Overwatch used on this Mac in earlier ones; it
/// builds them after each session. After a macOS update it first warms the game's own
/// shader cache with them, once.
struct GraphicsProgress {
    enum Phase { case kept, learned, warming, checking, preparing, verifying, done, skipped }
    struct Item: Identifiable { let id: Int; let key: String; let ms: Double; let new: Bool }
    var phase: Phase?
    /// Shaders learned on this Mac, prepared ahead (ready), and new in this preparation.
    var learned=0, ready=0, added=0
    /// The current preparation: how many it handles, how many are done, how many are new.
    var target=0, prepared=0, fresh=0
    /// Folders left by earlier restarts (from 1.1) and the shaders they added.
    var keptFolders=0, keptAdded=0
    /// The warm-up: how many it builds, how many are built, and the total once done.
    var warmTarget=0, warmDone=0, warmed=0
    /// The most recent shaders, oldest first.
    var items=[Item]()
    private var serial=0
    static let shown=300
    mutating func update(_ value:[String:Any]) {
        func number(_ key:String) -> Int? { (value[key] as? NSNumber)?.intValue }
        switch value["phase"] as? String {
        case "kept": keptFolders=number("folders") ?? 0;keptAdded=number("added") ?? 0;phase = .kept
        case "learned": learned=number("learned") ?? learned;ready=number("ready") ?? ready;phase = .learned
        case "warming": warmTarget=number("target") ?? 0;warmDone=0;phase = .warming
        case "checking": phase = .checking
        // A retried preparation starts its count again; the list keeps going.
        case "preparing": target=number("target") ?? 0;prepared=0;fresh=0;phase = .preparing
        case "pipelines":
            for case let item as [Any] in value["items"] as? [Any] ?? [] {
                guard item.count == 3,let key=item[0] as? String,let ms=(item[1] as? NSNumber)?.doubleValue,let new=(item[2] as? NSNumber)?.boolValue else { continue }
                serial+=1
                if phase == .warming { warmDone+=1 } else { prepared+=1;if new { fresh+=1 } }
                items.append(Item(id:serial,key:key,ms:ms,new:new))
            }
            if items.count > Self.shown { items.removeFirst(items.count-Self.shown) }
        case "verifying": target=number("target") ?? target;phase = .verifying
        case "done": learned=number("learned") ?? learned;ready=number("ready") ?? ready;added=number("added") ?? 0;warmed=number("warmed") ?? 0;phase = .done
        default: break
        }
    }
    /// The worker reports a skipped preparation after the helper's own result, if any.
    mutating func skipped() { if phase != nil && phase != .done { phase = .skipped } }
    var summary:String {
        switch phase {
        case .kept, .learned, .checking: return learned > 0 ? "Checking \(learned.formatted()) learned shaders" : "Checking learned shaders"
        case .warming: return "Warming up \(warmDone.formatted()) of \(warmTarget.formatted()) shaders"
        case .preparing: return "Prepared \(prepared.formatted()) of \(target.formatted())"+(fresh > 0 ? " · \(fresh.formatted()) new" : "")
        case .verifying: return "Checking \(target.formatted()) prepared shaders"
        case .done:
            if learned == 0 && ready == 0 { return "No shaders learned yet" }
            if warmed > 0 { return "\(warmed.formatted()) shaders warmed up" }
            if ready == 0 { return "\(learned.formatted()) learned · ready after your next match" }
            if ready < learned { return "\(ready.formatted()) of \(learned.formatted()) shaders ready" }
            return "\(ready.formatted()) shaders ready"+(added > 0 ? " · \(added.formatted()) new" : "")
        case .skipped: return "Skipped this time · prepared shaders kept"
        case nil: return ""
        }
    }
    /// Why the warm-up runs, under its list.
    var warmingNote:String? {
        phase == .warming || warmed > 0 ? "After a macOS update, \(Brand.name) builds the shaders you’ve already used again. This can take a few minutes." : nil
    }
    /// Shown in place of the numbers before anything was learned.
    var explanation:String {
        "\(Brand.name) learns each shader the first time Overwatch uses it on this Mac. After you quit Overwatch, it prepares them for your next match."
    }
}

/// The launching screen's details: one summary line, and for players who open it, the
/// numbers explained, or each shader as it's prepared. The info button explains shaders.
struct GraphicsDetails: View {
    let progress:GraphicsProgress
    @AppStorage("graphicsDetailsExpanded") private var expanded=false
    @State private var info=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:10) {
                    Button { withAnimation(reduceMotion ? nil : .easeOut(duration:0.15)) { expanded.toggle() } } label: {
                        HStack(spacing:10) {
                            Image(systemName:progress.phase == .done ? "checkmark.circle.fill" : "square.stack.3d.up")
                                .foregroundStyle(progress.phase == .done ? AnyShapeStyle(LauncherStyle.accent) : AnyShapeStyle(.secondary)).frame(width:18)
                            Text(progress.summary).font(LauncherStyle.font(13,.medium)).monospacedDigit().lineLimit(1)
                            Spacer(minLength:8)
                            Text(expanded ? "Hide" : "Details").font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                            Image(systemName:"chevron.down").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(progress.summary).accessibilityHint(expanded ? "Hides the details" : "Shows what the numbers mean")
                    ShaderInfoButton(isPresented:$info)
                }
                if expanded {
                    if !progress.items.isEmpty { list }
                    else if progress.phase == .done && progress.learned == 0 && progress.ready == 0 {
                        Text(progress.explanation).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    } else if progress.phase == .done || progress.learned > 0 { numbers }
                    else { Text("Shaders appear here as they’re prepared.").font(LauncherStyle.font(12)).foregroundStyle(.secondary) }
                    if let note=progress.warmingNote {
                        Text(note).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    if progress.keptFolders > 0 {
                        Text("Includes shaders kept from before your Mac restarted.").font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
        }
    }
    /// The two numbers, each with what it counts.
    private var numbers:some View {
        Grid(alignment:.topLeading,horizontalSpacing:14,verticalSpacing:10) {
            number(progress.ready,"Ready",readyDetail)
            number(progress.learned,"Learned",ShaderInfo.learnedShort)
        }
    }
    private var readyDetail:String {
        if progress.ready == 0 { return "None yet. They’re built after you quit Overwatch and load from your next match." }
        let added=progress.added == 1 ? " 1 was added after your last match." : progress.added > 1 ? " \(progress.added.formatted()) were added after your last match." : ""
        let rest=progress.learned > progress.ready ? " The other \((progress.learned-progress.ready).formatted()) are built after your next match." : ""
        return ShaderInfo.readyShort+added+rest
    }
    private func number(_ value:Int,_ title:String,_ detail:String)->some View {
        GridRow {
            Text(value.formatted()).font(LauncherStyle.font(15,.semibold)).monospacedDigit().gridColumnAlignment(.trailing)
            VStack(alignment:.leading,spacing:1) {
                Text(title).font(LauncherStyle.font(13,.semibold))
                Text(detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }.accessibilityElement(children:.combine)
    }
    private var list:some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing:3) {
                    ForEach(progress.items) { item in
                        HStack(spacing:8) {
                            Text(item.key).font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary)
                            if item.new { Text("new").font(LauncherStyle.font(11,.semibold)).foregroundStyle(LauncherStyle.accent) }
                            Spacer(minLength:8)
                            Text(item.ms < 10 ? String(format:"%.1f ms",item.ms) : "\(Int(item.ms.rounded())) ms")
                                .font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary)
                        }.id(item.id)
                    }
                }.padding(.vertical,2)
            }.frame(height:168).scrollIndicators(.automatic)
                .onChange(of:progress.items.last?.id) { _,last in if let last { reader.scrollTo(last,anchor:.bottom) } }
                .onAppear { if let last=progress.items.last?.id { reader.scrollTo(last,anchor:.bottom) } }
                .accessibilityLabel("Prepared shaders")
        }
    }
}

/// What shaders are and how Recall learns and prepares them, in plain words. Shared by the
/// info button (launch screen, after-match status) and Help's FAQ.
enum ShaderInfo {
    static let what="Shaders are small programs your Mac’s graphics chip runs to draw each part of a scene, such as a hero, a wall or an explosion. Overwatch uses thousands of them."
    static let stutter="Overwatch’s shaders are written for Windows. The first time the game uses one, it’s translated for Apple’s Metal and built for your Mac’s graphics chip. When that takes longer than a frame, you see a brief stutter."
    static let learned="Every shader Overwatch has used on this Mac. The number grows as you see new maps, heroes, skins and effects; there’s no fixed total."
    static let ready="Learned shaders \(Brand.name) has already built. After you quit Overwatch, \(Brand.name) builds the ones that aren’t ready yet, slowest first. Overwatch loads them all when it starts, unless you choose less under Shader memory in Settings, and any it doesn’t load still come quickly from macOS’s own shader cache."
    static let interrupted="Preparing keeps going if you quit \(Brand.name). If your Mac shuts down or sleeps, or you play again before it’s done, what’s finished is kept and the rest is prepared after your next match."
    static let update="After a macOS update, \(Brand.name) builds your learned shaders again. It starts before Battle.net opens and finishes after your next match."
    static let local="Shaders stay on this Mac; nothing is uploaded."
    static let learnedShort="Every shader Overwatch has used on this Mac."
    static let readyShort="Built after you quit Overwatch and loaded when the game starts."
}
/// The info button beside shader numbers and status.
struct ShaderInfoButton:View {
    @Binding var isPresented:Bool
    var body:some View {
        Button { isPresented=true } label: { Image(systemName:"info.circle").font(.system(size:14)) }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("About shaders").accessibilityLabel("About shaders")
            .popover(isPresented:$isPresented,arrowEdge:.bottom) { ShaderInfoView() }
    }
}
struct ShaderInfoView:View {
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Shaders").font(LauncherStyle.font(15,.semibold)).accessibilityAddTraits(.isHeader)
            paragraph("What they are.",ShaderInfo.what)
            paragraph("Why the first time stutters.",ShaderInfo.stutter)
            paragraph("Learned.",ShaderInfo.learned)
            paragraph("Ready.",ShaderInfo.ready)
            paragraph("If preparing is cut short.",ShaderInfo.interrupted)
            paragraph("After an update.",ShaderInfo.update)
            Text(ShaderInfo.local).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.font(LauncherStyle.font(13)).padding(20).frame(width:420,alignment:.leading)
    }
    private func paragraph(_ lead:String,_ text:String) -> some View {
        Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(.primary)) \(Text(text).foregroundStyle(.secondary))")
            .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
    }
}
/// After a match, while Recall prepares what it learned: in place of the performance tip on
/// the ready and running screens, so the player knows to leave the Mac awake.
struct AfterMatchStatus:View {
    var progress:AfterMatch.Progress?
    /// The one-time shader cache update (Update Now after updating to 1.4) rather than a match's.
    var updating=false
    /// How far along: ready of learned. The helper updates it about every second while it builds.
    private var fraction:Double? { progress.map { min(1,Double($0.ready)/Double(max($0.learned,1))) } }
    @State private var info=false
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        HStack(alignment:.center,spacing:12) {
            if let fraction { ProgressRing(fraction:fraction).accessibilityHidden(true) }
            else { ProgressView().controlSize(.small).accessibilityHidden(true) }
            VStack(alignment:.leading,spacing:2) {
                Text((updating ? "Updating your shader cache" : "Preparing shaders from your last match")+(fraction.map { $0 >= 1 ? " · Finishing up" : " · \(Int($0*100))%" } ?? ""))
                    .font(LauncherStyle.font(13,.semibold)).monospacedDigit()
                Text((progress.map { "\($0.ready.formatted()) of \($0.learned.formatted()) ready. " } ?? "")+(updating ? "This one-time update keeps going if you quit \(Brand.name)." : "This keeps going if you quit \(Brand.name).")+" Keep your Mac awake until it’s done.")
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.accessibilityElement(children:.combine)
            Spacer(minLength:4)
            ShaderInfoButton(isPresented:$info)
        }.padding(.horizontal,16).padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading)
            .background(LauncherStyle.surface(scheme).opacity(0.72),in:RoundedRectangle(cornerRadius:16,style:.continuous))
            .overlay { RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(.primary.opacity(0.06),lineWidth:1) }
    }
}
/// A ring that fills as preparing goes along, in place of a spinner.
struct ProgressRing:View {
    let fraction:Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.12),lineWidth:3.5)
            Circle().trim(from:0,to:max(0.02,fraction))
                .stroke(LauncherStyle.accent,style:StrokeStyle(lineWidth:3.5,lineCap:.round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration:0.8),value:fraction)
        }.frame(width:24,height:24)
    }
}
/// Whether the session's monitor is preparing what the last match learned
/// (portable_setup.m prepareAfterSession): its pid file names a live ow2-setup. A file
/// left by a monitor that was killed names a process that's gone or another program.
enum AfterMatch {
    /// How many shaders are ready of all learned, as the preparation writes it after each batch.
    struct Progress:Equatable { let ready:Int, learned:Int }
    static func progress(root:URL)->Progress? {
        guard let data=try? Data(contentsOf:root.appendingPathComponent("cache/preparing.json")),
              let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let ready=(value["ready"] as? NSNumber)?.intValue,let learned=(value["learned"] as? NSNumber)?.intValue,
              learned > 0,ready >= 0 else { return nil }
        return Progress(ready:ready,learned:learned)
    }
    /// The monitor preparing is the one-time update's (portable_session.h watchClient).
    static func updating(root:URL)->Bool { FileManager.default.fileExists(atPath:root.appendingPathComponent("cache/shader-update").path) }
    static func running(root:URL)->Bool {
        guard let text=try? String(contentsOf:root.appendingPathComponent("cache/after-session.pid"),encoding:.utf8),
              let pid=pid_t(text.trimmingCharacters(in:.whitespacesAndNewlines)),pid>0 else { return false }
        var path=[CChar](repeating:0,count:4*Int(MAXPATHLEN))
        guard proc_pidpath(pid,&path,UInt32(path.count))>0 else { return false }
        return String(cString:path).hasSuffix("/ow2-setup")
    }
}
/// Settings › Graphics › Shader memory: how much of the shader cache Overwatch loads when it
/// starts. The worker keeps the choice (shader_memory: "all", "first" or a number of MiB) and
/// writes it where the game reads it; the parts are the pack's, in the order the game loads
/// them, slowest shaders first (cache/pack.json, from scripts/portable_pipeline.swift).
enum ShaderMemory {
    struct Part:Equatable { let bytes:Int64, shaders:Int }
    static func parts(root:URL)->[Part] {
        guard let data=try? Data(contentsOf:root.appendingPathComponent("cache/pack.json")),
              let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let parts=value["parts"] as? [[NSNumber]] else { return catalogParts(root:root) }
        return parts.compactMap { $0.count == 2 && $0[0].int64Value > 0 ? Part(bytes:$0[0].int64Value,shaders:$0[1].intValue) : nil }
    }
    /// Before the helper has written pack.json (an update, until the first launch or match):
    /// the pack's own catalog, in the newest of this installation's cache folders.
    private static func catalogParts(root:URL)->[Part] {
        let folders=(try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("cache/pipelines"),includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
        let catalogs=folders.filter { $0.lastPathComponent.count == 64 }.map { $0.appendingPathComponent("archive.json") }
            .filter { FileManager.default.fileExists(atPath:$0.path) }
        let date={ (url:URL) in (try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        guard let newest=catalogs.max(by:{ date($0) < date($1) }),
              let size=(try? newest.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size < 64<<20,
              let data=try? Data(contentsOf:newest),
              let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let archives=value["archives"] as? [[String:Any]] else { return [] }
        return archives.compactMap { entry in
            guard let bytes=(entry["bytes"] as? NSNumber)?.int64Value,bytes > 0 else { return nil }
            return Part(bytes:bytes,shaders:(entry["prepared_keys"] as? [Any])?.count ?? 0)
        }
    }
    static func valid(_ choice:String)->Bool {
        choice == "all" || choice == "first" || (choice.count <= 7 && choice.first != "0" && !choice.isEmpty && choice.allSatisfy(\.isASCII) && choice.allSatisfy(\.isNumber))
    }
    /// Every Mac loads all of it unless the player chooses less (as the worker does).
    static let defaultChoice="all"
    /// How many of the parts a choice loads, as the game counts them (pipeline_cache.c).
    static func loaded(_ choice:String,_ parts:[Part])->Int {
        if choice == "all" || parts.isEmpty { return parts.count }
        if choice == "first" { return 1 }
        var budget=(Int64(choice) ?? 0)<<20,count=0
        for part in parts where part.bytes <= budget { budget-=part.bytes;count+=1 }
        return max(count,1)
    }
    /// The choice for loading the first COUNT parts: the first alone is "first", all of them "all".
    static func choice(loading count:Int,of parts:[Part])->String {
        if count >= parts.count { return "all" }
        if count <= 1 { return "first" }
        let bytes=parts.prefix(count).reduce(Int64(0)) { $0+$1.bytes }
        return String((bytes+(1<<20)-1)>>20)
    }
}
/// The support report's shader record: the numbers and how the last after-match preparation
/// ended, read from the helper's own logs and reported as numbers and codes (no paths).
enum ShaderRecord {
    static func read(root:URL)->[String:Any] {
        let logs=root.appendingPathComponent("logs")
        let launch=log(logs.appendingPathComponent("pipeline-preparation.log"))
        let after=log(logs.appendingPathComponent("pipeline-after-session.log"))
        // The newer of the two has the current numbers.
        let newest=[launch,after].compactMap { $0 }.max { $0.date < $1.date }
        var record:[String:Any]=["preparing_now":AfterMatch.running(root:root)]
        if let newest {
            if let learned=newest.last("learned") { record["learned"]=learned["learned"] ?? 0;record["ready"]=learned["ready"] ?? 0 }
            if let done=newest.last("done"),let ready=done["ready"] { record["ready"]=ready }
        }
        if let after {
            record["after_match"]=outcome(after.text)
            record["after_match_hours_ago"]=max(0,Int(Date().timeIntervalSince(after.date)/3600))
        } else { record["after_match"]="never" }
        return record
    }
    private struct Log {
        let text:String,date:Date
        /// The last progress event of this kind ({"graphics":kind,...}).
        func last(_ kind:String)->[String:Int]? {
            for line in text.split(separator:"\n").reversed() where line.hasPrefix("{") {
                guard let event=try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],event["graphics"] as? String == kind else { continue }
                return event.compactMapValues { ($0 as? NSNumber)?.intValue }
            }
            return nil
        }
    }
    private static func log(_ url:URL)->Log? {
        guard let text=try? String(contentsOf:url,encoding:.utf8),
              let date=(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate else { return nil }
        return Log(text:text,date:date)
    }
    /// scripts/portable_pipeline.swift's last word on the run, as a code.
    private static func outcome(_ text:String)->String {
        let codes=[("Prepared and verified","prepared"),("Learned pipelines are up to date","up_to_date"),
                   ("Current archive covers comparable","up_to_date"),("Refresh already evaluated","up_to_date"),
                   ("no verified improvement","up_to_date"),("to preserve disk headroom","skipped_low_disk"),
                   ("leave no room to save","skipped_no_room"),("Archive not saved","not_saved"),
                   ("No learned pipelines yet","nothing_learned"),("Pipeline preparation skipped","failed"),
                   ("ran out of time","timed_out")]
        for line in text.split(separator:"\n").reversed() where !line.hasPrefix("{") {
            if let code=codes.first(where:{ line.contains($0.0) })?.1 { return code }
        }
        return text.isEmpty ? "never" : "incomplete"
    }
}
