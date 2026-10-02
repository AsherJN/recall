import Foundation

// The one data folder that holds Battle.net, Overwatch, the runtime and caches.
// The internal default needs no decision; another folder is checked here when
// picked, and the setup helper enforces the same drive rules for any new folder.
enum InstallLocation {
    static let folderName="Overwatch2Mac"
    static let savedKey="installLocation"
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
        return parts.count>2 && parts[1] == "Volumes" ? parts[2] : "your drive"
    }
    static func isInternal(_ root:URL)->Bool {
        (try? existing(root).resourceValues(forKeys:[.volumeIsInternalKey]).volumeIsInternal) ?? true
    }
    /// Short dropdown title: "Macintosh HD" for the default, "T7 › Games" otherwise.
    static func title(_ root:URL)->String {
        let drive=driveName(root)
        if isStandard(root) { return drive }
        let folder=root.deletingLastPathComponent()
        let volume=(try? folder.resourceValues(forKeys:[.volumeURLKey]).volume)?.standardizedFileURL
        return volume == folder.standardizedFileURL ? drive : "\(drive) › \(folder.lastPathComponent)"
    }
    /// The reason a chosen folder can't hold an installation, or nil.
    static func problem(for root:URL)->String? {
        let folder=root.deletingLastPathComponent()
        let keys:Set<URLResourceKey>=[.volumeIsReadOnlyKey,.volumeIsLocalKey,.volumeTypeNameKey,.volumeLocalizedFormatDescriptionKey,.volumeSupportsCaseSensitiveNamesKey,.volumeLocalizedNameKey,.isUbiquitousItemKey]
        guard let values=try? folder.resourceValues(forKeys:keys) else { return "That folder can’t be read. Choose another location." }
        let drive=values.volumeLocalizedName ?? "This drive"
        if values.volumeIsLocal == false { return "Network drives aren’t supported. Choose a drive connected to this Mac." }
        if values.volumeIsReadOnly == true { return "“\(drive)” is read-only. Choose another location." }
        if !["apfs","hfs"].contains((values.volumeTypeName ?? "").lowercased()) {
            return "“\(drive)” is formatted as \(values.volumeLocalizedFormatDescription ?? "an unsupported format"). Choose a drive formatted as APFS or Mac OS Extended. Reformatting a drive in Disk Utility erases it."
        }
        if values.volumeSupportsCaseSensitiveNames == true { return "“\(drive)” is case-sensitive, which Windows games don’t support. Choose another drive." }
        let path=folder.path
        if values.isUbiquitousItem == true || path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/") {
            return "Folders synced to iCloud Drive or other cloud storage aren’t supported. Choose a folder that isn’t synced."
        }
        let fm=FileManager.default
        if fm.fileExists(atPath:root.path),!fm.fileExists(atPath:root.appendingPathComponent(".overwatch-2-mac-owner").path),
           (try? fm.contentsOfDirectory(atPath:root.path))?.isEmpty == false {
            return "That “\(folderName)” folder already contains other files. Choose another location."
        }
        return nil
    }
    private static func existing(_ root:URL)->URL { FileManager.default.fileExists(atPath:root.path) ? root : root.deletingLastPathComponent() }
}
