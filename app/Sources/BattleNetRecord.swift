import Foundation

/// The support report's Battle.net record (REC-31): what Battle.net's update agent did on its last
/// few starts, read from the agent's own logs. Each update says how long it waited behind another
/// (Overwatch's waits behind the agent updating itself) and how long it ran; then the codes Battle.net
/// gave for marking something not playable (2123: its permissions check), and the download servers'
/// names. Only those leave the logs: no account details, addresses, tags or paths.
enum BattleNetRecord {
    static func read(root:URL, starts:Int=3)->[[String:Any]] {
        let fm=FileManager.default
        let agent=root.appendingPathComponent("environment/drive_c/ProgramData/Battle.net/Agent")
        // One set of logs per start, named by its UTC start time (Operations-20261019T191303.log),
        // in the folder of the agent version that wrote them (Agent.9824/Logs).
        var logs:[String:(version:String,files:[String:URL])]=[:]
        for folder in (try? fm.contentsOfDirectory(at:agent,includingPropertiesForKeys:nil)) ?? [] where folder.lastPathComponent.hasPrefix("Agent.") {
            let version=String(folder.lastPathComponent.dropFirst(6))
            for file in (try? fm.contentsOfDirectory(at:folder.appendingPathComponent("Logs"),includingPropertiesForKeys:nil)) ?? [] {
                let parts=file.deletingPathExtension().lastPathComponent.split(separator:"-")
                guard file.pathExtension == "log",parts.count == 2,parts[1].count == 15 else { continue }
                logs[String(parts[1]),default:(version,[:])].files[String(parts[0])]=file
            }
        }
        return logs.keys.sorted().suffix(starts).reversed().map { stamp in
            let start=logs[stamp]!
            // A bad byte must not hide the rest of a log. Lines end in CRLF (one Character), hence isNewline.
            let text={ (kind:String) in start.files[kind].flatMap { try? Data(contentsOf:$0) }.map { String(decoding:$0,as:UTF8.self) } ?? "" }
            var record:[String:Any]=["updates":updates(text("Operations")),"not_playable":notPlayable(text("Agent")),
                                     "download_servers":servers(text("bc"))]
            if let started=started(stamp) { record["started"]=started }
            if start.version.allSatisfy(\.isNumber) { record["agent_version"]=start.version }
            return record
        }
    }
    /// Each OP_UPDATE the agent ran: queued, then active (after whatever ran before it), then
    /// completed. One still running when the logs end (Battle.net closed, or it never finished) says
    /// so and how long it had run.
    static func updates(_ text:String)->[[String:Any]] {
        operations(text).map { operation in
            var update:[String:Any]=["product":operation.product,"finished":operation.finished,"waited_seconds":Int(operation.waited.rounded()),"seconds":Int((operation.end-operation.began).rounded())]
            if operation.cancelled { update["cancelled"]=true }
            return update
        }
    }
    /// An update with its times (seconds since 1970, UTC) and the line it was queued on, from 1 (as
    /// grep counts them); Save Logs puts them on its timeline (LogBundle). One Battle.net cancelled
    /// ("Cancel requested … done Canceling") ended then and didn't finish.
    struct Operation { let product:String;let queued:Double?;let began:Double;let end:Double;let finished:Bool;var cancelled=false;let line:Int
        var waited:Double { queued.map { max(0,began-$0) } ?? 0 } }
    static func operations(_ text:String)->[Operation] {
        var queued:[String:(time:Double,line:Int)]=[:],active:[String:Double]=[:],cancel:[String:Double]=[:],result:[Operation]=[]
        var last:Double?
        for (index,raw) in logLines(text).enumerated() {
            let line=raw.hasSuffix("\r") ? raw.dropLast() : raw
            guard let time=time(line) else { continue }
            last=time
            guard !line.contains("Concurrent operation"),line.contains("OP_UPDATE for '"),let product=product(line) else { continue }
            if line.contains("Queue operation - OP_UPDATE") { queued[product]=(time,index+1);active[product]=nil;cancel[product]=nil }
            else if line.contains("replaced by OP_UPDATE for '\(product)'") { active[product]=time }
            else if line.contains("Cancel requested for active operation - OP_UPDATE") { cancel[product]=time }
            else if line.hasSuffix("OP_UPDATE for '\(product)' completed") || line.hasSuffix("OP_UPDATE for '\(product)' done Canceling") {
                let cancelled=line.hasSuffix("done Canceling")
                result.append(operation(product,queued[product],active[product],cancelled ? (cancel[product] ?? time) : time,!cancelled,cancelled,index+1))
                queued[product]=nil;active[product]=nil;cancel[product]=nil
            }
        }
        for (product,since) in queued {
            result.append(operation(product,since,active[product],cancel[product] ?? last ?? since.time,false,cancel[product] != nil,since.line))
        }
        return result
    }
    private static func operation(_ product:String,_ queued:(time:Double,line:Int)?,_ active:Double?,_ end:Double,_ finished:Bool,_ cancelled:Bool,_ line:Int)->Operation {
        let began=active ?? end
        return Operation(product:product,queued:queued?.time,began:began,end:max(began,end),finished:finished,cancelled:cancelled,line:queued?.line ?? line)
    }
    /// "Build marked non-playable for prometheus: Permissions check failure (2123)" → "prometheus 2123".
    static func notPlayable(_ text:String)->[String] {
        var codes:[String]=[]
        for line in text.split(whereSeparator:\.isNewline) {
            guard let range=line.range(of:"Build marked non-playable for "),let colon=line[range.upperBound...].firstIndex(of:":") else { continue }
            let product=String(line[range.upperBound..<colon])
            let code=String(line[colon...].reversed().drop { !$0.isNumber }.prefix { $0.isNumber }.reversed())
            let entry="\(product) \(code)"
            if valid(product),!code.isEmpty,!codes.contains(entry),codes.count < 10 { codes.append(entry) }
        }
        return codes
    }
    /// The servers' names from "[tact] Adding server node 0. Server 'level3.blizzard.com' | Address …".
    static func servers(_ text:String)->[String] {
        var names=Set<String>()
        for line in text.split(whereSeparator:\.isNewline) where line.contains("Adding server node") {
            guard let range=line.range(of:"Server '"),let end=line[range.upperBound...].firstIndex(of:"'") else { continue }
            let name=line[range.upperBound..<end].lowercased()
            if !name.isEmpty,name.count <= 64,name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),name.contains(where:\.isLetter) { names.insert(name) }
        }
        return names.sorted().prefix(12).map { $0 }
    }
    /// "[I 2026-10-19 19:13:04.0700] …": the agent writes UTC, with ten-thousandths of a second.
    static func time(_ line:Substring)->Double? {
        guard line.count > 30,line.hasPrefix("["),let date=formatter.date(from:String(line.dropFirst(3).prefix(19))) else { return nil }
        return date.timeIntervalSince1970+(Double(line.dropFirst(23).prefix(4)) ?? 0)/10000
    }
    private static func started(_ stamp:String)->String? {
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone=TimeZone(identifier:"UTC");format.dateFormat="yyyyMMdd'T'HHmmss"
        guard let date=format.date(from:stamp) else { return nil }
        return ISO8601DateFormatter().string(from:date)
    }
    private static func product(_ line:Substring)->String? {
        guard let close=line.lastIndex(of:"'"),let open=line[..<close].lastIndex(of:"'") else { return nil }
        let product=String(line[line.index(after:open)..<close])
        return valid(product) ? product : nil
    }
    private static func valid(_ product:String)->Bool {
        !product.isEmpty && product.count <= 32 && product.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }
    private static let formatter:DateFormatter={
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone=TimeZone(identifier:"UTC");format.dateFormat="yyyy-MM-dd HH:mm:ss"
        return format
    }()
}
