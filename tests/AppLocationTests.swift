import Foundation

// Moving out of the disk image. Without arguments: location rules, version
// order, which copies are retired and where the app may go, on scratch folders.
// With arguments (a notarized Developer ID build, then an empty scratch folder):
// a real install into <scratch>/Applications that replaces an older copy, keeps
// a different app of the same name and clears the download quarantine. Never
// point it at /Applications.
@main struct AppLocationTests {
    static let identifier="org.overwatch2mac.launcher"
    static func fakeApp(_ url:URL, identifier:String=identifier, version:String, build:Int) throws {
        try FileManager.default.createDirectory(at:url.appendingPathComponent("Contents"),withIntermediateDirectories:true)
        let info:NSDictionary=["CFBundleIdentifier":identifier,"CFBundleShortVersionString":version,"CFBundleVersion":String(build)]
        precondition(info.write(to:url.appendingPathComponent("Contents/Info.plist"),atomically:true))
    }
    @MainActor static func main() async throws {
        let fm=FileManager.default
        precondition(AppLocation.needsMove(URL(fileURLWithPath:"/Volumes/Recall/Recall.app")))
        precondition(AppLocation.needsMove(URL(fileURLWithPath:"/private/var/folders/x/T/AppTranslocation/ABC/d/Recall.app")))
        precondition(!AppLocation.needsMove(URL(fileURLWithPath:"/Applications/Recall.app")))
        precondition(AppLocation.original(of:URL(fileURLWithPath:"/Applications/Recall.app")).path == "/Applications/Recall.app")
        let current=AppLocation.Copy(url:URL(fileURLWithPath:"/x"),version:"1.0.0",build:22)
        precondition(AppLocation.isOlder(AppLocation.Copy(url:current.url,version:"1.0.0",build:21),than:"1.0.0",build:22))
        precondition(AppLocation.isOlder(AppLocation.Copy(url:current.url,version:"0.1.6",build:30),than:"1.0.0",build:22))
        precondition(!AppLocation.isOlder(current,than:"1.0.0",build:22))
        precondition(!AppLocation.isOlder(AppLocation.Copy(url:current.url,version:"1.0.1",build:1),than:"1.0.0",build:22))

        let scratch=fm.temporaryDirectory.appendingPathComponent("recall-location-\(UUID().uuidString)")
        defer { try? fm.removeItem(at:scratch) }
        let system=scratch.appendingPathComponent("Applications"), personal=scratch.appendingPathComponent("home/Applications")
        try fm.createDirectory(at:system,withIntermediateDirectories:true)
        precondition(AppLocation.isInstalled(system.appendingPathComponent("Recall.app"),folders:[system,personal]))
        precondition(!AppLocation.isInstalled(scratch.appendingPathComponent("Recall.app"),folders:[system,personal]))
        // Only older copies of this app are retired: not the kept one, a newer
        // one, another app, or anything outside the folders' top level.
        let kept=system.appendingPathComponent("Recall.app")
        try fakeApp(system.appendingPathComponent("Overwatch 2 Mac.app"),version:"0.1.6",build:20)
        try fakeApp(system.appendingPathComponent("Overwatch 2 Mac RC.app"),version:"1.0.0",build:21)
        try fakeApp(kept,version:"1.0.0",build:22)
        try fakeApp(system.appendingPathComponent("Newer.app"),version:"1.0.1",build:1)
        try fakeApp(system.appendingPathComponent("Flashcards.app"),identifier:"com.example.recall",version:"0.1",build:1)
        try fakeApp(system.appendingPathComponent("Games/Overwatch 2 Mac.app"),version:"0.1.0",build:1)
        let older=AppLocation.olderCopies(identifier:identifier,version:"1.0.0",build:22,keeping:kept,in:[system,personal])
        precondition(Set(older.map(\.url.lastPathComponent)) == ["Overwatch 2 Mac.app","Overwatch 2 Mac RC.app"],"\(older)")
        // The destination never replaces a different app with the same name.
        let first=try AppLocation.destination(identifier:identifier,folders:[system,personal])
        precondition(first.path == kept.path)
        try fm.removeItem(at:kept)
        try fakeApp(kept,identifier:"com.example.recall",version:"3.0",build:1)
        let unchecked=try AppLocation.destination(identifier:identifier,folders:[system,personal],create:false)
        precondition(unchecked.path == personal.appendingPathComponent("Recall.app").path)
        precondition(!fm.fileExists(atPath:personal.path),"Checking a destination must not create folders")
        let fallback=try AppLocation.destination(identifier:identifier,folders:[system,personal])
        precondition(fallback.path == personal.appendingPathComponent("Recall.app").path)
        try fakeApp(personal.appendingPathComponent("Recall.app"),identifier:"com.example.other",version:"1",build:1)
        do { _ = try AppLocation.destination(identifier:identifier,folders:[system,personal]);fatalError("Replaced another app") }
        catch let e as SetupFailure { precondition(e.code == "app_name_taken") }
        let disk=await AppLocation.diskImageVolume(containing:URL(fileURLWithPath:"/Applications/Safari.app"))
        precondition(disk == nil)
        print("PASS: location rules, version order, older copies, destination never replaces another app")

        let args=CommandLine.arguments
        guard args.count == 3 else { return }
        let source=URL(fileURLWithPath:args[1]), root=URL(fileURLWithPath:args[2])
        precondition(!root.path.hasPrefix("/Applications"),"Use a scratch folder")
        guard let team=UpdateInstaller.team(of:source),let info=NSDictionary(contentsOf:source.appendingPathComponent("Contents/Info.plist")),
              let version=info["CFBundleShortVersionString"] as? String,let build=Int(info["CFBundleVersion"] as? String ?? "") else { fatalError("Needs a Developer ID build") }
        let folders=[root.appendingPathComponent("Applications"),root.appendingPathComponent("home/Applications")]
        try fm.createDirectory(at:folders[0],withIntermediateDirectories:true)
        try fakeApp(folders[0].appendingPathComponent("Overwatch 2 Mac.app"),version:"0.1.6",build:20)
        try fakeApp(folders[0].appendingPathComponent("Recall.app"),version:"1.0.0",build:build-1)
        let target=try AppLocation.destination(identifier:identifier,folders:folders)
        precondition(target.path == folders[0].appendingPathComponent("Recall.app").path)
        // A wrong version is refused and leaves the older copy in place.
        do { try await AppLocation.install(source,at:target,team:team,identifier:identifier,version:"9.9.9");fatalError("Installed a mismatched version") }
        catch let e as SetupFailure { precondition(e.code == "update_signature_invalid") }
        precondition(AppLocation.copy(at:target)?.copy.build == build-1)
        try await AppLocation.install(source,at:target,team:team,identifier:identifier,version:version)
        try UpdateInstaller.verify(target,team:team,identifier:identifier,version:version)
        precondition(AppLocation.copy(at:target)?.copy.build == build)
        precondition(getxattr(target.path,"com.apple.quarantine",nil,0,0,0) < 0,"Quarantine was kept")
        let retire=AppLocation.olderCopies(identifier:identifier,version:version,build:build,keeping:target,in:folders)
        precondition(retire.map(\.url.lastPathComponent) == ["Overwatch 2 Mac.app"])
        let leftovers=try fm.contentsOfDirectory(atPath:folders[0].path).filter { $0.hasPrefix(".") && $0 != ".DS_Store" }
        precondition(leftovers.isEmpty,"Left behind: \(leftovers)")
        print("PASS: real install of \(version) (\(build)) over an older copy; mismatched version refused; quarantine cleared")
    }
}
