import AppKit

/// REC-94: security software on this Mac that scans files as they're written. Bitdefender and
/// Surfshark have quarantined Recall's Windows files (.dll), and setup then stops on the files it
/// can no longer find. The failure screen names the app, so the player knows where to add an
/// exception for Recall's folder; the support report names it too.
///
/// macOS has no API for other apps' system extensions, so this reads `systemextensionsctl list`,
/// which needs no administrator. Real-time scanners are Endpoint Security extensions; VPNs and
/// other network, driver or camera extensions don't count. Anything unexpected (the command
/// missing, slow or changed) reads as "unavailable", and the failure screen falls back to its
/// general line.
enum SecuritySoftware {
    enum Check: Equatable {
        case notChecked, unavailable, found([String])
        var names:[String] { if case .found(let names)=self { return names };return [] }
        /// The support report's value: the apps' names, "none", "unavailable" or "not_checked".
        var report:Any {
            switch self {
            case .notChecked: return "not_checked"
            case .unavailable: return "unavailable"
            case .found(let names): return names.isEmpty ? "none" as Any : names as Any
            }
        }
    }
    struct Extension: Equatable { let bundleID:String; let name:String }
    static let category="com.apple.system_extension.endpoint_security"
    /// The Endpoint Security extensions the listing shows enabled and active. Each section starts
    /// with "--- <category> (…)", then a header row, then rows of tab-separated columns: enabled
    /// ("*"), active ("*"), team ID, "bundle ID (version)", name and "[state]".
    static func extensions(in listing:String) -> [Extension] {
        var inSection=false, found=[Extension]()
        for line in listing.split(separator:"\n") {
            if line.hasPrefix("---") {
                let title=line.dropFirst(3).trimmingCharacters(in:.whitespaces)
                inSection=title == category || title.hasPrefix(category+" ");continue
            }
            guard inSection else { continue }
            let columns=line.split(separator:"\t",omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:.whitespaces) }
            guard columns.count >= 6,columns[0] == "*",columns[1] == "*",columns[5].contains("activated enabled"),
                  let bundleID=columns[3].split(separator:" ").first.map(String.init),!bundleID.isEmpty,!columns[4].isEmpty else { continue }
            found.append(Extension(bundleID:bundleID,name:columns[4]))
        }
        return found
    }
    /// The names to show: the app each extension came with where macOS knows it, otherwise the
    /// extension's own name. One app with several extensions is named once.
    static func names(in listing:String, appName:(String)->String?=SecuritySoftware.appName(for:)) -> [String] {
        var names=[String]()
        for found in extensions(in:listing) {
            let name=appName(found.bundleID) ?? found.name
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
    /// The app a system extension came with. Its bundle identifier usually extends the app's
    /// (com.vendor.app.extension), so shorter and shorter prefixes are looked up.
    static func appName(for bundleID:String) -> String? {
        var parts=bundleID.split(separator:".").map(String.init)
        while parts.count > 2 {
            parts.removeLast()
            if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:parts.joined(separator:".")),url.pathExtension == "app" {
                return url.deletingPathExtension().lastPathComponent
            }
        }
        return nil
    }
    /// Reads the list off the main thread and names what it found.
    @MainActor static func check() async -> Check {
        guard let listing=await Task.detached(priority:.utility,operation:{ readListing() }).value else { return .unavailable }
        return .found(names(in:listing))
    }
    private static func readListing() -> String? {
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/systemextensionsctl")
        process.arguments=["list"]
        let output=Pipe()
        process.standardOutput=output;process.standardError=FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stop=DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline:.now()+5,execute:stop)
        let data=output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit();stop.cancel()
        guard process.terminationReason == .exit,process.terminationStatus == 0 else { return nil }
        return String(data:data,encoding:.utf8)
    }
}
