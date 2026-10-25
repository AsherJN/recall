import AppKit

// REC-44: after Set Up on This Mac Instead, the installation on the other drive stays one choice
// away, and going back to it asks before this Mac's setup moves to the Trash. Runs the real worker
// against a disk image and a throwaway home folder (CFFIXED_USER_HOME), so "this Mac" is never the
// real ~/Library/Application Support/Overwatch2Mac. Build with every app source but Main.swift,
// with the worker beside it where the app looks for it:
//   mkdir -p runtime/phase-3/other-installation-tests/Contents/Helpers
//   python3 scripts/build_portable_setup.py --output runtime/phase-3/other-installation-tests/Contents/Helpers/ow2-setup
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library $(ls app/Sources/*.swift | grep -v Main.swift) \
//     tests/OtherInstallationTests.swift -o runtime/phase-3/other-installation-tests/other-installation-tests
//   runtime/phase-3/other-installation-tests/other-installation-tests
// Main.swift's AppDelegate, for the one menu action the app's views name.
final class AppDelegate: NSObject { @objc func forceQuit() {} }
@main struct OtherInstallationTests {
    static func hdiutil(_ args:[String]) {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/hdiutil");p.arguments=args
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try! p.run();p.waitUntilExit();precondition(p.terminationStatus == 0,"hdiutil \(args.first!) failed")
    }
    @MainActor static func settle(_ model:AppModel) {
        let end=Date().addingTimeInterval(30)
        repeat { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) } while model.busy && Date()<end
        precondition(!model.busy,"a step didn't finish")
    }
    @MainActor static func main() throws {
        let fm=FileManager.default
        // The first run makes a throwaway home on a disk image of its own, so what this Mac's
        // setup moves to the Trash lands in that image's trash, and runs a copy of itself in it.
        guard let home=ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            let base=fm.temporaryDirectory.appendingPathComponent("other-installation-\(getpid())")
            try fm.createDirectory(at:base,withIntermediateDirectories:true)
            let homeVolume="OW2 REC44 Home \(getpid())",homeImage=base.appendingPathComponent("home.sparseimage")
            hdiutil(["create","-size","64m","-fs","APFS","-type","SPARSE","-volname",homeVolume,homeImage.path])
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
        let volume="OW2 REC44 \(getpid())",image=fm.temporaryDirectory.appendingPathComponent("other-installation-drive-\(getpid()).sparseimage")
        hdiutil(["create","-size","64m","-fs","APFS","-type","SPARSE","-volname",volume,image.path])
        func attach() { hdiutil(["attach","-nobrowse",image.path]) }
        func detach() { hdiutil(["detach","-force","/Volumes/"+volume]) }
        attach()
        defer { if fm.fileExists(atPath:"/Volumes/"+volume) { detach() };try? fm.removeItem(at:image) }
        // An installation on the drive, as setup leaves it part way.
        let drive=URL(fileURLWithPath:"/Volumes/\(volume)/Overwatch2Mac")
        try fm.createDirectory(at:drive,withIntermediateDirectories:true)
        try "ow2-native-setup-v1\n".write(to:drive.appendingPathComponent(".overwatch-2-mac-owner"),atomically:true,encoding:.utf8)
        try #"{"active_runtime":"phase2-test","battlenet_region":"global","onboarding_complete":true}"#.write(to:drive.appendingPathComponent("state.json"),atomically:true,encoding:.utf8)
        UserDefaults.standard.set(drive.path,forKey:InstallLocation.savedKey)
        UserDefaults.standard.removeObject(forKey:InstallLocation.otherKey)
        // Setup on this Mac got as far as installing something (and a file worth measuring).
        func setUpHere(_ model:AppModel) throws {
            try #"{"active_runtime":"phase2-test","battlenet_region":"global"}"#.write(to:mac.appendingPathComponent("state.json"),atomically:true,encoding:.utf8)
            try fm.createDirectory(at:mac.appendingPathComponent("downloads"),withIntermediateDirectories:true)
            try Data(count:2<<20).write(to:mac.appendingPathComponent("downloads/part.bin"))
            model.recheck();settle(model)
            precondition(!model.canChangeLocation,"this Mac's setup wasn't seen")
        }
        // The drive is unplugged when Recall opens; the player presses Set Up on This Mac Instead.
        func misclick() -> AppModel {
            detach()
            let model=AppModel()
            precondition(model.root.path == drive.path)
            model.recheck();settle(model)
            precondition(model.screen == .driveMissing,"expected Connect the drive, got \(model.screen)")
            model.useThisMac();settle(model)
            precondition(model.root.path == mac.path && model.screen == .welcome,"expected this Mac's welcome, got \(model.screen)")
            precondition(model.otherInstallation?.path == drive.path && model.offersOtherInstallation,"the unplugged drive isn't offered")
            precondition(UserDefaults.standard.string(forKey:InstallLocation.savedKey) == nil)
            attach()
            return model
        }

        // 1. Straight back, before anything is installed here: no question, the empty folder goes.
        var model=misclick()
        precondition(model.canChangeLocation)
        model.chooseOtherInstallation();settle(model)
        precondition(model.sheet == nil && model.root.path == drive.path,"didn't go back to the drive")
        precondition(model.screen == .readyToInstall,"the drive's setup didn't pick up: \(model.screen)")
        precondition(model.otherRoot == nil && model.otherInstallation == nil && !fm.fileExists(atPath:mac.path),"this Mac's empty folder stayed")
        precondition(UserDefaults.standard.string(forKey:InstallLocation.savedKey) == drive.path)

        // 2. Setup started here, then back to the drive, keeping this Mac's setup: it's offered back.
        model=misclick();try setUpHere(model)
        model.chooseOtherInstallation()
        precondition(model.sheet == .otherInstallation,"no question before leaving this Mac's setup")
        precondition(InstallLocation.size(mac)>=2<<20)
        model.useOtherInstallation(removing:false);settle(model)
        precondition(model.root.path == drive.path && model.screen == .readyToInstall)
        precondition(fm.fileExists(atPath:mac.appendingPathComponent("state.json").path),"kept setup was removed")
        precondition(model.otherInstallation?.path == mac.path && model.offersOtherInstallation,"kept setup isn't offered back")
        // ...and from the drive, back to this Mac the same way (its setup is there, so it asks).
        model.chooseOtherInstallation()
        precondition(model.sheet == .otherInstallation)
        model.useOtherInstallation(removing:false);settle(model)
        precondition(model.root.path == mac.path && model.otherInstallation?.path == drive.path)

        // 3. Back to the drive, moving this Mac's setup to the Trash.
        model.chooseOtherInstallation();precondition(model.sheet == .otherInstallation)
        let marker="rec44-test-\(getpid())"
        try Data().write(to:mac.appendingPathComponent(marker))
        model.useOtherInstallation(removing:true);settle(model)
        precondition(model.root.path == drive.path && model.screen == .readyToInstall)
        precondition(!fm.fileExists(atPath:mac.path),"this Mac's setup wasn't moved to the Trash")
        precondition(model.otherRoot == nil && model.otherInstallation == nil,"a removed setup is still offered")
        // In the home image's trash, never the real one.
        let trashes=URL(fileURLWithPath:home).deletingLastPathComponent().appendingPathComponent(".Trashes/\(getuid())")
        precondition(((try? fm.contentsOfDirectory(atPath:trashes.path)) ?? []).contains { fm.fileExists(atPath:trashes.appendingPathComponent($0).appendingPathComponent(marker).path) },
                     "this Mac's setup isn't in the home image's trash")

        // 4. A drive whose installation was deleted meanwhile isn't offered.
        model=misclick()
        try fm.removeItem(at:drive.appendingPathComponent("state.json"))
        precondition(model.otherInstallation == nil && !model.offersOtherInstallation,"a deleted installation is still offered")

        // Measuring never follows Wine's drive letters (a link to /).
        let folder=URL(fileURLWithPath:home).appendingPathComponent("measure")
        try fm.createDirectory(at:folder.appendingPathComponent("dosdevices"),withIntermediateDirectories:true)
        try Data(count:1<<20).write(to:folder.appendingPathComponent("file.bin"))
        try fm.createSymbolicLink(atPath:folder.appendingPathComponent("dosdevices/z:").path,withDestinationPath:"/")
        let measured=InstallLocation.size(folder)
        precondition(measured>=1<<20 && measured<4<<20,"measured \(measured) bytes")
        print("PASS: Set Up on This Mac Instead can be undone: straight back before setup, or after it with this Mac's setup kept (offered back) or moved to the Trash; deleted installations aren't offered; measuring skips links")
    }
}
