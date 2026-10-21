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
        case .kept, .learned, .checking: return learned > 0 ? L("Checking {0} learned shaders",learned.formatted()) : L("Checking learned shaders")
        case .warming: return L("Warming up {0} of {1} shaders",warmDone.formatted(),warmTarget.formatted())
        case .preparing: return fresh > 0 ? L("Prepared {0} of {1} · {2} new",prepared.formatted(),target.formatted(),fresh.formatted()) : L("Prepared {0} of {1}",prepared.formatted(),target.formatted())
        case .verifying: return L("Checking {0} prepared shaders",target.formatted())
        case .done:
            if learned == 0 && ready == 0 { return L("No shaders learned yet") }
            if warmed > 0 { return L("{0} shaders warmed up",warmed.formatted()) }
            if ready == 0 { return L("{0} learned · ready after your next match",learned.formatted()) }
            if ready < learned { return L("{0} of {1} shaders ready",ready.formatted(),learned.formatted()) }
            return added > 0 ? L("{0} shaders ready · {1} new",ready.formatted(),added.formatted()) : L("{0} shaders ready",ready.formatted())
        case .skipped: return L("Skipped this time · prepared shaders kept")
        case nil: return ""
        }
    }
    /// Why the warm-up runs, under its list.
    var warmingNote:String? {
        phase == .warming || warmed > 0 ? L("After a macOS update, {0} builds the shaders you’ve already used again. This can take a few minutes.",Brand.name) : nil
    }
    /// Shown in place of the numbers before anything was learned.
    var explanation:String {
        L("{0} learns each shader the first time Overwatch uses it on this Mac. After you quit Overwatch, it prepares them for your next match.",Brand.name)
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
                            Text(expanded ? L("Hide") : L("Details")).font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                            Image(systemName:"chevron.down").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(progress.summary).accessibilityHint(expanded ? L("Hides the details") : L("Shows what the numbers mean"))
                    ShaderInfoButton(isPresented:$info)
                }
                if expanded {
                    if !progress.items.isEmpty { list }
                    else if progress.phase == .done && progress.learned == 0 && progress.ready == 0 {
                        Text(progress.explanation).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    } else if progress.phase == .done || progress.learned > 0 { numbers }
                    else { Text(L("Shaders appear here as they’re prepared.")).font(LauncherStyle.font(12)).foregroundStyle(.secondary) }
                    if let note=progress.warmingNote {
                        Text(note).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    if progress.keptFolders > 0 {
                        Text(L("Includes shaders kept from before your Mac restarted.")).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
        }
    }
    /// The two numbers, each with what it counts.
    private var numbers:some View {
        Grid(alignment:.topLeading,horizontalSpacing:14,verticalSpacing:10) {
            number(progress.ready,L("Ready"),readyDetail)
            number(progress.learned,L("Learned"),ShaderInfo.learnedShort)
        }
    }
    private var readyDetail:String {
        if progress.ready == 0 { return L("None yet. They’re built after you quit Overwatch and load from your next match.") }
        let added=progress.added == 1 ? L("1 was added after your last match.") : progress.added > 1 ? L("{0} were added after your last match.",progress.added.formatted()) : ""
        let rest=progress.learned > progress.ready ? L("The other {0} are built after your next match.",(progress.learned-progress.ready).formatted()) : ""
        return sentences(ShaderInfo.readyShort,added,rest)
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
                            if item.new { Text(L("new")).font(LauncherStyle.font(11,.semibold)).foregroundStyle(LauncherStyle.accent) }
                            Spacer(minLength:8)
                            Text(item.ms < 10 ? String(format:"%.1f ms",item.ms) : "\(Int(item.ms.rounded())) ms")
                                .font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary)
                        }.id(item.id)
                    }
                }.padding(.vertical,2)
            }.frame(height:168).scrollIndicators(.automatic)
                .onChange(of:progress.items.last?.id) { _,last in if let last { reader.scrollTo(last,anchor:.bottom) } }
                .onAppear { if let last=progress.items.last?.id { reader.scrollTo(last,anchor:.bottom) } }
                .accessibilityLabel(L("Prepared shaders"))
        }
    }
}

/// What shaders are and how Recall learns and prepares them, in plain words. Shared by the
/// info button (launch screen, after-match status) and Help's FAQ.
enum ShaderInfo {
    static var what:String { L("Shaders are small programs your Mac’s graphics chip runs to draw each part of a scene, such as a hero, a wall or an explosion. Overwatch uses thousands of them.") }
    static var stutter:String { L("Overwatch’s shaders are written for Windows. The first time the game uses one, it’s translated for Apple’s Metal and built for your Mac’s graphics chip. When that takes longer than a frame, you see a brief stutter.") }
    static var learned:String { L("Every shader Overwatch has used on this Mac. The number grows as you see new maps, heroes, skins and effects; there’s no fixed total.") }
    static var ready:String { L("Learned shaders {0} has already built. After you quit Overwatch, {0} builds the ones that aren’t ready yet, slowest first. Overwatch loads them all when it starts, unless you choose less under Shader memory in Settings, and any it doesn’t load still come quickly from macOS’s own shader cache.",Brand.name) }
    static var interrupted:String { L("Preparing keeps going if you quit {0}. If your Mac shuts down or sleeps, or you play again before it’s done, what’s finished is kept and the rest is prepared after your next match.",Brand.name) }
    static var update:String { L("After a macOS update, {0} builds your learned shaders again. It starts before Battle.net opens and finishes after your next match.",Brand.name) }
    static var local:String { L("Shaders stay on this Mac; nothing is uploaded.") }
    static var learnedShort:String { L("Every shader Overwatch has used on this Mac.") }
    static var readyShort:String { L("Built after you quit Overwatch and loaded when the game starts.") }
}
/// The info button beside shader numbers and status.
struct ShaderInfoButton:View {
    @Binding var isPresented:Bool
    var body:some View {
        Button { isPresented=true } label: { Image(systemName:"info.circle").font(.system(size:14)) }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help(L("About shaders")).accessibilityLabel(L("About shaders"))
            .infoPopover(isPresented:$isPresented) { ShaderInfoView() }
    }
}
struct ShaderInfoView:View {
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("Shaders")).font(LauncherStyle.font(15,.semibold)).accessibilityAddTraits(.isHeader)
            paragraph(L("What they are."),ShaderInfo.what)
            paragraph(L("Why the first time stutters."),ShaderInfo.stutter)
            paragraph(L("Learned."),ShaderInfo.learned)
            paragraph(L("Ready."),ShaderInfo.ready)
            paragraph(L("If preparing is cut short."),ShaderInfo.interrupted)
            paragraph(L("After an update."),ShaderInfo.update)
            Text(ShaderInfo.local).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.font(LauncherStyle.font(13)).padding(20).frame(width:420,alignment:.leading)
    }
    private func paragraph(_ lead:String,_ text:String) -> some View {
        Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(.primary))\(AppLanguage.gap)\(Text(text).foregroundStyle(.secondary))")
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
                Text((updating ? L("Updating your shader cache") : L("Preparing shaders from your last match"))+(fraction.map { " · "+($0 >= 1 ? L("Finishing up") : "\(Int($0*100))%") } ?? ""))
                    .font(LauncherStyle.font(13,.semibold)).monospacedDigit()
                Text(sentences(progress.map { L("{0} of {1} ready.",$0.ready.formatted(),$0.learned.formatted()) } ?? "",
                               updating ? L("This one-time update keeps going if you quit {0}.",Brand.name) : L("This keeps going if you quit {0}.",Brand.name),
                               L("Keep your Mac awake until it’s done.")))
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
/// Settings › Graphics › Clear Shader Cache: the size of what it removes, as the worker finds it
/// (portable_setup.m deleteShaders): Recall's caches, and macOS's for the engine's game app.
enum ShaderCache {
    static func bytes(root:URL,runtime:String?)->Int64 {
        var folders=[root.appendingPathComponent("cache/pipelines"),root.appendingPathComponent("cache/shaders")]
        var caches=[CChar](repeating:0,count:Int(PATH_MAX))
        if let runtime,!runtime.contains("/"),
           let info=NSDictionary(contentsOf:root.appendingPathComponent("runtimes/\(runtime)/lib/wine/game-mode/Overwatch.app/Contents/Info.plist")),
           let identifier=info["CFBundleIdentifier"] as? String,identifier.hasPrefix("org.overwatch2mac."),!identifier.contains("/"),!identifier.contains(".."),
           confstr(_CS_DARWIN_USER_CACHE_DIR,&caches,caches.count) > 0 {
            folders.append(URL(fileURLWithPath:String(cString:caches)).appendingPathComponent(identifier))
        }
        var total=Int64(0)
        for folder in folders {
            guard let files=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.totalFileAllocatedSizeKey]) else { continue }
            for case let file as URL in files { total+=Int64((try? file.resourceValues(forKeys:[.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        }
        return total
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
        // The monitor names itself once Battle.net is closed for the match, then waits for the game
        // to close before the helper starts and rewrites its log: until then, the log is the last run's.
        let named=AfterMatch.running(root:root) ? modified(root.appendingPathComponent("cache/after-session.pid")) : nil
        let waiting=named.map { since in after.map { $0.date < since } ?? true } ?? false
        var record:[String:Any]=["preparing_now":named != nil && !waiting,"waiting_for_game_to_close":waiting]
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
    private static func modified(_ url:URL)->Date? { (try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate }
    private static func log(_ url:URL)->Log? {
        guard let text=try? String(contentsOf:url,encoding:.utf8),let date=modified(url) else { return nil }
        return Log(text:text,date:date)
    }
    /// scripts/portable_pipeline.swift's last word on the run, as a code. The worker stops a
    /// preparation when the game starts again: that is "cancelled", not "failed". A stop while the
    /// helper waits on one of its tools reads the same as that tool timing out.
    static func outcome(_ text:String)->String {
        let codes=[("Prepared and verified","prepared"),("Learned pipelines are up to date","up_to_date"),
                   ("Current archive covers comparable","up_to_date"),("Refresh already evaluated","up_to_date"),
                   ("no verified improvement","up_to_date"),("to preserve disk headroom","skipped_low_disk"),
                   ("leave no room to save","skipped_no_room"),("Archive not saved","not_saved"),
                   ("No learned pipelines yet","nothing_learned"),
                   ("retained: Preparation cancelled or timed out","cancelled_or_timed_out"),
                   ("retained: Preparation cancelled","cancelled"),("Pipeline preparation skipped","failed"),
                   ("ran out of time","timed_out")]
        for line in text.split(separator:"\n").reversed() where !line.hasPrefix("{") {
            if let code=codes.first(where:{ line.contains($0.0) })?.1 { return code }
        }
        return text.isEmpty ? "never" : "incomplete"
    }
}
