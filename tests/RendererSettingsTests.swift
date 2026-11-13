import AppKit

// Custom renderer settings (RendererSettings, REC-85): the check of each line the player types, the
// lines a launch passes on, the settings Show Recall's settings lists, Save Logs' summary line, and
// the support report's display sync (REC-93).
// Build with every app source but Main.swift, and run:
//   mkdir -p runtime/phase-3/renderer-tests
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library $(ls app/Sources/*.swift | grep -v Main.swift) \
//     tests/RendererSettingsTests.swift -o runtime/phase-3/renderer-tests/renderer-settings-tests
//   runtime/phase-3/renderer-tests/renderer-settings-tests
// Main.swift's AppDelegate, for the one menu action the app's views name.
final class AppDelegate: NSObject { @objc func forceQuit() {} }
@main struct RendererSettingsTests {
    static func problem(_ line:String)->RendererSettings.Problem? {
        let checked=RendererSettings.check(line)
        precondition(checked.count == 1,"\(line): \(checked)")
        return checked[0].problem
    }
    @MainActor static func main() throws {
        // The engine's names, exactly: a value its parser reads passes.
        for line in ["d3d11.preferredMaxFrameRate = 45","dxgi.maxFrameLatency=2","dxgi.presentPacing = false",
                     "d3d11.releaseShaderIR = True","d3d11.metalSpatialUpscaleFactor = 0.75","dxgi.customDeviceDesc = \"Apple M1 Pro\"",
                     "d3d11.preferredMaxFrameRate = 45 # comment after the value"] {
            precondition(problem(line) == nil,"\(line): \(String(describing:problem(line)))")
        }
        // A letter in the wrong case is the same setting to a player and none to the engine.
        precondition(problem("dxgi.maxframelatency = 2") == .unknown("dxgi.maxframelatency",suggestion:"dxgi.maxFrameLatency"))
        // The right setting under the wrong prefix; a letter or two off.
        precondition(problem("dxgi.preferredMaxFrameRate = 60") == .unknown("dxgi.preferredMaxFrameRate",suggestion:"d3d11.preferredMaxFrameRate"))
        precondition(problem("dxgi.maxFrameLatancy = 2") == .unknown("dxgi.maxFrameLatancy",suggestion:"dxgi.maxFrameLatency"))
        // A frame rate cap by any other name points to the one Overwatch's renderer reads (the
        // ticket's own example, dxgi.maxFrameRate, isn't a setting either).
        for name in ["dxgi.maxFrameRate","maxfps","d3d11.fpsLimit"] {
            precondition(problem("\(name) = 60") == .unknown(name,suggestion:"d3d11.preferredMaxFrameRate"),name)
        }
        precondition(problem("dxgi.somethingElse = 1") == .unknown("dxgi.somethingElse",suggestion:nil))
        // Values the engine's parsers can't read.
        precondition(problem("d3d11.preferredMaxFrameRate = sixty") == .value("d3d11.preferredMaxFrameRate",.int))
        precondition(problem("d3d11.preferredMaxFrameRate = 60.5") == .value("d3d11.preferredMaxFrameRate",.int))
        precondition(problem("dxgi.presentPacing = yes") == .value("dxgi.presentPacing",.bool))
        precondition(problem("d3d11.metalSpatialUpscaleFactor = .5") == .value("d3d11.metalSpatialUpscaleFactor",.float))
        precondition(problem("dxgi.customDeviceDesc =") == .value("dxgi.customDeviceDesc",.text))
        // What the worker leaves out.
        precondition(problem("dxgi.fullscreenCanvasWidth = 800") == .recalls("dxgi.fullscreenCanvasWidth"))
        precondition(problem("d3d11.metalfxSharpness = 1") == .recalls("d3d11.metalfxSharpness"))
        precondition(problem("[Overwatch.exe]") == .section)
        precondition(problem("frame rate 60") == .unreadable)
        precondition(problem("max-fps = 60") == .unreadable)

        // Numbered as the player sees them; blank lines and comments say nothing.
        let text="# my settings\n\nd3d11.preferredMaxFrameRate = 45\r\n  dxgi.maxframerate = 60\ndxgi.fullscreenCanvasHeight = 1\n[x]\nnot a setting"
        let checked=RendererSettings.check(text)
        precondition(checked.map(\.number) == [3,4,5,6,7],"\(checked)")
        precondition(checked.compactMap(RendererSettings.message).count == 4)
        precondition(RendererSettings.message(checked[1]) == "Line 4: dxgi.maxframerate isn’t a setting. Did you mean d3d11.preferredMaxFrameRate?",
                     RendererSettings.message(checked[1]) ?? "")
        precondition(RendererSettings.message(checked[2]) == "Line 5: dxgi.fullscreenCanvasHeight follows your resolution in Settings › Display, so this line isn’t used.")
        // A launch passes on every name = value line but Recall's own, as the worker keeps them;
        // an unknown name too (the engine ignores it).
        precondition(RendererSettings.used(text) == ["d3d11.preferredMaxFrameRate = 45","dxgi.maxframerate = 60"],"\(RendererSettings.used(text))")
        precondition(RendererSettings.used("") == [] && RendererSettings.check("").isEmpty)

        // Show Recall's settings: the last launch's dxmt.conf without the player's lines, one line
        // per setting (the last word, as DXMT reads it), no comments; before a launch, the engine's.
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("renderer-settings-\(getpid())")
        defer { try? fm.removeItem(at:root) }
        let engine=root.appendingPathComponent("runtimes/v1/config")
        try fm.createDirectory(at:engine,withIntermediateDirectories:true)
        try "# engine\n[Overwatch.exe]\nd3d11.releaseShaderIR = True\ndxgi.fullscreenCanvasWidth = 1920\n".write(to:engine.appendingPathComponent("dxmt.conf"),atomically:true,encoding:.utf8)
        precondition(RendererSettings.recallsLines(root:root,runtime:"v1") == ["d3d11.releaseShaderIR = True","dxgi.fullscreenCanvasWidth = 1920"])
        precondition(RendererSettings.recallsLines(root:root,runtime:nil) == [])
        let launched="# engine\n[Overwatch.exe]\nd3d11.releaseShaderIR = True\ndxgi.fullscreenCanvasWidth = 2560\n[Overwatch.exe]\nd3d11.metalfxSharpness = 0.4\n"
            + "# Custom renderer settings (Settings › Advanced)\n[Overwatch.exe]\nd3d11.preferredMaxFrameRate = 45\n"
        try launched.write(to:root.appendingPathComponent("dxmt.conf"),atomically:true,encoding:.utf8)
        let shown=RendererSettings.recallsLines(root:root,runtime:"v1")
        precondition(shown == ["d3d11.releaseShaderIR = True","dxgi.fullscreenCanvasWidth = 2560","d3d11.metalfxSharpness = 0.4"],"\(shown)")

        // Display sync for the support report (REC-93): the last value the last launch's dxmt.conf
        // gives, as DXMT reads it; off without a line; not_launched before a launch wrote the file.
        let neoRoot=fm.temporaryDirectory.appendingPathComponent("display-sync-\(getpid())")
        defer { try? fm.removeItem(at:neoRoot) }
        try fm.createDirectory(at:neoRoot,withIntermediateDirectories:true)
        let neoFile=neoRoot.appendingPathComponent("dxmt.conf")
        precondition(RendererSettings.displaySync(root:neoRoot) == "not_launched")
        precondition(RendererSettings.displaySync(root:root) == "off")
        let neo="# engine\n[Overwatch.exe]\nd3d11.releaseShaderIR = True\n[Overwatch.exe]\ndxgi.displaySyncEnabled = True\n"
        try neo.write(to:neoFile,atomically:true,encoding:.utf8)
        precondition(RendererSettings.displaySync(root:neoRoot) == "on")
        // Recall's line is one of Recall's settings shown on a MacBook Neo.
        precondition(RendererSettings.recallsLines(root:neoRoot,runtime:nil) == ["d3d11.releaseShaderIR = True","dxgi.displaySyncEnabled = True"])
        // A player's own line comes later and wins; it isn't one of Recall's.
        let marker="# Custom renderer settings (Settings › Advanced)\n[Overwatch.exe]\n"
        try (neo+marker+"dxgi.displaySyncEnabled = false\n").write(to:neoFile,atomically:true,encoding:.utf8)
        precondition(RendererSettings.displaySync(root:neoRoot) == "off")
        precondition(RendererSettings.recallsLines(root:neoRoot,runtime:nil).last == "dxgi.displaySyncEnabled = True")
        // A value DXMT can't read and a comment change nothing.
        try (neo+marker+"dxgi.displaySyncEnabled = maybe\n# dxgi.displaySyncEnabled = False\n").write(to:neoFile,atomically:true,encoding:.utf8)
        precondition(RendererSettings.displaySync(root:neoRoot) == "on")

        // Save Logs' summary names the lines when the setting is on, and nothing when it's off.
        var input=LogBundle.Input(root:root,report:"{}",appVersion:"1.6.4",runtime:"v1",logging:LoggingSetting(rawValue:""),custom:"",since:nil)
        precondition(!Summary.text(input,moments:[],removed:[:],olderLeftOut:0,overLimit:false).contains("Custom renderer"))
        input.renderer=["d3d11.preferredMaxFrameRate = 45"]
        let summary=Summary.text(input,moments:[],removed:[:],olderLeftOut:0,overLimit:false)
        precondition(summary.contains("Custom renderer settings: on\n  d3d11.preferredMaxFrameRate = 45\n"),summary)
        print("PASS: each line's check (names, values, Recall's own, sections), the lines a launch passes on, Recall's settings shown, Save Logs' summary, display sync")
    }
}
