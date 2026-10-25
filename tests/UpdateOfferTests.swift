import AppKit

// REC-48: the update sheet opens by itself during setup and on error screens, once a launch,
// when nothing is running (AppModel.offerUpdate). The automatic check reads a local feed: a
// private-preview release takes --update-feed. Build with every app source but Main.swift:
//   mkdir -p runtime/phase-3/update-offer-tests
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library $(ls app/Sources/*.swift | grep -v Main.swift) \
//     tests/UpdateOfferTests.swift -o runtime/phase-3/update-offer-tests/update-offer-tests
//   runtime/phase-3/update-offer-tests/update-offer-tests
// Main.swift's AppDelegate, for the one menu action the app's views name.
final class AppDelegate: NSObject { @objc func forceQuit() {} }
@main struct UpdateOfferTests {
    static let feed=FileManager.default.temporaryDirectory.appendingPathComponent("update-offer-\(getpid()).json")
    @MainActor static func main() throws {
        // A copy of this test started with --update-feed runs the checks against it.
        guard CommandLine.arguments.contains("--update-feed") else {
            let release:[String:Any]=["tag_name":"v9.9.0","html_url":"https://github.com/AsherJN/recall/releases/tag/v9.9.0",
                                      "body":"## What's new\n- Something new\n<!-- minimum-macos: 26.5 -->",
                                      "assets":[["name":Brand.diskImage("9.9.0"),"size":1000,
                                                 "browser_download_url":"https://github.com/AsherJN/recall/releases/download/v9.9.0/\(Brand.diskImage("9.9.0"))",
                                                 "digest":"sha256:"+String(repeating:"a",count:64)]]]
            try JSONSerialization.data(withJSONObject:release).write(to:feed)
            defer { try? FileManager.default.removeItem(at:feed) }
            let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=["--update-feed",feed.absoluteString]
            try p.run();p.waitUntilExit();exit(p.terminationStatus)
        }
        func model(_ screen:AppModel.Screen)->AppModel {
            let model=AppModel()
            model.release=Release(appVersion:"0",runtimeVersion:"",runtimeArchive:"",runtimeSHA256:"",installerURL:"",installerSHA256:"",
                                  chinaInstallerURL:"",chinaInstallerSHA256:"",distribution:"private-preview")
            model.screen=screen
            return model
        }
        func checked(_ model:AppModel,manual:Bool=false,present:Bool=true) {
            model.checkForUpdates(manual:manual,present:present)
            let end=Date().addingTimeInterval(10)
            while Date()<end {
                RunLoop.main.run(until:Date().addingTimeInterval(0.05))
                if case .available=model.update { RunLoop.main.run(until:Date().addingTimeInterval(0.1));return }
            }
            preconditionFailure("the local feed's update wasn't found: \(model.update)")
        }
        // Setup and error screens: the check's answer opens the sheet.
        for screen in [AppModel.Screen.welcome,.battleNet,.readyToInstall,.driveMissing,.failure] {
            let m=model(screen);checked(m)
            precondition(m.sheet == .update,"no update sheet on \(screen)")
        }
        // Once a launch: closed with Later, it doesn't come back when setup next stops.
        let once=model(.failure);checked(once);once.sheet=nil
        once.busy=true;once.busy=false
        precondition(once.sheet == nil,"the update sheet opened twice")
        // While setup runs, it waits; it opens when setup stops on a screen that offers it.
        let running=model(.readyToInstall);running.busy=true;checked(running)
        precondition(running.sheet == nil,"the update sheet opened while setup was running")
        running.screen = .failure;running.busy=false
        precondition(running.sheet == .update,"no update sheet after setup stopped")
        // Battle.net open, Overwatch running, the Play screen (route asks before Battle.net opens)
        // and the Move to Applications screen keep to the small button.
        for screen in [AppModel.Screen.ready,.running,.installer,.launching,.preparing,.moveApp] {
            let m=model(screen);checked(m);m.busy=true;m.busy=false
            precondition(m.sheet == nil,"update sheet on \(screen)")
        }
        // Another sheet open: it isn't replaced.
        let help=model(.welcome);help.sheet = .help;checked(help)
        precondition(help.sheet == .help,"the update sheet replaced Help")
        // A manual check that showed it counts as offered.
        let manual=model(.failure);checked(manual,manual:true)
        precondition(manual.sheet == .update);manual.sheet=nil;manual.busy=true;manual.busy=false
        precondition(manual.sheet == nil,"the update sheet opened again after a manual check")
        print("PASS: the update sheet opens on setup and error screens once a launch, waits for setup to stop, and leaves Play, running and other sheets alone")
    }
}
