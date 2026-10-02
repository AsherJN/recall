import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

// A newer public release found on GitHub. Notes are the release's "What's new"
// bullets as plain sentences.
struct AvailableUpdate: Equatable {
    let version: String
    let notes: [String]
    let page: URL
    let download: URL
    let size: Int64
    let sha256: String
    let checksum: URL?
}

// One anonymous HTTPS request to GitHub's public API per check; nothing about
// the player or the Mac is sent. Drafts and pre-releases are never offered.
enum UpdateCheck {
    static let feed=Brand.releaseFeed
    static var installed: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0" }
    static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "") ?? 0 }

    /// Dotted numeric versions only; anything else never counts as newer.
    static func isNewer(_ candidate:String, than current:String) -> Bool {
        func parts(_ value:String) -> [Int]? {
            let fields=value.split(separator:".",omittingEmptySubsequences:false)
            guard (1...4).contains(fields.count) else { return nil }
            var numbers=[Int]()
            for field in fields { guard let number=Int(field),number>=0 else { return nil };numbers.append(number) }
            return numbers
        }
        guard let a=parts(candidate),let b=parts(current) else { return false }
        for i in 0..<max(a.count,b.count) {
            let x=i<a.count ? a[i]:0, y=i<b.count ? b[i]:0
            if x != y { return x>y }
        }
        return false
    }
    /// The bullets under the body's "What's new" heading, Markdown emphasis and links removed.
    static func notes(_ body:String) -> [String] {
        var inSection=false, items=[String]()
        for raw in body.components(separatedBy:.newlines) {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("#") {
                if inSection { break }
                let heading=line.lowercased();inSection=heading.contains("what") && heading.contains("new")
                continue
            }
            guard inSection,line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            items.append(plain(String(line.dropFirst(2))))
        }
        return Array(items.prefix(12))
    }
    static func plain(_ text:String) -> String {
        var value=text.replacingOccurrences(of:"**",with:"").replacingOccurrences(of:"__",with:"").replacingOccurrences(of:"`",with:"")
        while let open=value.range(of:"["),let middle=value.range(of:"](",range:open.upperBound..<value.endIndex),
              let close=value.range(of:")",range:middle.upperBound..<value.endIndex) {
            value.replaceSubrange(open.lowerBound..<close.upperBound,with:value[open.upperBound..<middle.lowerBound])
        }
        return value
    }
    /// GitHub's latest-release JSON. Nil when the release is not newer.
    static func parse(_ data:Data, current:String) throws -> AvailableUpdate? {
        guard let release=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let tag=release["tag_name"] as? String else {
            throw SetupFailure(code:"update_check_failed")
        }
        if release["draft"] as? Bool == true || release["prerelease"] as? Bool == true { return nil }
        let version=tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version,than:current) else { return nil }
        let assets=release["assets"] as? [[String:Any]] ?? []
        // This app's file name, or after a rename the one "<name>-<version>.dmg".
        let images=assets.filter { ($0["name"] as? String)?.hasSuffix("-\(version).dmg") == true }
        guard let disk=images.first(where:{ $0["name"] as? String == Brand.diskImage(version) }) ?? (images.count == 1 ? images[0] : nil),
              let name=disk["name"] as? String,
              let link=(disk["browser_download_url"] as? String).flatMap(URL.init(string:)),link.scheme == "https",
              let size=(disk["size"] as? NSNumber)?.int64Value,size>0 else { throw SetupFailure(code:"update_unavailable") }
        var digest=""
        if let value=disk["digest"] as? String,value.hasPrefix("sha256:") { digest=String(value.dropFirst(7)).lowercased() }
        let checksum=assets.first(where:{ $0["name"] as? String == name+".sha256" })?["browser_download_url"] as? String
        guard digest.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil || checksum != nil else {
            throw SetupFailure(code:"update_unavailable")
        }
        let page=(release["html_url"] as? String).flatMap(URL.init(string:)) ?? Brand.releases
        return AvailableUpdate(version:version,notes:notes(release["body"] as? String ?? ""),page:page,download:link,
                               size:size,sha256:digest,checksum:checksum.flatMap(URL.init(string:)))
    }
    static func latest(from feed:URL=feed, current:String=installed) async throws -> AvailableUpdate? {
        var request=URLRequest(url:feed,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue(Brand.name,forHTTPHeaderField:"User-Agent")
        let (data,response)=try await URLSession(configuration:.ephemeral).data(for:request)
        if let http=response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { throw SetupFailure(code:"update_check_failed") }
        }
        return try parse(data,current:current)
    }
}

// Replaces this app with a verified newer copy, then relaunches it. The new app
// must match GitHub's SHA-256, be notarized, carry this app's bundle identifier
// and be signed by this app's own Developer ID team. Any failure leaves the
// installed app untouched.
enum UpdateInstaller {
    static func team(of app:URL) -> String? {
        var code:SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL,[],&code) == errSecSuccess,let code else { return nil }
        var information:CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&information) == errSecSuccess,
              let values=information as? [String:Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
    static func verify(_ app:URL, team:String, identifier:String, version:String?) throws {
        var code:SecStaticCode?, requirement:SecRequirement?
        let text="anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\" and notarized"
        guard SecStaticCodeCreateWithPath(app as CFURL,[],&code) == errSecSuccess,let code,
              SecRequirementCreateWithString(text as CFString,[],&requirement) == errSecSuccess,let requirement else {
            throw SetupFailure(code:"update_signature_invalid")
        }
        let flags=SecCSFlags(rawValue:kSecCSCheckAllArchitectures|kSecCSStrictValidate|kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(code,flags,requirement,nil) == errSecSuccess else {
            throw SetupFailure(code:"update_signature_invalid")
        }
        let info=NSDictionary(contentsOf:app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == identifier,
              version == nil || info?["CFBundleShortVersionString"] as? String == version else {
            throw SetupFailure(code:"update_signature_invalid")
        }
    }
    static func sha256(of file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        var hash=SHA256()
        while let chunk=try handle.read(upToCount:4<<20),!chunk.isEmpty { hash.update(data:chunk) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    /// Runs a system tool off the main thread; its standard output is returned.
    static func tool(_ path:String, _ arguments:[String]) async throws -> Data {
        try await Task.detached(priority:.userInitiated) {
            let process=Process(), output=Pipe()
            process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments
            process.standardOutput=output;process.standardError=FileHandle.nullDevice
            try process.run()
            let data=output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw SetupFailure(code:"update_install_failed") }
            return data
        }.value
    }
    private final class ProgressObserver: NSObject, URLSessionTaskDelegate {
        let report:@Sendable (Double)->Void
        var observation:NSKeyValueObservation?
        init(_ report:@escaping @Sendable (Double)->Void) { self.report=report }
        func urlSession(_ session:URLSession, didCreateTask task:URLSessionTask) {
            observation=task.progress.observe(\.fractionCompleted) { [report] progress,_ in report(progress.fractionCompleted) }
        }
    }
    static func download(_ update:AvailableUpdate, to file:URL, progress:@escaping @Sendable (Double)->Void) async throws {
        let observer=ProgressObserver(progress)
        let (temporary,response)=try await URLSession(configuration:.ephemeral).download(for:URLRequest(url:update.download),delegate:observer)
        if let http=response as? HTTPURLResponse,http.statusCode != 200 { throw SetupFailure(code:"update_download_failed") }
        try? FileManager.default.removeItem(at:file)
        try FileManager.default.moveItem(at:temporary,to:file)
        let size=(try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.int64Value
        guard size == update.size else { throw SetupFailure(code:"update_download_failed") }
        var expected=update.sha256
        if expected.isEmpty,let checksum=update.checksum {
            let (data,_)=try await URLSession(configuration:.ephemeral).data(from:checksum)
            expected=String(String(decoding:data,as:UTF8.self).prefix(64)).lowercased()
        }
        guard expected.count == 64,try sha256(of:file) == expected else { throw SetupFailure(code:"update_hash_mismatch") }
    }
    /// Downloads, verifies and swaps the new app in place of `app`.
    static func install(_ update:AvailableUpdate, over app:URL, team:String, identifier:String,
                        work:URL, progress:@escaping @Sendable (Double)->Void) async throws {
        let fm=FileManager.default, parent=app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath:parent.path),fm.isWritableFile(atPath:app.path) else { throw SetupFailure(code:"update_location_read_only") }
        try? fm.removeItem(at:work)
        try fm.createDirectory(at:work,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:work) }
        let disk=work.appendingPathComponent("update.dmg")
        try await download(update,to:disk,progress:progress)
        // A random mount point under /Volumes, hidden from Finder: mounting over
        // a folder fails on some volumes.
        let attached=try await tool("/usr/bin/hdiutil",["attach","-nobrowse","-readonly","-noautoopen","-noverify","-mountrandom","/Volumes","-plist",disk.path])
        guard let plist=(try? PropertyListSerialization.propertyList(from:attached,format:nil)) as? [String:Any],
              let point=(plist["system-entities"] as? [[String:Any]])?.compactMap({ $0["mount-point"] as? String }).first else {
            throw SetupFailure(code:"update_install_failed")
        }
        let mount=URL(fileURLWithPath:point,isDirectory:true)
        let staged=parent.appendingPathComponent(".\(app.deletingPathExtension().lastPathComponent) \(update.version).app")
        do {
            guard let source=try fm.contentsOfDirectory(at:mount,includingPropertiesForKeys:nil).first(where:{ $0.pathExtension == "app" }) else {
                throw SetupFailure(code:"update_install_failed")
            }
            try verify(source,team:team,identifier:identifier,version:update.version)
            try? fm.removeItem(at:staged)
            _ = try await tool("/usr/bin/ditto",[source.path,staged.path])
            _ = try? await tool("/usr/bin/hdiutil",["detach",mount.path,"-force"])
            try verify(staged,team:team,identifier:identifier,version:update.version)
            _ = try fm.replaceItemAt(app,withItemAt:staged)
        } catch {
            _ = try? await tool("/usr/bin/hdiutil",["detach",mount.path,"-force"])
            try? fm.removeItem(at:staged)
            throw error
        }
    }
    /// Opens `app` once this process has exited (the single-instance lock is
    /// released at exit), first ejecting `volume`, the disk image it was opened
    /// from, when given. The helper runs in its own session so it outlives us.
    static func relaunch(_ app:URL, ejecting volume:URL?=nil) {
        let script="while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; if [ -n \"$2\" ]; then /usr/bin/hdiutil detach \"$2\" -quiet || /usr/bin/hdiutil detach \"$2\" -quiet -force; fi; /usr/bin/open \"$0\""
        let arguments=["/bin/sh","-c",script,app.path,String(getpid()),volume?.path ?? ""]
        var attributes:posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETSID))
        var argv=arguments.map { strdup($0) }+[nil]
        defer { argv.forEach { free($0) };posix_spawnattr_destroy(&attributes) }
        var pid=pid_t(0)
        _ = posix_spawn(&pid,"/bin/sh",nil,&attributes,&argv,nil)
    }
}
