import AppKit

// REC-82: Settings › General › Move… takes an installation to another drive or folder and the app
// follows it. Runs the real worker against disk images and a throwaway home folder
// (CFFIXED_USER_HOME), so "this Mac" is never the real ~/Library/Application Support/Overwatch2Mac
// and what goes to the Trash lands in the home image's own. Build with every app source but
// Main.swift, with the worker beside it where the app looks for it:
//   mkdir -p runtime/phase-3/move-installation-tests/Contents/Helpers
//   python3 scripts/build_portable_setup.py --output runtime/phase-3/move-installation-tests/Contents/Helpers/ow2-setup
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library $(ls app/Sources/*.swift | grep -v Main.swift) \
//     tests/MoveInstallationTests.swift -o runtime/phase-3/move-installation-tests/move-installation-tests
//   runtime/phase-3/move-installation-tests/move-installation-tests
// Main.swift's AppDelegate, for the one menu action the app's views name.
final class AppDelegate: NSObject { @objc func forceQuit() {} }
@main struct MoveInstallationTests {
    static func hdiutil(_ args:[String]) {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/hdiutil");p.arguments=args
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try! p.run();p.waitUntilExit();precondition(p.terminationStatus == 0,"hdiutil \(args.first!) failed")
    }
    @MainActor static func settle(_ model:AppModel) {
        let end=Date().addingTimeInterval(60)
        repeat { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) } while (model.busy || model.move.isWorking) && Date()<end
        precondition(!model.busy && !model.move.isWorking,"a step didn't finish")
    }
    @MainActor static func main() throws {
        let fm=FileManager.default
        // The first run makes a throwaway home on a disk image of its own and runs a copy of itself in it.
        guard let home=ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            let base=fm.temporaryDirectory.appendingPathComponent("move-installation-\(getpid())")
            try fm.createDirectory(at:base,withIntermediateDirectories:true)
            let homeVolume="OW2 REC82 Home \(getpid())",homeImage=base.appendingPathComponent("home.sparseimage")
            hdiutil(["create","-size","96m","-fs","APFS","-type","SPARSE","-volname",homeVolume,homeImage.path])
            hdiutil(["attach","-nobrowse",homeImage.path])
            let home=URL(fileURLWithPath:"/Volumes/\(homeVolume)/home")
            try fm.createDirectory(at:home.appendingPathComponent("Library/Application Support"),withIntermediateDirectories:true)
            let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
            p.environment=ProcessInfo.processInfo.environment.merging(["CFFIXED_USER_HOME":home.path]) { $1 }
            try p.run();p.waitUntilExit()
            hdiutil(["detach","-force","/Volumes/"+homeVolume]);try? fm.removeItem(at:base)
            // Defaults go to the real preferences: take this test's out again.
            UserDefaults.standard.removePersistentDomain(forName:ProcessInfo.processInfo.processName)
            exit(p.terminationStatus)
        }
        // Never the real installation.
        precondition(InstallLocation.standard.path.hasPrefix(home+"/"),"this Mac's location isn't the throwaway home: \(InstallLocation.standard.path)")
        let mac=InstallLocation.standard
        let volume="OW2 REC82 \(getpid())",image=fm.temporaryDirectory.appendingPathComponent("move-installation-drive-\(getpid()).sparseimage")
        hdiutil(["create","-size","96m","-fs","APFS","-type","SPARSE","-volname",volume,image.path])
        hdiutil(["attach","-nobrowse",image.path])
        defer { if fm.fileExists(atPath:"/Volumes/"+volume) { hdiutil(["detach","-force","/Volumes/"+volume]) };try? fm.removeItem(at:image) }
        let drive=URL(fileURLWithPath:"/Volumes/\(volume)/Overwatch2Mac")
        for key in [InstallLocation.savedKey,InstallLocation.otherKey,InstallLocation.pendingKey] { UserDefaults.standard.removeObject(forKey:key) }

        // An installation on this Mac, with what a move must keep: the game's bytes, Wine's links
        // (z: is a link to /, never followed) and the saved state.
        var model=AppModel()
        precondition(model.root.path == mac.path)
        model.recheck();settle(model)
        let game=Data((0..<(3<<20)).map { UInt8(truncatingIfNeeded:$0 &* 31 &+ $0>>8) })
        func content(_ root:URL)->URL { root.appendingPathComponent("environment/drive_c/Program Files (x86)/Overwatch/data.bin") }
        try fm.createDirectory(at:content(mac).deletingLastPathComponent(),withIntermediateDirectories:true)
        try fm.createDirectory(at:mac.appendingPathComponent("environment/dosdevices"),withIntermediateDirectories:true)
        try game.write(to:content(mac))
        try fm.createSymbolicLink(atPath:mac.appendingPathComponent("environment/dosdevices/c:").path,withDestinationPath:"../drive_c")
        try fm.createSymbolicLink(atPath:mac.appendingPathComponent("environment/dosdevices/z:").path,withDestinationPath:"/")
        try #"{"active_runtime":"phase2-test","battlenet_region":"global","onboarding_complete":true}"#.write(to:mac.appendingPathComponent("state.json"),atomically:true,encoding:.utf8)
        model.recheck();settle(model)
        precondition(!model.canChangeLocation,"the installation wasn't seen")
        func arrived(_ root:URL,_ what:String) {
            precondition((try? Data(contentsOf:content(root))) == game,"\(what): the game's bytes differ")
            precondition((try? fm.destinationOfSymbolicLink(atPath:root.appendingPathComponent("environment/dosdevices/z:").path)) == "/","\(what): Wine's z: link changed")
            precondition(InstallLocation.isInstallation(root) && !fm.fileExists(atPath:InstallLocation.partCopy(for:root).path),"\(what): not a whole installation")
            precondition(model.root.path == root.path && model.onboarded && !model.canChangeLocation,"\(what): the app didn't follow")
            precondition(UserDefaults.standard.string(forKey:InstallLocation.savedKey) == (InstallLocation.isStandard(root) ? nil : root.path),"\(what): the place wasn't saved")
            precondition(UserDefaults.standard.string(forKey:InstallLocation.pendingKey) == nil,"\(what): the move is still pending")
        }

        // 1. A folder that can't take it says why in Settings, and nothing opens.
        model.planMove(to:mac)
        precondition(model.move == .idle && model.sheet == nil && model.notice.contains("already there"),model.notice)
        model.planMove(to:mac.appendingPathComponent("cache/Overwatch2Mac"))
        precondition(model.move == .idle && model.notice.contains("inside the installation"),model.notice)
        let taken=URL(fileURLWithPath:"/Volumes/\(volume)/Taken/Overwatch2Mac")
        try fm.createDirectory(at:taken,withIntermediateDirectories:true)
        try "ow2-native-setup-v1\n".write(to:taken.appendingPathComponent(".overwatch-2-mac-owner"),atomically:true,encoding:.utf8)
        model.planMove(to:taken)
        precondition(model.move == .idle && model.notice.contains("already holds an installation"),model.notice)

        // 2. To the drive: copied, checked, the app follows, and the earlier copy is in the Trash
        // (the home image's, never the real one).
        model.planMove(to:drive)
        precondition(model.move == .ready(MovePlan(destination:drive,sameVolume:false)) && model.sheet == .moveInstallation && model.notice.isEmpty)
        model.startMove();settle(model)
        guard case .done(let moved)=model.move else { preconditionFailure("the move to the drive ended as \(model.move)") }
        precondition(moved.copied && moved.trashed && moved.from.path == mac.path && (moved.bytes ?? 0) >= Int64(game.count),"\(moved)")
        arrived(drive,"to the drive")
        precondition(!fm.fileExists(atPath:mac.path) && model.otherInstallation == nil,"the earlier copy is still in place")
        let trashes=URL(fileURLWithPath:home).deletingLastPathComponent().appendingPathComponent(".Trashes/\(getuid())")
        precondition(((try? fm.contentsOfDirectory(atPath:trashes.path)) ?? []).contains { (try? Data(contentsOf:content(trashes.appendingPathComponent($0)))) == game },
                     "the earlier copy isn't in the home image's trash")
        precondition(model.moveProgress.checking && model.moveProgress.bytes == model.moveProgress.total && model.moveProgress.fraction == 1,"\(model.moveProgress)")
        model.closeMove()
        precondition(model.move == .idle && model.sheet == .settings)

        // 3. To another folder on the same drive: renamed, with nothing copied and nothing for the Trash.
        let games=URL(fileURLWithPath:"/Volumes/\(volume)/Games")
        try fm.createDirectory(at:games,withIntermediateDirectories:true)
        let folder=InstallLocation.root(forChosen:games)
        model.planMove(to:folder)
        precondition(model.move == .ready(MovePlan(destination:folder,sameVolume:true)))
        model.startMove();settle(model)
        guard case .done(let renamed)=model.move else { preconditionFailure("the move on the same drive ended as \(model.move)") }
        precondition(!renamed.copied && !renamed.trashed && !fm.fileExists(atPath:drive.path),"\(renamed)")
        arrived(folder,"on the same drive")
        model.closeMove()

        // 4. A move that can't finish leaves everything where it was and says so; Try Again goes on
        // once the cause is gone; Cancel gives it up.
        try fm.createDirectory(at:mac.deletingLastPathComponent(),withIntermediateDirectories:true)
        model.planMove(to:mac)
        precondition(model.move == .ready(MovePlan(destination:mac,sameVolume:false)))
        // Something else's files turn up there between the question and the move.
        try fm.createDirectory(at:mac,withIntermediateDirectories:true)
        try "keep".write(to:mac.appendingPathComponent("personal.txt"),atomically:true,encoding:.utf8)
        model.startMove();settle(model)
        guard case .failed(let plan,let message)=model.move else { preconditionFailure("a move onto other files ended as \(model.move)") }
        precondition(plan.destination.path == mac.path && message.contains("can’t be used"),message)
        precondition(model.root.path == folder.path && model.sheet == .moveInstallation && model.move.staysOpen)
        precondition(UserDefaults.standard.string(forKey:InstallLocation.pendingKey) == nil && InstallLocation.isInstallation(folder))
        precondition((try? String(contentsOf:mac.appendingPathComponent("personal.txt"),encoding:.utf8)) == "keep")
        precondition(!model.closeSheetFromOutside(),"a failed move closed without an answer")
        // A menu command (Settings, About, Uninstall…) can't put another sheet in its place.
        model.sheet = .settings
        precondition(model.sheet == .moveInstallation,"another sheet replaced a failed move's")
        try fm.removeItem(at:mac)
        model.startMove();settle(model)
        guard case .done(let back)=model.move else { preconditionFailure("Try Again ended as \(model.move)") }
        precondition(back.copied && back.trashed)
        arrived(mac,"back to this Mac")
        model.closeMove()
        model.planMove(to:drive)
        try fm.createDirectory(at:drive,withIntermediateDirectories:true)
        try "keep".write(to:drive.appendingPathComponent("personal.txt"),atomically:true,encoding:.utf8)
        model.startMove();settle(model)
        guard case .failed=model.move else { preconditionFailure("expected a failed move, got \(model.move)") }
        // Cancel gives the move up: a part copy the worker made goes with it.
        let part=InstallLocation.partCopy(for:drive)
        try fm.createDirectory(at:part.appendingPathComponent("cache"),withIntermediateDirectories:true)
        try "ow2-move-v1\n".write(to:part.appendingPathComponent(".overwatch-2-mac-move"),atomically:true,encoding:.utf8)
        model.abandonMove();settle(model)
        precondition(model.move == .idle && model.sheet == .settings && model.root.path == mac.path)
        precondition(!fm.fileExists(atPath:part.path),"the part copy stayed after Cancel")
        try fm.removeItem(at:drive)
        // With its drive unplugged, the part copy is remembered and goes when the drive is back.
        let away=URL(fileURLWithPath:"/Volumes/Unplugged REC82 \(getpid())/Overwatch2Mac")
        model.move = .failed(MovePlan(destination:away,sameVolume:false),"unplugged")
        model.abandonMove();settle(model)
        precondition(UserDefaults.standard.string(forKey:InstallLocation.discardKey) == away.path,"an unreachable part copy was forgotten")
        UserDefaults.standard.set(drive.path,forKey:InstallLocation.discardKey)
        try fm.createDirectory(at:part,withIntermediateDirectories:true)
        try "ow2-move-v1\n".write(to:part.appendingPathComponent(".overwatch-2-mac-move"),atomically:true,encoding:.utf8)
        model.recheck();settle(model)
        precondition(!fm.fileExists(atPath:part.path) && UserDefaults.standard.string(forKey:InstallLocation.discardKey) == nil,"a remembered part copy stayed")

        // 5. A move the app didn't see finish (it quit as the copy took its final name): the next
        // launch finds the installation at the new place. The folder it came from, still whole
        // because it never reached the Trash, stays one choice away.
        func worker(_ args:[String]) {
            let p=Process();p.executableURL=model.service.helper;p.arguments=args
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
            try! p.run();p.waitUntilExit();precondition(p.terminationStatus == 0,"worker \(args.first!) failed")
        }
        UserDefaults.standard.set(drive.path,forKey:InstallLocation.pendingKey)
        worker(["move","--root",mac.path,"--to",drive.path])
        model=AppModel();model.recheck();settle(model)
        precondition(model.root.path == drive.path && model.otherRoot == nil,"a finished move wasn't found: \(model.root.path)")
        arrived(drive,"found at launch")
        // A move that never finished: the pending place holds no installation, and nothing changes.
        UserDefaults.standard.set(mac.path,forKey:InstallLocation.pendingKey)
        try fm.createDirectory(at:InstallLocation.partCopy(for:mac),withIntermediateDirectories:true)
        model=AppModel();model.recheck();settle(model)
        precondition(model.root.path == drive.path && UserDefaults.standard.string(forKey:InstallLocation.pendingKey) == nil,"an unfinished move was followed")
        try fm.removeItem(at:InstallLocation.partCopy(for:mac))
        // Both whole (the original hadn't reached the Trash): the new place is used, the other offered.
        try fm.copyItem(at:drive,to:mac)
        UserDefaults.standard.removeObject(forKey:InstallLocation.savedKey)
        UserDefaults.standard.set(drive.path,forKey:InstallLocation.pendingKey)
        model=AppModel();model.recheck();settle(model)
        precondition(model.root.path == drive.path && model.otherInstallation?.path == mac.path,"the copy left behind isn't offered")
        precondition(UserDefaults.standard.string(forKey:InstallLocation.savedKey) == drive.path && UserDefaults.standard.string(forKey:InstallLocation.pendingKey) == nil)
        // The new place's drive is unplugged at that launch, and the folder in use is gone (the
        // original reached the Trash): the app asks for the drive, never for a new setup, and
        // follows the move once the drive is back.
        try fm.removeItem(at:mac)
        hdiutil(["detach","-force","/Volumes/"+volume])
        UserDefaults.standard.removeObject(forKey:InstallLocation.savedKey);UserDefaults.standard.removeObject(forKey:InstallLocation.otherKey)
        UserDefaults.standard.set(drive.path,forKey:InstallLocation.pendingKey)
        model=AppModel();model.recheck();settle(model)
        precondition(model.screen == .driveMissing && model.root.path == drive.path,"expected Connect the drive, got \(model.screen) at \(model.root.path)")
        precondition(UserDefaults.standard.string(forKey:InstallLocation.pendingKey) == drive.path && !fm.fileExists(atPath:mac.path),"the pending move was forgotten, or a new setup begun")
        hdiutil(["attach","-nobrowse",image.path])
        model.recheck();settle(model)
        arrived(drive,"found once its drive was connected")
        // With an installation still in use here, an unplugged pending drive changes nothing yet.
        try fm.copyItem(at:drive,to:mac)
        hdiutil(["detach","-force","/Volumes/"+volume])
        UserDefaults.standard.removeObject(forKey:InstallLocation.savedKey)
        UserDefaults.standard.set(drive.path,forKey:InstallLocation.pendingKey)
        model=AppModel();model.recheck();settle(model)
        precondition(model.root.path == mac.path && model.screen != .driveMissing && UserDefaults.standard.string(forKey:InstallLocation.pendingKey) == drive.path,"\(model.screen) at \(model.root.path)")
        hdiutil(["attach","-nobrowse",image.path])

        // The copy's progress: one bar over both halves, and time left once there is enough to judge by.
        var progress=MoveProgress();let start=Date()
        progress.update(["phase":"copying","bytes":0,"total":1000],now:start)
        precondition(progress.fraction == 0 && progress.secondsLeft(now:start) == nil)
        progress.update(["phase":"copying","bytes":250,"total":1000],now:start.addingTimeInterval(10))
        precondition(progress.fraction == 0.125 && progress.secondsLeft(now:start.addingTimeInterval(10)) == 30,"\(progress)")
        progress.update(["phase":"checking","bytes":0,"total":1000],now:start.addingTimeInterval(40))
        precondition(progress.checking && progress.fraction == 0.5 && progress.secondsLeft(now:start.addingTimeInterval(41)) == nil)
        progress.update(["phase":"checking","bytes":1000,"total":1000],now:start.addingTimeInterval(60))
        precondition(progress.fraction == 1 && progress.secondsLeft(now:start.addingTimeInterval(60)) == nil)
        print("PASS: Move takes an installation to another drive (copied, checked, the earlier copy to the Trash) or folder (renamed) and the app follows; unusable folders say why; a failed move changes nothing and can be tried again or given up; a move finished unseen is found at the next launch")
    }
}
