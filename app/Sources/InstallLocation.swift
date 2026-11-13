import Foundation

// The one data folder that holds Battle.net, Overwatch, the runtime and caches.
// The internal default needs no decision; another folder is checked here when
// picked, and the setup helper enforces the same drive rules for any new folder.
enum InstallLocation {
    static let folderName="Overwatch2Mac"
    static let savedKey="installLocation"
    /// REC-44: an installation the player moved away from (Set Up on This Mac Instead), kept one
    /// choice away so a misclick never means setting everything up again.
    static let otherKey="otherInstallLocation"
    /// Help › Troubleshooting's answer for a case-sensitive drive.
    static let caseSensitiveTopic="case-sensitive"
    /// Help › Troubleshooting's answer for a folder macOS won't let Recall create or change (REC-54).
    static let folderAccessTopic="folder-access"
    /// The folder whose permissions stop setup, for Show in Finder: the data folder once it
    /// exists, otherwise the nearest folder above it that does (Application Support for J, REC-54).
    static func folderToFix(_ root:URL)->URL {
        var folder=root.standardizedFileURL
        while !FileManager.default.fileExists(atPath:folder.path) && folder.path != "/" { folder=folder.deletingLastPathComponent() }
        return folder
    }
    static var standard:URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(folderName) }
    static func isStandard(_ root:URL)->Bool { root.standardizedFileURL.path == standard.standardizedFileURL.path }
    /// Picking an existing app-made folder reconnects it; any other folder gets
    /// an Overwatch2Mac folder inside it.
    static func root(forChosen folder:URL)->URL {
        let folder=folder.standardizedFileURL
        let marker=folder.appendingPathComponent(".overwatch-2-mac-owner").path
        return folder.lastPathComponent == folderName || FileManager.default.fileExists(atPath:marker) ? folder : folder.appendingPathComponent(folderName)
    }
    /// False while the drive holding the folder is disconnected. The helper never
    /// creates the parent, so an unplugged drive can't become a stray folder.
    static func isAvailable(_ root:URL)->Bool {
        var directory:ObjCBool=false
        let parent=root.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath:parent.path,isDirectory:&directory),directory.boolValue else { return false }
        // An unclean eject can leave an empty /Volumes/<name> folder behind.
        let parts=root.standardizedFileURL.pathComponents
        guard parts.count>3,parts[1] == "Volumes" else { return true }
        let volume=(try? parent.resourceValues(forKeys:[.volumeURLKey]).volume)?.standardizedFileURL.path
        return volume == NSString.path(withComponents:Array(parts[0...2]))
    }
    static func driveName(_ root:URL)->String {
        if let name=try? existing(root).resourceValues(forKeys:[.volumeLocalizedNameKey]).volumeLocalizedName,isAvailable(root) { return name }
        let parts=root.standardizedFileURL.pathComponents
        return parts.count>2 && parts[1] == "Volumes" ? parts[2] : L("your drive")
    }
    /// The location dropdown's icon for a folder on this Mac or on another drive.
    static func symbol(_ root:URL)->String { isInternal(root) ? "folder" : "externaldrive" }
    /// The icon for an installation that may be on a disconnected drive.
    static func driveSymbol(_ root:URL)->String { isStandard(root) ? "internaldrive" : "externaldrive" }
    static func isInternal(_ root:URL)->Bool {
        (try? existing(root).resourceValues(forKeys:[.volumeIsInternalKey]).volumeIsInternal) ?? true
    }
    /// Short dropdown title: "Macintosh HD" for the default, "T7 › Games" otherwise.
    static func title(_ root:URL)->String {
        let drive=driveName(root)
        if isStandard(root) { return drive }
        let folder=root.deletingLastPathComponent()
        // A disconnected drive (REC-44's installation left behind): named from its path.
        if !isAvailable(root) {
            let parts=folder.standardizedFileURL.pathComponents
            return parts.count>3 && parts[1] == "Volumes" ? "\(drive) › \(folder.lastPathComponent)" : drive
        }
        let volume=(try? folder.resourceValues(forKeys:[.volumeURLKey]).volume)?.standardizedFileURL
        return volume == folder.standardizedFileURL ? drive : "\(drive) › \(folder.lastPathComponent)"
    }
    /// The reason a chosen folder can't hold an installation, or nil.
    static func problem(for root:URL)->String? { issue(for:root)?.message }
    /// Why a chosen folder can't hold an installation, and the Help topic that shows a way
    /// round it, when there is one.
    struct Issue { let message:String; var helpTopic:String?=nil }
    static func issue(for root:URL)->Issue? {
        let folder=root.deletingLastPathComponent()
        let keys:Set<URLResourceKey>=[.volumeIsReadOnlyKey,.volumeIsLocalKey,.volumeTypeNameKey,.volumeLocalizedFormatDescriptionKey,.volumeSupportsCaseSensitiveNamesKey,.volumeLocalizedNameKey,.isUbiquitousItemKey]
        guard let values=try? folder.resourceValues(forKeys:keys) else { return Issue(message:L("That folder can’t be read. Choose another location.")) }
        let drive=values.volumeLocalizedName ?? L("This drive")
        if values.volumeIsLocal == false { return Issue(message:L("Network drives aren’t supported. Choose a drive connected to this Mac.")) }
        if values.volumeIsReadOnly == true { return Issue(message:L("“{0}” is read-only. Choose another location.",drive)) }
        if !["apfs","hfs"].contains((values.volumeTypeName ?? "").lowercased()) {
            return Issue(message:L("“{0}” is formatted as {1}. Choose a drive formatted as APFS or Mac OS Extended. Reformatting a drive in Disk Utility erases it.",drive,values.volumeLocalizedFormatDescription ?? L("an unsupported format")))
        }
        // REC-47: a player with one drive was told to erase it. An APFS drive takes a second volume
        // that isn't case-sensitive, sharing its free space; Mac OS Extended needs a partition.
        if values.volumeSupportsCaseSensitiveNames == true {
            let apfs=values.volumeTypeName?.lowercased() == "apfs"
            return Issue(message:apfs
                ? L("“{0}” is case-sensitive, which Windows games don’t support. You don’t need to erase it: add a volume that isn’t case-sensitive in Disk Utility, then choose that volume.",drive)
                : L("“{0}” is case-sensitive, which Windows games don’t support. Choose another drive, or add a partition that isn’t case-sensitive in Disk Utility.",drive),
                helpTopic:caseSensitiveTopic)
        }
        let path=folder.path
        if values.isUbiquitousItem == true || path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/") {
            return Issue(message:L("Folders synced to iCloud Drive or other cloud storage aren’t supported. Choose a folder that isn’t synced."))
        }
        let fm=FileManager.default
        if fm.fileExists(atPath:root.path),!fm.fileExists(atPath:root.appendingPathComponent(".overwatch-2-mac-owner").path),
           (try? fm.contentsOfDirectory(atPath:root.path))?.isEmpty == false {
            return Issue(message:L("That “{0}” folder already contains other files. Choose another location.",folderName))
        }
        return nil
    }
    /// A folder setup used: the app's marker and its saved state. A disconnected drive can't
    /// say, so its folder counts until the drive is back.
    static func holdsInstallation(_ root:URL)->Bool {
        guard isAvailable(root) else { return true }
        let fm=FileManager.default
        return fm.fileExists(atPath:root.appendingPathComponent(".overwatch-2-mac-owner").path) && fm.fileExists(atPath:root.appendingPathComponent("state.json").path)
    }
    /// REC-82: where a move under way is going, kept until the app has taken the new place.
    static let pendingKey="pendingInstallLocation"
    /// A folder that is an installation now: its drive is there, with the app's marker and saved state.
    static func isInstallation(_ root:URL)->Bool {
        let fm=FileManager.default
        return isAvailable(root) && fm.fileExists(atPath:root.appendingPathComponent(".overwatch-2-mac-owner").path) && fm.fileExists(atPath:root.appendingPathComponent("state.json").path)
    }
    /// The part copy of a move the player gave up on while its drive was unplugged: it goes when
    /// the drive is next connected (AppModel.discardRememberedPartCopy).
    static let discardKey="abandonedMoveLocation"
    /// A move the app didn't see finish (it quit or crashed, or lost power, as the copy took its
    /// final name). The worker gives the copy its marker and final name only once it is whole and
    /// checked, so an installation at the pending place is the one to use.
    enum PendingMove:Equatable {
        /// The installation is at the pending place. `left` is the folder it came from, if that is
        /// still an installation (it hadn't reached the Trash).
        case finished(left:URL?)
        /// The pending place's drive isn't connected, so it can't say. `showsDrive`: the folder in
        /// use holds no installation either, so the app asks for the drive instead of setting up anew.
        case waiting(showsDrive:Bool)
        /// The drive is there with no installation at the pending place: the move never finished.
        case unfinished
    }
    static func pendingMove(current:URL,pending:URL)->PendingMove {
        if pending.standardizedFileURL.path == current.standardizedFileURL.path { return .unfinished }
        guard isAvailable(pending) else { return .waiting(showsDrive:isAvailable(current) && !isInstallation(current)) }
        guard isInstallation(pending) else { return .unfinished }
        return .finished(left:isInstallation(current) ? current : nil)
    }
    /// The part copy a move that didn't finish leaves beside its destination (portable_move.h).
    static func partCopy(for destination:URL)->URL { URL(fileURLWithPath:destination.standardizedFileURL.path+".moving") }
    /// Two folders on one volume: a move between them is a rename, with nothing to copy.
    static func sameVolume(_ a:URL,_ b:URL)->Bool {
        let volume={ (url:URL) in (try? existing(url).resourceValues(forKeys:[.volumeURLKey]).volume)?.standardizedFileURL.path }
        guard let first=volume(a),let second=volume(b) else { return false }
        return first == second
    }
    /// Free room where a folder is or will be, as Finder counts it (with what macOS clears on demand).
    static func freeBytes(at root:URL)->Int64? {
        guard let values=try? existing(root).resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey,.volumeAvailableCapacityKey]) else { return nil }
        return max(values.volumeAvailableCapacityForImportantUsage ?? 0,Int64(values.volumeAvailableCapacity ?? 0))
    }
    /// Why the installation at `root` can't move to a chosen folder, or nil. The drive rules are
    /// setup's (issue(for:)); a folder that already holds an installation is never merged into.
    static func moveIssue(from root:URL,to destination:URL)->Issue? {
        let from=root.standardizedFileURL.resolvingSymlinksInPath().path,to=destination.standardizedFileURL.resolvingSymlinksInPath().path
        if to == from { return Issue(message:L("Overwatch and Battle.net are already there. Choose another location.")) }
        if to.hasPrefix(from+"/") { return Issue(message:L("That folder is inside the installation itself. Choose another location.")) }
        if FileManager.default.fileExists(atPath:destination.appendingPathComponent(".overwatch-2-mac-owner").path) {
            return Issue(message:L("That location already holds an installation. Choose another location."))
        }
        return issue(for:destination)
    }
    /// What a folder takes on its drive (symbolic links, such as Wine's drive letters, aren't
    /// followed), for the question before it moves to the Trash.
    static func size(_ root:URL)->Int64 {
        let keys:[URLResourceKey]=[.totalFileAllocatedSizeKey,.isRegularFileKey]
        guard let walk=FileManager.default.enumerator(at:root,includingPropertiesForKeys:keys,options:[],errorHandler:{ _,_ in true }) else { return 0 }
        var total:Int64=0
        for case let url as URL in walk {
            guard let values=try? url.resourceValues(forKeys:Set(keys)),values.isRegularFile == true else { continue }
            total+=Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
    private static func existing(_ root:URL)->URL { FileManager.default.fileExists(atPath:root.path) ? root : root.deletingLastPathComponent() }
}
