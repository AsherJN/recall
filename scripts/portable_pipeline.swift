// Native counterpart of prepare_dxmt_pipelines.py. No player-side compiler/Python.
import Foundation
import CryptoKit
import Darwin
import Metal

let fm = FileManager.default
// A launch keeps what was learned and warms the game app's cache, but prepares no
// archive: that takes minutes, so the session's monitor runs it after the game closes
// (--after-session), and a launch stops one still running (portable_setup.m).
let afterSession = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--after-session"
let arguments = afterSession ? [CommandLine.arguments[0]] + CommandLine.arguments.dropFirst(2) : CommandLine.arguments
let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let cache = root.appendingPathComponent("cache/pipelines")
// What the last preparation after a session added, for the next launch to report.
let report = root.appendingPathComponent("cache/prepared.json")
let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("pipeline-prepare")
// The program Overwatch runs as, when the launch names it: the engine's Game Mode app, or Wine's own
// loader with Game Mode off (REC-51). Each keeps its own compiled-shader cache.
let gameApp = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]).standardizedFileURL : nil
// Its identifier, which names that cache: an app's Info.plist, or the one the loader carries in its
// own file (CrossOver's, com.codeweavers.CrossOver.wineloader).
func gameIdentifier(_ program: URL) -> String? {
    let info = program.pathExtension == "app" ? NSDictionary(contentsOf: program.appendingPathComponent("Contents/Info.plist"))
                                              : CFBundleCopyInfoDictionaryForURL(program as CFURL) as NSDictionary?
    return info?["CFBundleIdentifier"] as? String
}
let started = Date()
var child: Process?
var interrupted: Int32 = 0
signal(SIGTERM) { _ in interrupted = 1 }
signal(SIGINT) { _ in interrupted = 1 }
struct PreparationError: Error { let message: String }
func require(_ ok: Bool, _ message: String) throws { if !ok { throw PreparationError(message: message) } }
func json(_ url: URL, limit: Int = 2*1024*1024) throws -> [String: Any] {
    try require((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < limit, "Metadata too large")
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
}
// The pack's catalog (archive.json) lists every prepared pipeline; the game reads up to 64 MiB.
let catalogLimit = 64*1024*1024
func save(_ value: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic) }
// Each read is released as it goes: a command-line tool's autorelease pool never
// drains on its own, and preparation hashes hundreds of MB of files per batch.
func sha(_ url: URL) throws -> String {
    let stream = try FileHandle(forReadingFrom: url); defer { try? stream.close() }
    var digest = SHA256()
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let data = try stream.read(upToCount: 131072), !data.isEmpty else { return false }
        digest.update(data: data); return true
    }) {}
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func keys(_ directory: URL) throws -> Set<String> {
    let path = directory.appendingPathComponent("archive.json")
    if !fm.fileExists(atPath: path.path) { return [] }
    let values = try json(path, limit: catalogLimit)["prepared_keys"] as? [String] ?? []
    try require(values.count <= 1048576 && values.allSatisfy { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }, "Invalid key catalog")
    return Set(values)
}
// The pack's archives, in the catalog's order: each one's hash and the pipelines it holds.
func packEntries(_ directory: URL) throws -> [(hash: String, keys: [String])] {
    let path = directory.appendingPathComponent("archive.json")
    if !fm.fileExists(atPath: path.path) { return [] }
    return (try json(path, limit: catalogLimit)["archives"] as? [[String: Any]] ?? []).compactMap { entry in
        guard let hash = entry["sha256"] as? String, hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return (hash, entry["prepared_keys"] as? [String] ?? [])
    }
}
// The pack's parts in the order the game loads them, for Settings › Graphics › Shader memory:
// each one's size and how many pipelines it holds.
let packSummary = root.appendingPathComponent("cache/pack.json")
func summarize(_ directory: URL) throws {
    let path = directory.appendingPathComponent("archive.json")
    guard fm.fileExists(atPath: path.path) else { try? fm.removeItem(at: packSummary); return }
    let parts = (try json(path, limit: catalogLimit)["archives"] as? [[String: Any]] ?? []).map { entry in
        [entry["bytes"] as? Int ?? 0, (entry["prepared_keys"] as? [Any])?.count ?? 0]
    }
    try save(["schema": 1, "parts": parts], packSummary)
}
// The game loads the pack's parts in order, as much as the Shader memory setting allows, so
// they're kept with the slowest pipelines first: by recorded build time per byte.
func orderSlowestFirst(_ directory: URL, _ costs: [String: Double]) throws {
    let path = directory.appendingPathComponent("archive.json")
    var manifest = try json(path, limit: catalogLimit)
    guard let archives = manifest["archives"] as? [[String: Any]] else { return }
    var density: [Double] = []
    for entry in archives {
        let bytes = Double(max(entry["bytes"] as? Int ?? 1, 1))
        let cost: Double = (entry["prepared_keys"] as? [String] ?? []).reduce(0.0) { $0 + (costs[$1] ?? 0) }
        density.append(cost / bytes)
    }
    let order: [Int] = archives.indices.sorted { (a: Int, b: Int) -> Bool in
        density[a] == density[b] ? a < b : density[a] > density[b]
    }
    manifest["archives"] = order.map { archives[$0] }
    try save(manifest, path)
}
// tick runs while the child does (false) and once after it exits (true).
func run(_ executable: URL, _ args: [String], _ env: [String: String]?, _ output: URL, _ seconds: Double, tick: ((Process, Bool) -> Void)? = nil) throws -> Int32 {
    let p = Process(); p.executableURL = executable; p.arguments = args; p.environment = env
    fm.createFile(atPath: output.path, contents: nil)
    let log = try FileHandle(forWritingTo: output); defer { try? log.close() }
    p.standardOutput = log; p.standardError = FileHandle.nullDevice
    try p.run(); child = p; defer { child = nil }
    let end = Date().addingTimeInterval(seconds)
    while p.isRunning && Date() < end && interrupted == 0 { Thread.sleep(forTimeInterval: 0.05); tick?(p, false) }
    if p.isRunning {
        p.terminate(); let grace = Date().addingTimeInterval(2)
        while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit(); throw PreparationError(message: "Preparation cancelled or timed out")
    }
    p.waitUntilExit(); tick?(p, true); return p.terminationStatus
}
// Progress for the launcher's "Preparing graphics" details, one JSON line per step
// among the log lines; the worker passes these on as graphics events.
func progress(_ phase: String, _ values: [String: Any] = [:]) {
    var value = values; value["graphics"] = phase
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    print(String(decoding: data, as: UTF8.self)); fflush(stdout)
}
// Follows the preparation tool's diagnostic log (DXMT_PIPELINE_CACHE_LOG), which
// records each pipeline as the tool restores or compiles it, and sends them in
// batches: a short key, the milliseconds it took, and whether it is new.
final class PipelineFeed {
    let log: URL, previous: Set<String>
    var offset: UInt64 = 0, pending: [UInt8] = [], batch: [[Any]] = [], sent = Date(), counted = Date.distantPast
    // New pipelines built so far, passed on at most once a second (the main window's progress).
    var built = Set<String>(), onBuilt: ((Int) -> Void)?
    init(_ log: URL, _ previous: Set<String>) { self.log = log; self.previous = previous }
    func poll(_ tool: Process, _ final: Bool) {
        if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "\(log.path)-\(tool.processIdentifier).jsonl")) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size < offset { offset = 0; pending = [] } // The tool rotated it.
            try? handle.seek(toOffset: offset)
            if let data = try? handle.readToEnd() { offset += UInt64(data.count); pending += data }
        }
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], entry["event"] as? String == "prewarm",
                  entry["success"] as? Bool == true, let key = entry["key"] as? String, validKey(key),
                  let us = (entry["duration_us"] as? NSNumber)?.doubleValue, us.isFinite, us >= 0 else { continue }
            batch.append([String(key.prefix(12)), (min(us, 600000000) / 100).rounded() / 10, !previous.contains(key)])
            if !previous.contains(key) { built.insert(key) }
        }
        if final || Date().timeIntervalSince(counted) >= 1 { counted = Date(); onBuilt?(built.count) }
        guard final || Date().timeIntervalSince(sent) >= 0.25 else { return }
        while !batch.isEmpty { progress("pipelines", ["items": Array(batch.prefix(400))]); batch.removeFirst(min(400, batch.count)) }
        sent = Date()
    }
}
func inventory(_ directory: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    guard let it = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey,.isRegularFileKey]) else { return result }
    for case let file as URL in it {
        let value = try file.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey])
        try require(value.isSymbolicLink != true, "Cache contains a symbolic link")
        if value.isRegularFile == true { result[String(file.path.dropFirst(directory.path.count + 1))] = try autoreleasepool { try sha(file) } }
    }
    return result
}
// The game keeps what it learns in a folder named after this Mac's GPU and
// macOS version, hashed with Metal's registry ID for the GPU (pipeline_cache.c).
// macOS reassigns that ID at each restart, so each restart began a new, empty
// folder. Before each session, earlier folders are folded into the one the
// game will open now, and removed.
let namespaceBuild = "ow2-source-v1"
// Since 1.4 the game keeps everything it learns and the pack holds every learned
// pipeline (dxmt-shader-pack.patch): no size limits, only a free-space floor.
// Preparation after a session goes in batches, each an archive added to the pack,
// so a session cut short keeps what it finished. A batch takes up to batchLimit
// pipelines, or about 150 seconds of their first builds, whichever is fewer.
let batchLimit = 2048, batchCost = 150_000_000.0
// Archives with fewer pipelines than this (the game's own, a batch cut short) are
// built again into the next batch, so the pack stays a few large files.
let smallArchive = 512, rebuildLimit = 4096
// The game holds what it loads of the pack in memory (measured: about 1.05 bytes per
// byte of archive). It loads the pack's parts in order, slowest first (orderSlowestFirst),
// as much as Settings › Graphics › Shader memory allows: all of it unless the player chose
// less (portable_setup.m, pipeline_cache.c). Every learned pipeline also goes into the game app's own shader cache
// after each session (warm), which costs no memory until the game uses one, for what a
// game doesn't load.
func validKey(_ key: String) -> Bool { key.count == 64 && key.allSatisfy { "0123456789abcdef".contains($0) } }
func identity(_ device: MTLDevice) -> (UInt64) -> [UInt8] {
    let prefix = Array("dxmt-render-cache-v1|\(namespaceBuild)|\(ProcessInfo.processInfo.operatingSystemVersionString)|".utf8), suffix = Array("|\(device.name)".utf8)
    return { prefix + Array(String($0).utf8) + suffix }
}
func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func learnedFolders() throws -> [URL] {
    guard fm.fileExists(atPath: cache.path) else { return [] }
    return try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isSymbolicLinkKey]).filter {
        validKey($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
            && fm.fileExists(atPath: $0.appendingPathComponent("recipes").path)
    }
}
func learnedAt(_ folder: URL) -> Date {
    (try? folder.appendingPathComponent("recipes").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
}
func fileBytes(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
func freeBytes() -> UInt64 { (try? fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? UInt64) ?? 0 }
// Earlier folders of this GPU on this macOS: the same name with another registry
// ID. macOS numbers registry entries in boot order, so the GPU's ID moves little
// between restarts. A folder from another macOS version or GPU is not found.
func sameMacFolders(_ names: [String], _ device: MTLDevice) -> Set<String> {
    var wanted: [Data: String] = [:]
    for name in names { wanted[Data(stride(from: 0, to: 64, by: 2).map { UInt8(name.dropFirst($0).prefix(2), radix: 16)! })] = name }
    var found = Set<String>(); let current = device.registryID, name = identity(device)
    for distance in UInt64(1)...(1 << 19) {
        if wanted.isEmpty { break }
        for id in [current &+ distance, current &- distance] {
            if let match = wanted.removeValue(forKey: Data(SHA256.hash(data: name(id)))) { found.insert(match) }
        }
    }
    return found
}
// Returns the folder the game opens in this restart, which need not exist yet.
func consolidate() throws -> URL {
    guard let device = MTLCreateSystemDefaultDevice() else { throw PreparationError(message: "No Metal device") }
    let current = cache.appendingPathComponent(hex(SHA256.hash(data: identity(device)(device.registryID))))
    let folders = try learnedFolders()
    var earlier = folders.filter { $0.lastPathComponent != current.lastPathComponent }.sorted { learnedAt($0) > learnedAt($1) }
    let found = earlier.count
    guard found > 0 else { return current }
    // The writer lock the game and preparation take. A folder in use is left alone.
    var locks: [Int32] = []; defer { locks.forEach { close($0) } }
    for folder in folders {
        let lock = open(folder.appendingPathComponent("write.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { if lock >= 0 { close(lock) }; print("Earlier learned pipelines are in use; kept for the next session"); return current }
        locks.append(lock)
    }
    let sameMac = sameMacFolders(earlier.map(\.lastPathComponent), device)
    var moved = "none"
    if !fm.fileExists(atPath: current.path) {
        // The most recent folder becomes this restart's. Archives hold GPU code
        // compiled for its macOS version, so they stay only from this macOS.
        let base = earlier.first { sameMac.contains($0.lastPathComponent) } ?? earlier[0]
        earlier.removeAll { $0 == base }
        if !sameMac.contains(base.lastPathComponent) {
            for name in ["archives","archive.json","refresh-decision-native.json"] where fm.fileExists(atPath: base.appendingPathComponent(name).path) { try fm.removeItem(at: base.appendingPathComponent(name)) }
            try fm.createDirectory(at: base.appendingPathComponent("archives"), withIntermediateDirectories: true)
        }
        try fm.moveItem(at: base, to: current)
        moved = sameMac.contains(base.lastPathComponent) ? "same_macos" : "other_macos"
    }
    // The rest add what this folder lacks, most expensive to build first, with
    // the shader libraries they need. Their archives are not merged: preparation
    // rebuilds them for the added pipelines.
    guard freeBytes() > 1 << 30 else { print("Earlier learned pipelines kept for the next session to preserve disk headroom"); return current }
    var added = 0
    let recipes = current.appendingPathComponent("recipes"), libraries = current.appendingPathComponent("libraries")
    for directory in [recipes, libraries] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    for donor in earlier {
        var entries: [(key: String, cost: Double, libraries: [String])] = []
        for file in try fm.contentsOfDirectory(at: donor.appendingPathComponent("recipes"), includingPropertiesForKeys: nil) {
            let key = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", validKey(key), !fm.fileExists(atPath: recipes.appendingPathComponent(file.lastPathComponent).path),
                  let data = try? json(file), let cost = data["cost_us"] as? Double, cost.isFinite, cost >= 0, let recipe = data["recipe"] as? [String: Any] else { continue }
            let needed = ["vertex","fragment"].compactMap { (recipe[$0] as? [String: Any])?["library"] as? String }
            guard recipe["vertex"] != nil, needed.allSatisfy(validKey) else { continue }
            entries.append((key, cost, needed))
        }
        for entry in entries.sorted(by: { $0.cost > $1.cost }) {
            let missing = Set(entry.libraries.map { $0 + ".air" }).filter { !fm.fileExists(atPath: libraries.appendingPathComponent($0).path) }
            let sizes = ([("recipes", entry.key + ".json")] + missing.map { ("libraries", $0) }).map { fileBytes(donor.appendingPathComponent($0.0).appendingPathComponent($0.1)) }
            guard sizes.allSatisfy({ $0 != nil }) else { continue }
            for name in missing { try fm.copyItem(at: donor.appendingPathComponent("libraries").appendingPathComponent(name), to: libraries.appendingPathComponent(name)) }
            try fm.copyItem(at: donor.appendingPathComponent("recipes").appendingPathComponent(entry.key + ".json"), to: recipes.appendingPathComponent(entry.key + ".json"))
            added += 1
        }
    }
    for donor in earlier { try fm.removeItem(at: donor) }
    print("Kept learned pipelines from \(found) earlier folders: moved \(moved), \(added) added, \(earlier.count) removed")
    progress("kept", ["folders": found, "added": added])
    return current
}
// macOS keeps compiled shaders per app. With Game Mode, Overwatch runs as the
// engine's game app, whose cache starts empty after the update that brings it and
// after each macOS update, so every learned pipeline would be compiled again
// mid-match; without, it runs as Wine's own loader, whose cache is just as cold after a
// macOS update, or when the player last played with Game Mode on. pipeline-warm compiles
// them into that program's cache before the session, costliest first, once per program,
// macOS version and GPU (cache/warmed.json); after that the game adds what it compiles itself.
// Before a session (launch), once per app, macOS version and GPU and within the launch's
// budget. After one, every time and every learned pipeline: Metal skips what the cache
// already holds, so this only adds what it lacks, whatever cleared it.
func warm(_ folder: URL, _ costs: [String: Double], after: Bool = false) throws -> Int {
    guard let app = gameApp, !costs.isEmpty,
          let identifier = gameIdentifier(app),
          identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$", options: .regularExpression) != nil, !identifier.contains("..") else { return 0 }
    let tool = helper.deletingLastPathComponent().appendingPathComponent("pipeline-warm")
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fm.isExecutableFile(atPath: tool.path), confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0,
          let device = MTLCreateSystemDefaultDevice() else { return 0 }
    let caches = String(cString: buffer)
    let target = URL(fileURLWithPath: caches).appendingPathComponent(identifier).appendingPathComponent("com.apple.metal")
    let marker = cache.deletingLastPathComponent().appendingPathComponent("warmed.json")
    let expected = ["app": identifier, "macos": ProcessInfo.processInfo.operatingSystemVersionString, "gpu": device.name]
    if !after, fm.fileExists(atPath: target.path), let saved = try? json(marker), expected.allSatisfy({ saved[$0.key] as? String == $0.value }) { return 0 }
    // The worker waits 600 s for all of a launch's preparation; about 120 KB of cache per pipeline.
    let remaining = after ? 3600 : 540 - Date().timeIntervalSince(started)
    let free = (try? fm.attributesOfFileSystem(forPath: caches)[.systemFreeSize] as? UInt64) ?? 0
    guard remaining > 30, free > 4 << 30 else { print("Shader warm-up left for the next session"); return 0 }
    let work = root.appendingPathComponent("tmp")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    let selection = costs.keys.sorted { costs[$0]! == costs[$1]! ? $0 < $1 : costs[$0]! > costs[$1]! }
    let list = work.appendingPathComponent("warm-selection.json"); try save(selection, list)
    let seconds = after ? 1800 : min(300, remaining - 20)
    let feed = PipelineFeed(work.appendingPathComponent("warm-log"), Set(costs.keys))
    defer { for file in (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("warm-log-") { try? fm.removeItem(at: file) } }
    progress("warming", ["target": selection.count])
    let output = work.appendingPathComponent("warm.json"), code: Int32
    do {
        code = try run(tool, [folder.path, target.path, list.path, feed.log.path, String(Int(seconds))],
                       ["PATH": "/usr/bin:/bin", "HOME": root.appendingPathComponent("home").path], output, seconds + 75, tick: { feed.poll($0, $1) })
    } catch { if interrupted != 0 { throw error }; print("Shader warm-up stopped; it continues next session"); return 0 }
    guard code == 0, let summary = try? json(output), summary["cache"] as? String == target.path else { print("Shader warm-up skipped this time"); return 0 }
    let warmed = summary["warmed"] as? Int ?? 0
    if summary["complete"] as? Bool == true && warmed > 0 { try save(expected, marker) }
    print("Warmed \(warmed) learned pipelines for \(identifier)")
    return warmed
}
// Metal builds each archive in a working folder in the user's cache folder
// (com.apple.gpuarchiver/gpuarchiver-*) and leaves it there, about the size of the
// archive, for good: before 1.4 each preparation left one. Those a tool run made are
// removed once it has exited; a folder whose lock another process holds is left.
let archiverCache: URL? = {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent("com.apple.gpuarchiver")
}()
func archiverFolders() -> Set<String> {
    guard let archiverCache else { return [] }
    return Set(((try? fm.contentsOfDirectory(atPath: archiverCache.path)) ?? []).filter { $0.hasPrefix("gpuarchiver-") })
}
func removeArchiverFolders(since before: Set<String>) {
    guard let archiverCache else { return }
    for name in archiverFolders().subtracting(before) {
        let folder = archiverCache.appendingPathComponent(name)
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
        let lock = open(folder.appendingPathComponent("PersistentState-lock").path, O_RDWR | O_NOFOLLOW)
        if lock >= 0 { defer { close(lock) }; guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { continue } }
        try? fm.removeItem(at: folder)
    }
}
// While a session's preparation runs: how many pipelines are ready of all learned,
// for the launcher's main window.
let preparing = root.appendingPathComponent("cache/preparing.json")
func prepare() throws {
    let original = try consolidate()
    guard fm.fileExists(atPath: original.appendingPathComponent("recipes").path) else {
        print("No learned pipelines yet"); progress("done", ["learned": 0, "ready": 0, "added": 0]); return
    }
    var lock = open(original.appendingPathComponent("write.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { if lock >= 0 { close(lock) }; exit(75) }
    defer { close(lock) }
    defer { try? summarize(original) }
    var previous = try keys(original)
    // Every way out says how many are ready now; a failure leaves the archives published so far.
    var ready = previous.count, added = 0, warmed = 0
    defer { progress("done", ["ready": ready, "added": added, "warmed": warmed]) }
    var costs: [String: Double] = [:], modified: [String: Double] = [:]
    for file in try fm.contentsOfDirectory(at: original.appendingPathComponent("recipes"), includingPropertiesForKeys: [.isSymbolicLinkKey,.contentModificationDateKey]) {
        autoreleasepool {
            let key = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", validKey(key),
                  let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey,.contentModificationDateKey]), values.isSymbolicLink != true,
                  let data = try? json(file), let cost = data["cost_us"] as? Double, cost.isFinite, cost >= 0, cost <= 60000000 else { return }
            costs[key] = cost; modified[key] = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
    }
    // A process killed while saving an archive leaves it half written; the game counts it.
    for file in (try? fm.contentsOfDirectory(at: original.appendingPathComponent("archives"), includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("capture-") && file.pathExtension == "tmp" { try? fm.removeItem(at: file) }
    progress("learned", ["learned": costs.count, "ready": previous.count])
    if !afterSession { warmed = try warm(original, costs) }
    guard afterSession else {
        if let saved = try? json(report) { added = saved["added"] as? Int ?? 0; try? fm.removeItem(at: report) }
        print("The archive is prepared after the session"); return
    }
    // Every learned pipeline is prepared: the slowest to build first, and of those as
    // slow, the ones used lately (the game rewrites a recipe each session it is used).
    let newest = modified.values.max() ?? 0
    var weights: [String: Double] = [:]
    for (key, cost) in costs { weights[key] = min(cost, 250000) * (0.25 + 0.75 * pow(2, -(newest - modified[key]!) / 21600)) }
    func ranked<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { weights[$0]! == weights[$1]! ? $0 < $1 : weights[$0]! > weights[$1]! }
    }
    var pending = ranked(costs.keys.filter { !previous.contains($0) })
    // Archives the game will not load (missing or damaged) are built again into the next batch.
    var damaged = Set<String>()
    for entry in try packEntries(original) where (try? sha(original.appendingPathComponent("archives/\(entry.hash).metallib"))) != entry.hash {
        damaged.insert(entry.hash)
    }
    try? save(["ready": ready, "learned": costs.count], preparing)
    defer { try? fm.removeItem(at: preparing) }
    let staging = root.appendingPathComponent("pipeline-staging")
    let clone = staging.appendingPathComponent("cache"), candidate = clone.appendingPathComponent(original.lastPathComponent)
    func invoke(_ mode: String, _ selection: [String]) throws -> [String: Any] {
        let list = staging.appendingPathComponent(mode + "-selection.json"); try save(selection, list)
        var env = ["PATH":"/usr/bin:/bin", "HOME":root.appendingPathComponent("home").path,
                   "DXMT_PIPELINE_CACHE_PATH":clone.path, "DXMT_PIPELINE_CACHE_NAMESPACE":namespaceBuild,
                   "DXMT_PIPELINE_CACHE_PREWARM_LIMIT":String(selection.count), "DXMT_PIPELINE_CACHE_PREWARM_MS":"180000",
                   "DXMT_PIPELINE_CACHE_MIN_COST_US":"0", "DXMT_PIPELINE_CACHE_APPEND":"1", "DXMT_PIPELINE_CACHE_SELECTION":list.path,
                   "DXMT_PIPELINE_CACHE_VERIFY_ONLY":mode == "verify" ? "1":"0"]
        let feed = mode == "prepare" ? PipelineFeed(staging.appendingPathComponent("prepare-log"), previous) : nil
        // Progress within the batch, so the main window's ring moves while a batch builds.
        let fresh = selection.filter { !previous.contains($0) }.count, readyBefore = ready, learned = costs.count
        feed?.onBuilt = { count in try? save(["ready": readyBefore + min(count, fresh), "learned": learned], preparing) }
        if let feed { env["DXMT_PIPELINE_CACHE_LOG"] = feed.log.path }
        let output = staging.appendingPathComponent(mode + ".json")
        let before = archiverFolders(); defer { removeArchiverFolders(since: before) }
        try require(try run(helper,[],env,output,270,tick:feed.map { feed in { feed.poll($0,$1) } }) == 0,"Pipeline tool failed")
        return try json(output, limit: catalogLimit)
    }
    var baselineRecipes: [String: String]?, baselineLibraries: [String: String]?, batches = 0
    while interrupted == 0 {
        let entries = try packEntries(original)
        let adding = !pending.isEmpty
        let small = entries.filter { $0.keys.count < smallArchive && !damaged.contains($0.hash) }
        // Damaged archives always; small ones when there is something to merge them with.
        var rebuild = entries.filter { damaged.contains($0.hash) } + (adding || small.count > 1 ? small : [])
        guard adding || !rebuild.isEmpty else {
            if batches == 0 { print("Learned pipelines are up to date") }
            break
        }
        var limited: [(hash: String, keys: [String])] = [], count = 0
        for entry in rebuild where limited.isEmpty || count + entry.keys.count <= rebuildLimit { limited.append(entry); count += entry.keys.count }
        rebuild = limited
        let rebuilt = Set(rebuild.map(\.hash)), kept = entries.filter { !rebuilt.contains($0.hash) }
        let keptKeys = Set(kept.flatMap(\.keys))
        // A rebuilt archive's pipelines go first; one without a recipe can't be built again.
        let again = ranked(Set(rebuild.flatMap(\.keys)).subtracting(keptKeys).filter { costs[$0] != nil })
        var fresh: [String] = [], cost = 0.0
        for key in pending {
            if again.count + fresh.count >= batchLimit || (!fresh.isEmpty && cost + costs[key]! > batchCost) { break }
            fresh.append(key); cost += costs[key]!
        }
        let selection = again + fresh
        guard !selection.isEmpty else { break }
        guard freeBytes() > 2 << 30 else { print("Preparation skipped to preserve disk headroom"); break }
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) } // Only unpublished output/one prior cache.
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if baselineRecipes == nil {
            progress("checking")
            baselineRecipes = try inventory(original.appendingPathComponent("recipes"))
            baselineLibraries = try inventory(original.appendingPathComponent("libraries"))
        }
        try require(try run(URL(fileURLWithPath:"/bin/cp"),["-cR",cache.path,clone.path],nil,staging.appendingPathComponent("copy.log"),120) == 0,"Cache clone failed")
        if !rebuild.isEmpty {
            let path = candidate.appendingPathComponent("archive.json")
            let archives = (try json(path, limit: catalogLimit)["archives"] as? [[String: Any]] ?? []).filter { !rebuilt.contains($0["sha256"] as? String ?? "") }
            try save(["schema": 2, "archives": archives, "prepared_keys": keptKeys.sorted()], path)
            for hash in rebuilt { try? fm.removeItem(at: candidate.appendingPathComponent("archives/\(hash).metallib")) }
        }
        progress("preparing", ["target": selection.count])
        let prepared = try invoke("prepare", selection)
        try require(prepared["namespace_directory"] as? String == candidate.path && prepared["write_owner"] as? Bool == true,"Namespace or writer ownership changed")
        // A saved batch adds what the tool captured (not a pipeline finished after its
        // deadline) to the archives kept. A catalog left as it was was not saved.
        let captured = Set(prepared["captured_keys"] as? [String] ?? []), catalog = try keys(candidate)
        let late = prepared["deadline_exceeded"] as? Bool == true
        guard !captured.isEmpty, captured.isSubset(of: Set(selection)), catalog == keptKeys.union(captured) else {
            print("Archive not saved; existing cache kept"); break
        }
        // A rebuilt archive's pipelines all move to the new one, unless one failed to build.
        guard !late || Set(again).isSubset(of: captured) else { print("Preparation ran out of time; the rest is prepared after the next session"); break }
        try orderSlowestFirst(candidate, costs)
        progress("verifying", ["target": captured.count])
        let verified = try invoke("verify", captured.sorted())
        try require(verified["write_owner"] as? Bool == true && verified["verify_only"] as? Bool == true && verified["failures"] as? Int == 0 && verified["archive_failures"] as? Int == 0 && verified["prepared"] as? Int == captured.count,"Fresh-process verification failed")
        try require(try inventory(candidate.appendingPathComponent("recipes")) == baselineRecipes! && inventory(candidate.appendingPathComponent("libraries")) == baselineLibraries!,"Preparation changed learned input")
        let listed = Set(try packEntries(candidate).map { $0.hash + ".metallib" })
        for file in try fm.contentsOfDirectory(at:candidate.appendingPathComponent("archives"),includingPropertiesForKeys:nil) where file.pathExtension == "metallib" && !listed.contains(file.lastPathComponent) { try fm.removeItem(at:file) }
        try require(interrupted == 0,"Preparation cancelled")
        try require(renameatx_np(AT_FDCWD,original.path,AT_FDCWD,candidate.path,UInt32(RENAME_SWAP)) == 0,"Atomic cache publication failed")
        batches += 1
        let newly = catalog.subtracting(previous).count
        previous = catalog; ready = catalog.count; added += newly
        let earlier = (try? json(report))?["added"] as? Int ?? 0
        try? save(["added": earlier + newly], report)
        try? save(["ready": ready, "learned": costs.count], preparing)
        print("Prepared and verified \(captured.count) learned pipelines; \(ready) of \(costs.count) ready")
        damaged.subtract(rebuilt)
        // Anything selected but not built (it failed, or finished past the deadline)
        // waits for the next batch or session. A batch that built none of its new ones ends the round.
        pending.removeAll { captured.contains($0) || (!late && fresh.contains($0)) }
        if !fresh.isEmpty && captured.isDisjoint(with: fresh) { break }
        // The lock held was on the folder just replaced; the next batch holds this one's.
        close(lock); lock = open(original.appendingPathComponent("write.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { break }
    }
    if interrupted == 0 { warmed = try warm(original, costs, after: true) }
}
do { try prepare() } catch {
    print("Pipeline preparation skipped; existing cache retained: \((error as? PreparationError)?.message ?? String(describing: error))")
    exit(1)
}
