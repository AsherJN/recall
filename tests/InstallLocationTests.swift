import Foundation

// Checks the app's install-location rules against real mounted disk images.
// Build: swiftc -parse-as-library app/Sources/Localization.swift app/Sources/InstallLocation.swift tests/InstallLocationTests.swift
@main struct InstallLocationTests {
    static func run(_ args:[String]) {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/hdiutil");p.arguments=args
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try! p.run();p.waitUntilExit();precondition(p.terminationStatus == 0,"hdiutil \(args.first!) failed")
    }
    static func main() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent("ow2-location-tests-\(getpid())")
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        var mounts=[URL]()
        defer { for m in mounts { run(["detach","-force",m.path]) };try? fm.removeItem(at:base) }
        func volume(_ filesystem:String,_ name:String,readOnly:Bool=false)->URL {
            let image=base.appendingPathComponent(name+".sparseimage"),mount=base.appendingPathComponent(name)
            run(["create","-size","64m","-fs",filesystem,"-type","SPARSE","-volname",name,image.path])
            run(["attach","-nobrowse"]+(readOnly ? ["-readonly"] : [])+["-mountpoint",mount.path,image.path])
            mounts.append(mount);return mount
        }
        // REC-54: Show in Finder selects the data folder once it exists, otherwise the nearest folder above it.
        let missing=base.appendingPathComponent("Library/Application Support/Overwatch2Mac")
        precondition(InstallLocation.folderToFix(missing).path == base.standardizedFileURL.path,"folder to fix skipped past an existing folder")
        try fm.createDirectory(at:missing.deletingLastPathComponent(),withIntermediateDirectories:true)
        precondition(InstallLocation.folderToFix(missing).lastPathComponent == "Application Support")
        try fm.createDirectory(at:missing,withIntermediateDirectories:true)
        precondition(InstallLocation.folderToFix(missing).path == missing.standardizedFileURL.path)
        let apfs=volume("APFS","OW2APFS")
        let root=InstallLocation.root(forChosen:apfs)
        precondition(root.lastPathComponent == "Overwatch2Mac" && root.deletingLastPathComponent().path == apfs.standardizedFileURL.path)
        precondition(InstallLocation.problem(for:root) == nil,"APFS drive refused")
        precondition(InstallLocation.isAvailable(root) && InstallLocation.title(root) == "OW2APFS")
        try fm.createDirectory(at:apfs.appendingPathComponent("Games"),withIntermediateDirectories:true)
        precondition(InstallLocation.title(InstallLocation.root(forChosen:apfs.appendingPathComponent("Games"))) == "OW2APFS › Games")
        // An existing app-made folder reconnects; one with other files is refused.
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        try "ow2-native-setup-v1\n".write(to:root.appendingPathComponent(".overwatch-2-mac-owner"),atomically:true,encoding:.utf8)
        precondition(InstallLocation.root(forChosen:root) == root.standardizedFileURL && InstallLocation.problem(for:root) == nil)
        let foreign=apfs.appendingPathComponent("Other/Overwatch2Mac")
        try fm.createDirectory(at:foreign,withIntermediateDirectories:true)
        try "keep".write(to:foreign.appendingPathComponent("personal.txt"),atomically:true,encoding:.utf8)
        precondition(InstallLocation.problem(for:foreign)?.contains("already contains") == true)
        let exfat=InstallLocation.root(forChosen:volume("ExFAT","OW2EXFAT"))
        precondition(InstallLocation.problem(for:exfat)?.contains("APFS or Mac OS Extended") == true,"ExFAT accepted")
        // REC-47: case-sensitive drives are refused with a way round that keeps their files.
        let sensitive=InstallLocation.root(forChosen:volume("Case-sensitive APFS","OW2CASE"))
        let apfsIssue=InstallLocation.issue(for:sensitive)
        precondition(apfsIssue?.message.contains("case-sensitive") == true,"case-sensitive accepted")
        precondition(apfsIssue?.message.contains("add a volume") == true && apfsIssue?.helpTopic == InstallLocation.caseSensitiveTopic,"case-sensitive APFS without its way round")
        let sensitiveHFS=InstallLocation.issue(for:InstallLocation.root(forChosen:volume("Case-sensitive HFS+","OW2CASEHFS")))
        precondition(sensitiveHFS?.message.contains("add a partition") == true && sensitiveHFS?.helpTopic == InstallLocation.caseSensitiveTopic,"case-sensitive Mac OS Extended without its way round")
        precondition(InstallLocation.issue(for:exfat)?.helpTopic == nil)
        let locked=InstallLocation.root(forChosen:volume("APFS","OW2LOCKED",readOnly:true))
        precondition(InstallLocation.problem(for:locked)?.contains("read-only") == true,"read-only accepted")
        // Disconnected: unavailable, still named from its path, never created.
        let unplugged=URL(fileURLWithPath:"/Volumes/Unplugged OW2 Test SSD/Games/Overwatch2Mac")
        precondition(!InstallLocation.isAvailable(unplugged) && InstallLocation.driveName(unplugged) == "Unplugged OW2 Test SSD")
        precondition(InstallLocation.title(unplugged) == "Unplugged OW2 Test SSD › Games")
        precondition(InstallLocation.title(URL(fileURLWithPath:"/Volumes/Unplugged OW2 Test SSD/Overwatch2Mac")) == "Unplugged OW2 Test SSD")
        precondition(InstallLocation.holdsInstallation(unplugged),"a disconnected installation isn't offered back")
        precondition(InstallLocation.isStandard(InstallLocation.standard) && InstallLocation.problem(for:InstallLocation.standard) == nil)
        print("PASS: install location accepts APFS and reconnects owned folders; refuses ExFAT, case-sensitive (with Help's way round), read-only and foreign folders; detects disconnected drives; finds the folder to fix")
    }
}
