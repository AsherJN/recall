import SwiftUI

/// "Preparing graphics" before Battle.net opens, as the worker reports it (graphics
/// events from the pipeline helper, scripts/portable_pipeline.swift). Before each
/// session Recall prepares the shaders Overwatch used on this Mac in earlier ones.
/// After an update or a macOS update it first warms the game's own shader cache
/// with all of them, once.
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
            if learned == 0 && ready == 0 { return "Nothing to prepare yet" }
            if warmed > 0 { return "\(warmed.formatted()) shaders warmed up" }
            return "\(ready.formatted()) shaders ready"+(added > 0 ? " · \(added.formatted()) new this time" : "")
        case .skipped: return "Skipped this time · prepared shaders kept"
        case nil: return ""
        }
    }
    /// Why the warm-up runs, under its list.
    var warmingNote:String? {
        phase == .warming || warmed > 0 ? "After an update, Recall builds every shader Overwatch has used on this Mac once, so your first match runs smoothly." : nil
    }
    /// Shown in place of the list when this preparation had nothing to do.
    var explanation:String {
        if learned == 0 && ready == 0 { return "Recall learns each shader the first time Overwatch uses it on this Mac, then prepares it before your next session." }
        return "Everything learned so far was prepared earlier. Shaders new to this Mac are prepared before your next session."
    }
}

/// The launching screen's details: one summary line, and for players who open it,
/// each shader as it's prepared.
struct GraphicsDetails: View {
    let progress:GraphicsProgress
    @AppStorage("graphicsDetailsExpanded") private var expanded=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:12) {
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
                }.buttonStyle(.plain).accessibilityLabel(progress.summary).accessibilityHint(expanded ? "Hides the shaders" : "Shows each shader as it’s prepared")
                if expanded {
                    if progress.items.isEmpty {
                        Text(progress.phase == .done ? progress.explanation : "Shaders appear here as they’re prepared.")
                            .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    } else { list }
                    if let note=progress.warmingNote {
                        Text(note).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    if progress.keptFolders > 0 || progress.learned > 0 {
                        Text(footer).font(LauncherStyle.font(12)).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
        }
    }
    private var footer:String {
        var parts=[String]()
        if progress.learned > 0 { parts.append("\(progress.learned.formatted()) learned on this Mac") }
        if progress.keptFolders > 0 { parts.append("kept from before your Mac restarted") }
        return parts.joined(separator:" · ")
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
