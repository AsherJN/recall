import Foundation

/// A log's lines as grep and sed count them: split at LF, a CRLF (one Character in Swift) included,
/// but not at a lone CR (Overwatch's crash reports end some lines in CR CR LF).
func logLines<S:StringProtocol>(_ text:S)->[S.SubSequence] {
    text.split(omittingEmptySubsequences:false,whereSeparator:{ $0 == "\n" || $0 == "\r\n" })
}

/// Save Logs (Settings › Advanced, Help › Support; REC-40): the logs of the player's recent
/// sessions in one zip, with personal details removed (LogCleaner), a short timeline for people in
/// the player's language (Summary.txt) and, for engineers and AI assistants, an index of every file
/// and of the moments worth reading, with their lines (index.json; README.md explains the layout).
/// It works with logging off too: Battle.net and Overwatch keep their own logs, and Recall keeps
/// each session's (portable_logs.h). Newest sessions first, as many as fit in GitHub's 25 MB
/// attachment limit, the newest always. Overwatch's crash dumps never go in: they hold the game's memory.
enum LogBundle {
    struct Input:Sendable {
        var root:URL
        /// The Support Report as Help shows it.
        var report:String
        var appVersion:String
        var runtime:String
        var logging:LoggingSetting
        var custom:String
        var since:Date?
        var now=Date()
        /// GitHub's attachment limit, for the zip.
        var limit=25_000_000
        /// The guide for engineers and AI assistants (app/Resources/LogsReadme.md).
        var readme:URL?
        /// Whose details to remove; nil for this Mac's (tests give their own).
        var identity:LogCleaner.Identity?
    }
    struct Saved:Sendable {
        var bytes:Int64
        var sessions:Int
        var olderLeftOut:Int
    }
    enum Source:String { case recallSession="recall_session",recall,battlenetClient="battlenet_client",battlenetAgent="battlenet_agent",
                              battlenetSetup="battlenet_setup",overwatch,overwatchCrash="overwatch_crash" }
    struct File { let url:URL;let path:String;let source:Source;let time:Date }
    /// One Battle.net start: Recall's record of it (from 1.5) and Battle.net's own log of it.
    struct Session { var start:Date;var name:String?;var files:[File]=[] }
    struct Written { let file:File;let lines:Int;let bytes:Int;let repeats:Int }

    static func defaultName(_ now:Date=Date())->String {
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.dateFormat="yyyy-MM-dd-HHmm"
        return "\(Brand.name)-logs-\(format.string(from:now)).zip"
    }

    static func save(_ input:Input, to destination:URL) throws -> Saved {
        let fm=FileManager.default
        let staging=fm.temporaryDirectory.appendingPathComponent("\(Brand.name)-logs-\(UUID().uuidString)")
        let folder=staging.appendingPathComponent(destination.deletingPathExtension().lastPathComponent)
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:staging) }
        let found=collect(root:input.root)
        let sessions=group(found.files,starts:found.starts)
        let ids=accountIDs(root:input.root,files:found.files)
        var cleaner=input.identity.map { LogCleaner(user:$0.user,fullName:$0.fullName,hosts:$0.hosts,accountIDs:ids) } ?? LogCleaner.forThisMac(accountIDs:ids)
        var written:[Written]=[]
        var estimate=0,included=0
        // Newest first, while the zip would stay under the limit; the newest always.
        for session in sessions.reversed() {
            var batch:[Written]=[],packed=0
            for file in session.files {
                guard let data=try? Data(contentsOf:file.url) else { continue }
                var text=cleaner.clean(String(decoding:data,as:UTF8.self))
                var repeats=0
                if file.source == .recallSession && file.url.pathExtension == "log" { (text,repeats)=collapse(text) }
                let bytes=Data(text.utf8)
                let target=folder.appendingPathComponent(file.path)
                try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try bytes.write(to:target)
                packed+=((try? (bytes as NSData).compressed(using:.zlib))?.length ?? bytes.count)
                batch.append(Written(file:file,lines:bytes.reduce(0) { $1 == 10 ? $0+1 : $0 },bytes:bytes.count,repeats:repeats))
            }
            if included > 0 && estimate+packed > input.limit {
                for item in batch { try? fm.removeItem(at:folder.appendingPathComponent(item.file.path)) }
                break
            }
            estimate+=packed;included+=1;written+=batch
        }
        let kept=Array(sessions.suffix(included)),olderLeftOut=sessions.count-included,overLimit=estimate > input.limit
        try Data(cleaner.clean(input.report).utf8).write(to:folder.appendingPathComponent("support-report.json"))
        if let readme=input.readme,fm.fileExists(atPath:readme.path) { try fm.copyItem(at:readme,to:folder.appendingPathComponent("README.md")) }
        let read=Moments.read(written.map(\.file),folder:folder)
        let index=index(input,kept:kept,written:written,read:read,removed:cleaner.found,olderLeftOut:olderLeftOut,dumps:found.dumps,overLimit:overLimit)
        try JSONSerialization.data(withJSONObject:index,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("index.json"))
        let summary=Summary.text(input,moments:read.moments,removed:cleaner.found,olderLeftOut:olderLeftOut,overLimit:overLimit)
        try Data(summary.utf8).write(to:folder.appendingPathComponent("Summary.txt"))
        if fm.fileExists(atPath:destination.path) { try fm.removeItem(at:destination) }
        let zip=Process();zip.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        zip.arguments=["-c","-k","--sequesterRsrc","--keepParent",folder.path,destination.path]
        try zip.run();zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        let bytes=((try? fm.attributesOfItem(atPath:destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return Saved(bytes:bytes,sessions:included,olderLeftOut:olderLeftOut)
    }

    /// Every log Recall, Battle.net and Overwatch keep, with the time each belongs to: a start time in
    /// its name, otherwise when it was last written. Recall's process lists (session-query, left only by
    /// a worker that stopped mid-check) and Overwatch's crash dumps stay out.
    static func collect(root:URL)->(files:[File],starts:[Date],dumps:Int) {
        let fm=FileManager.default
        var files:[File]=[],starts:[Date]=[],dumps=0
        func children(_ url:URL)->[URL] { ((try? fm.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isRegularFileKey,.contentModificationDateKey])) ?? []).sorted { $0.path < $1.path } }
        func modified(_ url:URL)->Date { (try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        func regular(_ url:URL)->Bool { (try? url.resourceValues(forKeys:[.isRegularFileKey]))?.isRegularFile == true }
        func logs(_ url:URL)->[URL] { children(url).filter { regular($0) && $0.pathExtension.lowercased() == "log" } }
        let recall=root.appendingPathComponent("logs")
        for session in children(recall.appendingPathComponent("sessions")) {
            guard let start=stamp(session.lastPathComponent) else { continue }
            starts.append(start)
            for file in children(session) where regular(file) {
                files.append(File(url:file,path:"recall/sessions/\(session.lastPathComponent)/\(file.lastPathComponent)",source:.recallSession,time:start))
            }
        }
        for file in logs(recall) where !file.lastPathComponent.hasPrefix("session-query-") {
            files.append(File(url:file,path:"recall/\(file.lastPathComponent)",source:.recall,time:modified(file)))
        }
        let drive=root.appendingPathComponent("environment/drive_c")
        for user in children(drive.appendingPathComponent("users")) where user.lastPathComponent != "Public" {
            for file in logs(user.appendingPathComponent("AppData/Local/Battle.net/Logs")) {
                let start=stamp(file.lastPathComponent)
                if let start { starts.append(start) }
                files.append(File(url:file,path:"battlenet/client/\(file.lastPathComponent)",source:.battlenetClient,time:start ?? modified(file)))
            }
            let overwatch=user.appendingPathComponent("Documents/Overwatch/Logs")
            for file in logs(overwatch) {
                files.append(File(url:file,path:"overwatch/\(file.lastPathComponent)",source:.overwatch,time:modified(file)))
            }
            for file in children(overwatch.appendingPathComponent("errors")) where regular(file) {
                if file.pathExtension.lowercased() == "dmp" { dumps+=1;continue }
                guard file.pathExtension.lowercased() == "txt" else { continue }
                files.append(File(url:file,path:"overwatch/errors/\(file.lastPathComponent)",source:.overwatchCrash,time:modified(file)))
            }
        }
        let agent=drive.appendingPathComponent("ProgramData/Battle.net/Agent")
        for folder in children(agent) where folder.lastPathComponent.hasPrefix("Agent.") {
            for file in logs(folder.appendingPathComponent("Logs")) {
                let start=stamp(file.lastPathComponent)
                // The agent starts with Battle.net and keeps one set of logs per start, from before 1.5 too.
                if let start,file.lastPathComponent.hasPrefix("Agent-") { starts.append(start) }
                files.append(File(url:file,path:"battlenet/agent/\(folder.lastPathComponent)/\(file.lastPathComponent)",source:.battlenetAgent,
                                  time:start ?? modified(file)))
            }
        }
        for file in logs(agent.appendingPathComponent("Logs")) {
            files.append(File(url:file,path:"battlenet/agent/\(file.lastPathComponent)",source:.battlenetAgent,time:stamp(file.lastPathComponent) ?? modified(file)))
        }
        for setup in children(drive.appendingPathComponent("ProgramData/Battle.net/Setup")) {
            for file in logs(setup.appendingPathComponent("Logs")) {
                files.append(File(url:file,path:"battlenet/setup/\(setup.lastPathComponent)/\(file.lastPathComponent)",source:.battlenetSetup,time:modified(file)))
            }
        }
        return (files,starts,dumps)
    }
    /// One session per Battle.net start: Recall's record and Battle.net's log of the same start are
    /// seconds apart. Each file goes with the start before it, earlier files with the first.
    static func group(_ files:[File], starts:[Date])->[Session] {
        var sessions:[Session]=[]
        for start in starts.sorted() {
            if let last=sessions.last,start.timeIntervalSince(last.start) < 120 { continue }
            sessions.append(Session(start:start))
        }
        if sessions.isEmpty { sessions=[Session(start:files.map(\.time).min() ?? Date())] }
        for file in files {
            // Battle.net's client log can start a moment before Recall's record of the same start.
            let index=sessions.lastIndex { $0.start <= file.time.addingTimeInterval(120) } ?? 0
            sessions[index].files.append(file)
            if file.source == .recallSession,sessions[index].name == nil { sessions[index].name=String(file.path.split(separator:"/")[2]) }
        }
        return sessions
    }
    /// A start time in a log's name: Recall's 20261019T210211Z, Battle.net's 20261019T191300 (both UTC).
    static func stamp(_ name:String)->Date? {
        guard let range=name.range(of:#"[0-9]{8}T[0-9]{6}"#,options:.regularExpression) else { return nil }
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone=TimeZone(identifier:"UTC");format.dateFormat="yyyyMMdd'T'HHmmss"
        return format.date(from:String(name[range]))
    }
    /// Battle.net account numbers to remove wherever they appear: the folders Battle.net names by
    /// account, and the numbers in Overwatch's crash reports.
    static func accountIDs(root:URL, files:[File])->Set<String> {
        let fm=FileManager.default
        var ids=Set<String>()
        for user in (try? fm.contentsOfDirectory(at:root.appendingPathComponent("environment/drive_c/users"),includingPropertiesForKeys:nil)) ?? [] {
            for folder in ["AppData/Local/Battle.net/Account","AppData/Local/Battle.net/BrowserCaches"] {
                for item in (try? fm.contentsOfDirectory(atPath:user.appendingPathComponent(folder).path)) ?? [] where item.count >= 5 && item.allSatisfy(\.isNumber) { ids.insert(item) }
            }
        }
        let number=try! NSRegularExpression(pattern:#"(?i)account[\x20_]?id[\x20:=]+([0-9]{5,})"#)
        for file in files where file.source == .overwatchCrash {
            guard let data=try? Data(contentsOf:file.url) else { continue }
            let text=String(decoding:data,as:UTF8.self) as NSString
            for match in number.matches(in:text as String,range:NSRange(location:0,length:text.length)) { ids.insert(text.substring(with:match.range(at:1))) }
        }
        return ids
    }
    /// A run of three or more identical lines (Wine's clock, process and thread aside) is kept once,
    /// followed by a marker with the count and the last one's prefix.
    static func collapse(_ text:String)->(String,Int) {
        let prefix=try! NSRegularExpression(pattern:#"^(?:[0-9]+\.[0-9]{3}:)?(?:[0-9a-f]{4}:){1,2}"#)
        func split(_ line:Substring)->(prefix:String,body:Substring) {
            let s=String(line) as NSString
            guard let match=prefix.firstMatch(in:s as String,range:NSRange(location:0,length:s.length)) else { return ("",line) }
            let head=s.substring(to:match.range.length)
            return (head,line.dropFirst(head.count))
        }
        var out:[String]=[],removed=0
        var body:Substring?,count=0,lastPrefix=""
        func flush() {
            if count >= 2 { out.append("[recall:repeated count=\(count) last=\"\(lastPrefix)\"]");removed+=count }
            else if count == 1,let body { out.append(lastPrefix+body) }
            count=0
        }
        for line in logLines(text) {
            let parts=split(line)
            if let body,parts.body == body,!body.isEmpty { count+=1;lastPrefix=parts.prefix;continue }
            flush()
            out.append(String(line));body=parts.body
        }
        flush()
        return (out.joined(separator:"\n"),removed)
    }
    private static func index(_ input:Input, kept:[Session], written:[Written], read:Moments.Found, removed:[LogCleaner.Category:Int],
                              olderLeftOut:Int, dumps:Int, overLimit:Bool)->[String:Any] {
        let iso=ISO8601DateFormatter()
        let info=ProcessInfo.processInfo
        var logging:[String:Any]=["setting":input.logging.rawValue]
        if input.logging == .custom { logging["custom"]=input.custom }
        if let since=input.since { logging["since"]=iso.string(from:since) }
        let paths=Set(written.map(\.file.path))
        let sessions:[[String:Any]]=kept.reversed().map { session in
            var entry:[String:Any]=["started":iso.string(from:session.start),"files":session.files.map(\.path).filter(paths.contains)]
            if let name=session.name,paths.contains("recall/sessions/\(name)/session.json") { entry["record"]="recall/sessions/\(name)/session.json" }
            return entry
        }
        return ["schema":1,"saved":iso.string(from:input.now),"guide":"README.md","summary":"Summary.txt","support_report":"support-report.json",
                "recall":["app_version":input.appVersion,"runtime":input.runtime,"macos":info.operatingSystemVersionString,
                          "chip":Summary.chip,"memory_gib":info.physicalMemory>>30],
                "logging":logging,
                "removed":Dictionary(uniqueKeysWithValues:removed.map { ($0.key.rawValue,$0.value) }),
                "left_out":["older_sessions":olderLeftOut,"crash_dumps":dumps,"over_github_limit":overLimit],
                "sessions":sessions,
                "files":written.map { ["path":$0.file.path,"source":$0.file.source.rawValue,"bytes":$0.bytes,"lines":$0.lines,"repeats_collapsed":$0.repeats] },
                "moments":read.moments.map(\.json),
                "errors":read.errors]
    }
}

/// What happened when, read from the saved (cleaned) files: the timeline's moments, each with its
/// file and line, and the error lines each file repeats most.
enum Moments {
    struct Moment {
        var time:Date?
        var kind:String
        var file:String
        var line:Int
        var excerpt:String
        var extra:[String:Any]=[:]
        var json:[String:Any] {
            var value=extra
            value["kind"]=kind;value["file"]=file;value["line"]=line;value["text"]=excerpt
            if let time { value["time"]=ISO8601DateFormatter().string(from:time) }
            return value
        }
    }
    struct Found { var moments:[Moment];var errors:[[String:Any]] }
    /// Wine's clock (+timestamp) in a session: when it started, and Wine's count of milliseconds then.
    struct Clock { let started:Date;let ms:UInt32
        func date(_ seconds:Double)->Date {
            let delta=Int32(bitPattern:UInt32(truncatingIfNeeded:Int64((seconds*1000).rounded()))&-ms)
            return started.addingTimeInterval(Double(delta)/1000)
        }
    }
    static func read(_ files:[LogBundle.File], folder:URL)->Found {
        var moments:[Moment]=[],errors:[[String:Any]]=[]
        var clocks:[String:Clock]=[:]
        let iso=ISO8601DateFormatter()
        func text(_ file:LogBundle.File)->String? { (try? Data(contentsOf:folder.appendingPathComponent(file.path))).map { String(decoding:$0,as:UTF8.self) } }
        // Recall's records first: their clocks place Wine's lines.
        for file in files where file.source == .recallSession && file.url.lastPathComponent == "session.json" {
            guard let data=try? Data(contentsOf:folder.appendingPathComponent(file.path)),
                  let record=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                  let started=(record["started"] as? String).flatMap(iso.date(from:)) else { continue }
            let session=file.path.replacingOccurrences(of:"/session.json",with:"")
            if let ms=record["wine_clock_ms"] as? NSNumber { clocks[session]=Clock(started:started,ms:ms.uint32Value) }
            var extra:[String:Any]=["logging":record["logging"] as? String ?? "off"]
            for key in ["logging_custom","winedebug"] { if let value=record[key] { extra[key]=value } }
            moments.append(Moment(time:started,kind:"session_started",file:file.path,line:1,excerpt:extra["logging"] as! String,extra:extra))
            for game in record["games"] as? [[String:Any]] ?? [] {
                if let time=(game["started"] as? String).flatMap(iso.date(from:)) { moments.append(Moment(time:time,kind:"game_started",file:file.path,line:1,excerpt:"")) }
                if let time=(game["ended"] as? String).flatMap(iso.date(from:)) { moments.append(Moment(time:time,kind:"game_ended",file:file.path,line:1,excerpt:"")) }
            }
            if let ended=(record["ended"] as? String).flatMap(iso.date(from:)) { moments.append(Moment(time:ended,kind:"session_ended",file:file.path,line:1,excerpt:"")) }
        }
        let winePrefix=try! NSRegularExpression(pattern:#"^([0-9]+\.[0-9]{3}):"#)
        let repeatPrefix=try! NSRegularExpression(pattern:#"^\[recall:repeated[^"]*"([0-9]+\.[0-9]{3}):"#)
        for file in files {
            guard file.source != .recallSession || file.url.pathExtension == "log",let content=text(file) else { continue }
            // Numbered as grep numbers them; Windows programs' lines keep a CR at the end, dropped here.
            let lines=logLines(content).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
            switch file.source {
            case .recallSession:
                let clock=clocks[file.path.components(separatedBy:"/").dropLast().joined(separator:"/")]
                var last:Date?,counts:[String:(line:Int,count:Int,text:String)]=[:]
                for (number,line) in lines.enumerated() {
                    let s=String(line)
                    // A line's own clock, or the last of a run collapse kept once.
                    if let clock,let match=(winePrefix.firstMatch(in:s,range:NSRange(location:0,length:(s as NSString).length)) ?? repeatPrefix.firstMatch(in:s,range:NSRange(location:0,length:(s as NSString).length))),
                       let seconds=Double((s as NSString).substring(with:match.range(at:1))) { last=clock.date(seconds) }
                    if s.contains("wine: Unhandled") || s.contains("Unhandled exception") {
                        moments.append(Moment(time:last,kind:"windows_program_error",file:file.path,line:number+1,excerpt:String(s.prefix(300))))
                    }
                    if let range=s.range(of:":err:") ?? (s.hasPrefix("err:") ? s.range(of:"err:") : nil) {
                        let key=String(s[range.upperBound...]).replacingOccurrences(of:#"0x[0-9a-fA-F]+|[0-9a-fA-F]{8,}"#,with:"…",options:.regularExpression)
                        counts[key,default:(number+1,0,String(s.prefix(300)))].count+=1
                    }
                }
                errors+=counts.values.sorted { $0.count > $1.count }.prefix(40).map { ["file":file.path,"line":$0.line,"count":$0.count,"text":$0.text] }
            case .battlenetAgent:
                if file.url.lastPathComponent.hasPrefix("Operations-") {
                    for operation in BattleNetRecord.operations(content) {
                        moments.append(Moment(time:Date(timeIntervalSince1970:operation.began),kind:"battlenet_update",file:file.path,line:operation.line,
                                              excerpt:operation.product,extra:["product":operation.product,"finished":operation.finished,"cancelled":operation.cancelled,
                                                                            "waited_seconds":Int(operation.waited.rounded()),"seconds":Int((operation.end-operation.began).rounded())]))
                    }
                }
                for (number,line) in lines.enumerated() where line.contains("Build marked non-playable for ") {
                    let s=String(line)
                    let entry=BattleNetRecord.notPlayable(s).first ?? ""
                    let parts=entry.split(separator:" ")
                    moments.append(Moment(time:BattleNetRecord.time(line).map(Date.init(timeIntervalSince1970:)),kind:"battlenet_not_playable",file:file.path,line:number+1,
                                          excerpt:String(s.prefix(300)),extra:["product":parts.first.map(String.init) ?? "","code":parts.count > 1 ? String(parts[1]) : ""]))
                }
            case .battlenetClient:
                // "D 2026-10-19 19:13:00.859626 [Main] …", in UTC; E is an error.
                if let first=lines.first(where:{ clientTime($0) != nil }) { moments.append(Moment(time:clientTime(first),kind:"battlenet_started",file:file.path,line:1,excerpt:"")) }
                // Battle.net held Play until its own timer ran out (the game wasn't marked playable yet).
                for (number,line) in lines.enumerated() where line.contains("Launch timer expired") {
                    moments.append(Moment(time:clientTime(line),kind:"battlenet_launch_wait",file:file.path,line:number+1,excerpt:String(line.prefix(300))))
                }
                var counts:[String:(line:Int,count:Int,text:String)]=[:]
                for (number,line) in lines.enumerated() where line.hasPrefix("E ") && line.count > 28 {
                    let key=String(line.dropFirst(28)).replacingOccurrences(of:#"[0-9]+"#,with:"#",options:.regularExpression)
                    counts[key,default:(number+1,0,String(line.prefix(300)))].count+=1
                }
                errors+=counts.values.sorted { $0.count > $1.count }.prefix(20).map { ["file":file.path,"line":$0.line,"count":$0.count,"text":$0.text] }
            case .overwatchCrash:
                // Blizzard's report: <BlizzardError.Summary:> "Overwatch - 2.25.0.0: EXCEPTION_…", the
                // crashing thread's frames, Running Time, then Most Recent Logs, the game's last lines.
                let number=lines.firstIndex { $0.hasPrefix("Overwatch - ") } ?? lines.firstIndex { $0.contains("EXCEPTION") }
                    ?? lines.firstIndex { !$0.trimmingCharacters(in:CharacterSet(charactersIn:"- ")).isEmpty } ?? 0
                let headline=lines.isEmpty ? "" : lines[number].trimmingCharacters(in:.whitespaces)
                var extra:[String:Any]=[:]
                if let thread=lines.firstIndex(where:{ $0.contains("**Crashing Thread**") }) {
                    extra["top_frames"]=lines[(thread+1)...].prefix { !$0.trimmingCharacters(in:.whitespaces).isEmpty }.prefix(4).map { $0.trimmingCharacters(in:.whitespaces) }
                }
                if let running=lines.first(where:{ $0.hasPrefix("Running Time:") }) { extra["running_time"]=running.dropFirst(13).trimmingCharacters(in:.whitespaces) }
                var recent:[(number:Int,text:Substring)]=[]
                if let start=lines.firstIndex(where:{ $0.hasPrefix("Most Recent Logs:") }) {
                    for index in (start+1)..<lines.count {
                        if lines[index].hasPrefix("-----") { break }
                        if !lines[index].trimmingCharacters(in:.whitespaces).isEmpty { recent.append((index+1,lines[index])) }
                    }
                }
                if let lastLine=recent.last { extra["last_log_line"]=["line":lastLine.number,"text":String(lastLine.text.prefix(300))] }
                // Just before: in the game's last few lines.
                extra["after_failed_read"]=recent.suffix(3).contains { $0.text.contains("File read failed") || $0.text.contains("Failed to read data from TACT") }
                moments.append(Moment(time:file.time,kind:"overwatch_crash",file:file.path,line:number+1,excerpt:String(headline.prefix(300)),extra:extra))
            case .overwatch:
                // Overwatch's own log covers its latest run: "[…] [2026-10-19T19:14:39.179Z]: …".
                guard file.url.lastPathComponent == "Overwatch.log" else { break }
                let stamped=lines.enumerated().compactMap { (number,line)->(Int,Date)? in
                    guard let range=line.range(of:#"\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]{12}Z\]"#,options:.regularExpression) else { return nil }
                    return iso.date(from:String(line[range].dropFirst().dropLast().prefix(19))+"Z").map { (number+1,$0) }
                }
                if let first=stamped.first { moments.append(Moment(time:first.1,kind:"overwatch_log_started",file:file.path,line:first.0,excerpt:"")) }
                if let last=stamped.last,stamped.count > 1 { moments.append(Moment(time:last.1,kind:"overwatch_log_ended",file:file.path,line:last.0,excerpt:"")) }
            default: break
            }
        }
        moments.sort { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
        return Found(moments:moments,errors:errors)
    }
    private static func clientTime(_ line:Substring)->Date? {
        guard line.count > 27,line.dropFirst(1).first == " " else { return nil }
        return clientFormat.date(from:String(line.dropFirst(2).prefix(19)))
    }
    private static let clientFormat:DateFormatter={
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone=TimeZone(identifier:"UTC");format.dateFormat="yyyy-MM-dd HH:mm:ss"
        return format
    }()
}

/// Summary.txt: what happened, day by day, in the player's language, then what was left out and
/// removed. The moments come from Moments; minor ones (short Battle.net updates, errors Wine prints
/// in passing) stay in index.json.
enum Summary {
    static var chip:String {
        var size=0
        sysctlbyname("machdep.cpu.brand_string",nil,&size,nil,0)
        var value=[CChar](repeating:0,count:max(size,1))
        sysctlbyname("machdep.cpu.brand_string",&value,&size,nil,0)
        return String(decoding:value.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)
    }
    static func text(_ input:LogBundle.Input, moments:[Moments.Moment], removed:[LogCleaner.Category:Int], olderLeftOut:Int, overLimit:Bool)->String {
        let info=ProcessInfo.processInfo
        let version=info.operatingSystemVersion
        let macOS="\(version.majorVersion).\(version.minorVersion)"+(version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        var lines=[L("{0} logs",Brand.name),
                   L("Saved {0}",input.now.formatted(date:.long,time:.shortened)),
                   L("{0} {1} · engine {2} · macOS {3} · {4} · {5} GB memory",Brand.name,input.appVersion,input.runtime,macOS,chip,String(info.physicalMemory>>30)),
                   input.logging == .off ? L("Logging: off") : L("Logging: {0}",input.logging == .custom ? input.custom : input.logging.title)]
        if let since=input.since,input.logging != .off { lines.append(L("Logging has been on since {0}.",since.formatted(date:.abbreviated,time:.shortened))) }
        // What Recall recorded is told from its record; Battle.net's and Overwatch's own logs of the
        // same moment are left out (and an Overwatch log that ends in a crash isn't a close).
        let recorded=Recorded(moments)
        // Newest day first, so what just happened is at the top; each day in order.
        var days:[(title:String,lines:[String])]=[]
        for moment in moments {
            guard let time=moment.time,let sentence=sentence(moment,recorded:recorded) else { continue }
            let today=time.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            if days.last?.title != today { days.append((today,[])) }
            let clock=time.formatted(date:.omitted,time:.shortened)
            days[days.count-1].lines.append("  \(clock)  "+sentence.joined(separator:"\n  "+String(repeating:" ",count:clock.count)+"  "))
        }
        for day in days.reversed() { lines+=["",day.title]+day.lines }
        if days.isEmpty { lines+=["",L("Nothing to report in these logs.")] }
        lines.append("")
        if olderLeftOut > 0 { lines.append(L("Older sessions left out: {0}. With them, this file would be too large to attach on GitHub.",String(olderLeftOut))) }
        if overLimit { lines.append(L("This file is larger than GitHub’s 25 MB limit. Share it through a cloud storage link instead.")) }
        let names=LogCleaner.Category.allCases.filter { (removed[$0] ?? 0) > 0 }.map(\.title)
        lines.append(names.isEmpty ? L("No personal details were found in these logs.") : L("Removed before saving: {0}.",names.formatted(.list(type:.and))))
        lines.append(L("The full logs are in this folder. For an AI assistant, start with README.md."))
        return lines.joined(separator:"\n")+"\n"
    }
    struct Recorded {
        var starts:[Date],games:[Date],ends:[Date],crashes:[Date]
        init(_ moments:[Moments.Moment]) {
            func times(_ kinds:Set<String>)->[Date] { moments.filter { kinds.contains($0.kind) }.compactMap(\.time) }
            starts=times(["session_started"]);games=times(["game_started"]);ends=times(["game_ended"]);crashes=times(["overwatch_crash"])
        }
        static func near(_ times:[Date],_ time:Date)->Bool { times.contains { abs($0.timeIntervalSince(time)) < 120 } }
    }
    /// The sentence a moment gets, or nil when it's minor.
    private static func sentence(_ moment:Moments.Moment, recorded:Recorded)->[String]? {
        switch moment.kind {
        case "session_started":
            let setting=LoggingSetting(rawValue:moment.extra["logging"] as? String ?? "") ?? .off
            return [setting == .off ? L("Battle.net opened.") : L("Battle.net opened. Logging: {0}.",setting == .custom ? (moment.extra["logging_custom"] as? String ?? setting.title) : setting.title)]
        case "battlenet_started":
            guard let time=moment.time,!Recorded.near(recorded.starts,time) else { return nil }
            return [L("Battle.net opened.")]
        case "overwatch_log_started":
            guard let time=moment.time,!Recorded.near(recorded.games,time) else { return nil }
            return [L("Overwatch started.")]
        case "overwatch_log_ended":
            guard let time=moment.time,!Recorded.near(recorded.ends,time),!Recorded.near(recorded.crashes,time) else { return nil }
            return [L("Overwatch closed.")]
        case "battlenet_update":
            let seconds=moment.extra["seconds"] as? Int ?? 0,finished=moment.extra["finished"] as? Bool ?? true,cancelled=moment.extra["cancelled"] as? Bool ?? false
            guard seconds >= 30 else { return nil }
            let duration=Duration.seconds(seconds).formatted(.units(allowed:[.hours,.minutes,.seconds],width:.abbreviated,maximumUnitCount:2))
            let product=moment.extra["product"] as? String ?? ""
            if product == "agent" {
                return [finished ? L("Battle.net updated itself ({0}).",duration)
                        : cancelled ? L("Battle.net stopped updating itself after {0}.",duration) : L("Battle.net was still updating itself after {0} when its log ends.",duration)]
            }
            let name=["pro","prometheus"].contains(product) ? L("Overwatch") : product
            return [finished ? L("Battle.net updated {0} ({1}).",name,duration)
                    : cancelled ? L("Battle.net stopped updating {0} after {1}.",name,duration) : L("Battle.net was still updating {0} after {1} when its log ends.",name,duration)]
        case "battlenet_not_playable":
            // The update agent's own 2110 (its helper service check) comes with most starts (REC-39).
            let product=moment.extra["product"] as? String ?? ""
            guard product != "agent" else { return nil }
            return [L("Battle.net marked {0} not playable (code {1}).",["pro","prometheus"].contains(product) ? L("Overwatch") : product,moment.extra["code"] as? String ?? "")]
        case "game_started": return [L("Overwatch started.")]
        case "game_ended": return [L("Overwatch closed.")]
        case "session_ended": return [L("Battle.net closed.")]
        case "overwatch_crash":
            var lines=[L("Overwatch crashed: {0}",moment.excerpt)]
            if moment.extra["after_failed_read"] as? Bool == true { lines.append(L("Just before, it couldn’t read one of its game files.")) }
            return lines
        case "windows_program_error": return [L("A Windows program stopped with an error ({0}, line {1}).",moment.file,String(moment.line))]
        default: return nil
        }
    }
}
