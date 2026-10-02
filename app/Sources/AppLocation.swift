import AppKit
import Darwin

// Recall runs from an Applications folder. Opened from its disk image, or from a
// download macOS runs in a temporary read-only location (App Translocation), it
// copies itself there, verified like an update, and reopens. Older copies of the
// same app, such as the one installed under its former name, are moved to the
// Trash, never deleted: two copies would each install their own game components.
enum AppLocation {
    struct Copy: Equatable {
        let url: URL
        let version: String
        let build: Int
    }
    static var folders: [URL] {
        [URL(fileURLWithPath:"/Applications"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    /// Running from a disk image or a translocated copy.
    static func needsMove(_ bundle:URL) -> Bool {
        bundle.path.hasPrefix("/Volumes/") || bundle.path.contains("/AppTranslocation/")
    }
    /// Directly inside one of the Applications folders.
    static func isInstalled(_ bundle:URL, folders:[URL]=folders) -> Bool {
        let parent=bundle.deletingLastPathComponent().standardizedFileURL.path
        return folders.contains { $0.standardizedFileURL.path == parent }
    }
    /// The location the user opened, behind App Translocation.
    static func original(of bundle:URL) -> URL {
        guard bundle.path.contains("/AppTranslocation/"),
              let handle=dlopen("/System/Library/Frameworks/Security.framework/Security",RTLD_LAZY),
              let symbol=dlsym(handle,"SecTranslocateCreateOriginalPathForURL") else { return bundle }
        typealias Create=@convention(c) (CFURL,UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        return (unsafeBitCast(symbol,to:Create.self)(bundle as CFURL,nil)?.takeRetainedValue() as URL?) ?? bundle
    }
    static func copy(at url:URL) -> (identifier:String, copy:Copy)? {
        guard let info=NSDictionary(contentsOf:url.appendingPathComponent("Contents/Info.plist")),
              let identifier=info["CFBundleIdentifier"] as? String else { return nil }
        return (identifier,Copy(url:url,version:info["CFBundleShortVersionString"] as? String ?? "0",
                                build:Int(info["CFBundleVersion"] as? String ?? "") ?? 0))
    }
    /// Version first, then build: 1.0.0 (22) is newer than 1.0.0 (21) and 0.1.6.
    static func isOlder(_ copy:Copy, than version:String, build:Int) -> Bool {
        UpdateCheck.isNewer(version,than:copy.version) || (copy.version == version && copy.build < build)
    }
    /// Copies of this app (same bundle identifier) older than the given version,
    /// directly inside the folders. Never the copy being kept.
    static func olderCopies(identifier:String, version:String, build:Int, keeping:URL, in folders:[URL]=folders) -> [Copy] {
        let fm=FileManager.default
        return folders.flatMap { folder -> [Copy] in
            let items=(try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []
            return items.compactMap { url in
                guard url.pathExtension == "app",url.standardizedFileURL.path != keeping.standardizedFileURL.path,
                      let found=copy(at:url),found.identifier == identifier,isOlder(found.copy,than:version,build:build) else { return nil }
                return found.copy
            }
        }
    }
    /// Moves each copy to the Trash; returns the ones moved.
    static func retire(_ copies:[Copy]) -> [Copy] {
        copies.filter { (try? FileManager.default.trashItem(at:$0.url,resultingItemURL:nil)) != nil }
    }
    /// Where this app goes: "<name>.app" in the first folder the user can write
    /// to that does not hold a different app of that name.
    /// Only installing creates a missing folder (~/Applications).
    static func destination(identifier:String, folders:[URL]=folders, create:Bool=true) throws -> URL {
        let fm=FileManager.default
        var nameTaken=false
        for folder in folders {
            if !fm.fileExists(atPath:folder.path) {
                guard create else { return folder.appendingPathComponent(Brand.name+".app") }
                try? fm.createDirectory(at:folder,withIntermediateDirectories:true)
            }
            guard fm.isWritableFile(atPath:folder.path) else { continue }
            let target=folder.appendingPathComponent(Brand.name+".app")
            if fm.fileExists(atPath:target.path),copy(at:target)?.identifier != identifier { nameTaken=true;continue }
            return target
        }
        throw SetupFailure(code:nameTaken ? "app_name_taken" : "app_move_failed")
    }
    /// Copies `source` to `target`: checked like an update (notarized, this
    /// team, this identifier and version) before it replaces anything there.
    static func install(_ source:URL, at target:URL, team:String, identifier:String, version:String) async throws {
        let fm=FileManager.default
        let staged=target.deletingLastPathComponent().appendingPathComponent(".\(Brand.name) \(version).app")
        try? fm.removeItem(at:staged)
        do {
            _ = try await UpdateInstaller.tool("/usr/bin/ditto",[source.path,staged.path])
            try UpdateInstaller.verify(staged,team:team,identifier:identifier,version:version)
            // Opening it from the disk image was the user's approval; the
            // verified copy starts without the download quarantine.
            _ = try? await UpdateInstaller.tool("/usr/bin/xattr",["-dr","com.apple.quarantine",staged.path])
            if fm.fileExists(atPath:target.path) { _ = try fm.replaceItemAt(target,withItemAt:staged) }
            else { try fm.moveItem(at:staged,to:target) }
        } catch {
            try? fm.removeItem(at:staged)
            throw (error as? SetupFailure) ?? SetupFailure(code:"app_move_failed")
        }
    }
    /// The mount point of the disk image holding `url`, if any. Only disk images
    /// count, so a physical drive is never ejected.
    static func diskImageVolume(containing url:URL) async -> URL? {
        guard url.path.hasPrefix("/Volumes/"),
              let data=try? await UpdateInstaller.tool("/usr/bin/hdiutil",["info","-plist"]),
              let info=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any],
              let images=info["images"] as? [[String:Any]] else { return nil }
        let points=images.flatMap { ($0["system-entities"] as? [[String:Any]] ?? []).compactMap { $0["mount-point"] as? String } }
        return points.first { url.path.hasPrefix($0+"/") }.map { URL(fileURLWithPath:$0,isDirectory:true) }
    }
}
