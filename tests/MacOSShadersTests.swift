import AppKit

// After a macOS update (REC-77): when Recall offers to optimize the shaders for this macOS
// (MacOSShaders in app/Sources/GraphicsDetails.swift), from the records the pipeline helper keeps
// (scripts/portable_pipeline.swift). Build with every app source but Main.swift, and run:
//   mkdir -p runtime/phase-3/macos-shaders-tests
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library $(ls app/Sources/*.swift | grep -v Main.swift) \
//     tests/MacOSShadersTests.swift -o runtime/phase-3/macos-shaders-tests/run
//   runtime/phase-3/macos-shaders-tests/run
// Main.swift's AppDelegate, for the one menu action the app's views name.
final class AppDelegate: NSObject { @objc func forceQuit() {} }
@main struct MacOSShadersTests {
    static func main() throws {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("macos-shaders-\(getpid())")
        defer { try? fm.removeItem(at:root) }
        let cache=root.appendingPathComponent("cache")
        try fm.createDirectory(at:cache.appendingPathComponent("pipelines"),withIntermediateDirectories:true)
        let now="Version 26.7 (Build 25H12)",earlier="Version 26.6.2 (Build 25G83)"
        func record(_ name:String,_ macOS:String?) throws {
            let file=cache.appendingPathComponent(name)
            if let macOS { try JSONSerialization.data(withJSONObject:["macos":macOS,"gpu":"Apple M1 Pro"]).write(to:file) }
            else { try? fm.removeItem(at:file) }
        }
        func needed(_ learned:Int?=19611)->Bool { MacOSShaders.needed(root:root,learned:learned,current:now) }

        // A new installation: no record of any preparation, nothing to optimize.
        precondition(!needed())
        // Since 1.4 the warm-up's record names the macOS the game's shader cache was filled on.
        try record("warmed.json",now);precondition(!needed())
        try record("warmed.json",earlier);precondition(needed())
        // Nothing learned yet (or Clear Shader Cache): nothing to optimize, whatever the records say.
        precondition(!needed(nil) && !needed(0))
        // From 1.6.3 the helper records the macOS the shaders were last all prepared on; it decides.
        try record("optimized.json",now);precondition(!needed())
        try record("optimized.json",earlier);try record("warmed.json",now);precondition(needed())
        precondition(MacOSShaders.preparedOn(root:root) == earlier)
        // A folder still holding shaders the earlier macOS built (Play Now): optimize, whatever the record says.
        try record("optimized.json",now)
        let folder=cache.appendingPathComponent("pipelines/"+String(repeating:"ab",count:32))
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("{}".utf8).write(to:folder.appendingPathComponent("earlier-macos.json"))
        precondition(needed())
        // Only a cache folder counts (a 64-character name), not load.json or anything else there.
        try fm.removeItem(at:folder)
        try fm.createDirectory(at:cache.appendingPathComponent("pipelines/other"),withIntermediateDirectories:true)
        try Data("{}".utf8).write(to:cache.appendingPathComponent("pipelines/other/earlier-macos.json"))
        precondition(!needed())
        // The prompt's time: whole 5 minutes, at least 5.
        let rate=MacOSShaders.perMinute
        precondition(MacOSShaders.minutes(0) == 5 && MacOSShaders.minutes(Int(rate*5)) == 5)
        precondition(MacOSShaders.minutes(Int(rate*5)+1) == 10 && MacOSShaders.minutes(Int(rate*21)) == 25)
        print("PASS: macOS shader optimization offered from the helper's records")
    }
}
