// Native counterpart of prepare_dxmt_pipelines.py. No player-side compiler/Python.
import Foundation
import CryptoKit
import Darwin
import Metal

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let cache = root.appendingPathComponent("cache/pipelines")
let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("pipeline-prepare")
// The app Overwatch runs as (the engine's Game Mode app), when the launch uses it.
let gameApp = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL : nil
let started = Date()
var child: Process?
var interrupted: Int32 = 0
signal(SIGTERM) { _ in interrupted = 1 }
signal(SIGINT) { _ in interrupted = 1 }
struct PreparationError: Error { let message: String }
func require(_ ok: Bool, _ message: String) throws { if !ok { throw PreparationError(message: message) } }
func json(_ url: URL) throws -> [String: Any] {
    try require((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 2*1024*1024, "Metadata too large")
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
}
func save(_ value: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic) }
func sha(_ url: URL) throws -> String {
    let stream = try FileHandle(forReadingFrom: url); defer { try? stream.close() }
    var digest = SHA256()
    while let data = try stream.read(upToCount: 131072), !data.isEmpty { digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func keys(_ directory: URL) throws -> Set<String> {
    let path = directory.appendingPathComponent("archive.json")
    if !fm.fileExists(atPath: path.path) { return [] }
    let values = try json(path)["prepared_keys"] as? [String] ?? []
    try require(values.count <= 32768 && values.allSatisfy { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }, "Invalid key catalog")
    return Set(values)
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
    var offset: UInt64 = 0, pending: [UInt8] = [], batch: [[Any]] = [], sent = Date()
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
        }
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
        if value.isRegularFile == true { result[String(file.path.dropFirst(directory.path.count + 1))] = try sha(file) }
    }
    return result
}
// The game keeps what it learns in a folder named after this Mac's GPU and
// macOS version, hashed with Metal's registry ID for the GPU (pipeline_cache.c).
// macOS reassigns that ID at each restart, so each restart began a new, empty
// folder. Before each session, earlier folders are folded into the one the
// game will open now, and removed.
let namespaceBuild = "ow2-source-v1"
let mergeLimit = 256 * 1048576 // Leaves the game's 512 MB budget room for archives and new learning.
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
func folderBytes(_ folder: URL) -> Int {
    var total = 0
    guard let it = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey,.fileSizeKey]) else { return 0 }
    for case let file as URL in it { if let value = try? file.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey]), value.isRegularFile == true { total += value.fileSize ?? 0 } }
    return total
}
func fileBytes(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
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
    let free = try fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? UInt64 ?? 0
    guard free > 1 << 30 else { print("Earlier learned pipelines kept for the next session to preserve disk headroom"); return current }
    var used = folderBytes(current), added = 0
    let recipes = current.appendingPathComponent("recipes"), libraries = current.appendingPathComponent("libraries")
    for directory in [recipes, libraries] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    for donor in earlier {
        var entries: [(key: String, cost: Double, libraries: [String])] = []
        for file in try fm.contentsOfDirectory(at: donor.appendingPathComponent("recipes"), includingPropertiesForKeys: nil).prefix(32768) {
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
            let bytes = sizes.reduce(0) { $0 + $1! }
            guard used + bytes <= mergeLimit else { continue }
            for name in missing { try fm.copyItem(at: donor.appendingPathComponent("libraries").appendingPathComponent(name), to: libraries.appendingPathComponent(name)) }
            try fm.copyItem(at: donor.appendingPathComponent("recipes").appendingPathComponent(entry.key + ".json"), to: recipes.appendingPathComponent(entry.key + ".json"))
            used += bytes; added += 1
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
// mid-match. pipeline-warm compiles them into that app's cache before the session,
// costliest first, once per app, macOS version and GPU (cache/warmed.json); after
// that the game adds what it compiles itself.
func warm(_ folder: URL, _ costs: [String: Double]) throws -> Int {
    guard let app = gameApp, !costs.isEmpty,
          let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let identifier = info["CFBundleIdentifier"] as? String,
          identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$", options: .regularExpression) != nil, !identifier.contains("..") else { return 0 }
    let tool = helper.deletingLastPathComponent().appendingPathComponent("pipeline-warm")
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fm.isExecutableFile(atPath: tool.path), confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0,
          let device = MTLCreateSystemDefaultDevice() else { return 0 }
    let caches = String(cString: buffer)
    let target = URL(fileURLWithPath: caches).appendingPathComponent(identifier).appendingPathComponent("com.apple.metal")
    let marker = cache.deletingLastPathComponent().appendingPathComponent("warmed.json")
    let expected = ["app": identifier, "macos": ProcessInfo.processInfo.operatingSystemVersionString, "gpu": device.name]
    if fm.fileExists(atPath: target.path), let saved = try? json(marker), expected.allSatisfy({ saved[$0.key] as? String == $0.value }) { return 0 }
    // The worker waits 600 s for all of preparation; about 120 KB of cache per pipeline.
    let remaining = 540 - Date().timeIntervalSince(started)
    let free = (try? fm.attributesOfFileSystem(forPath: caches)[.systemFreeSize] as? UInt64) ?? 0
    guard remaining > 30, free > 4 << 30 else { print("Shader warm-up left for the next session"); return 0 }
    let work = root.appendingPathComponent("tmp")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    let selection = Array(costs.keys.sorted { costs[$0]! == costs[$1]! ? $0 < $1 : costs[$0]! > costs[$1]! }.prefix(16384))
    let list = work.appendingPathComponent("warm-selection.json"); try save(selection, list)
    let seconds = min(300, remaining - 20)
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
func prepare() throws {
    let original = try consolidate()
    guard fm.fileExists(atPath: original.appendingPathComponent("recipes").path) else {
        print("No learned pipelines yet"); progress("done", ["learned": 0, "ready": 0, "added": 0]); return
    }
    let lock = open(original.appendingPathComponent("write.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { if lock >= 0 { close(lock) }; exit(75) }
    defer { close(lock) }
    let previous = try keys(original)
    // Every way out says how many are ready now; a failure leaves the earlier archive.
    var ready = previous.count, added = 0, warmed = 0
    defer { progress("done", ["ready": ready, "added": added, "warmed": warmed]) }
    let manifestPath = original.appendingPathComponent("archive.json")
    let manifest = fm.fileExists(atPath: manifestPath.path) ? try json(manifestPath) : [:]
    let archiveBytes = (manifest["archives"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }
    var costs: [String: Double] = [:], modified: [String: Double] = [:]
    for file in try fm.contentsOfDirectory(at: original.appendingPathComponent("recipes"), includingPropertiesForKeys: [.isSymbolicLinkKey,.contentModificationDateKey]).sorted(by: { $0.path < $1.path }).prefix(32768) {
        let key = file.deletingPathExtension().lastPathComponent
        guard file.pathExtension == "json", key.count == 64, key.allSatisfy({ "0123456789abcdef".contains($0) }),
              let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey,.contentModificationDateKey]), values.isSymbolicLink != true,
              let data = try? json(file), let cost = data["cost_us"] as? Double, cost.isFinite, cost >= 0, cost <= 60000000 else { continue }
        costs[key] = cost; modified[key] = values.contentModificationDate?.timeIntervalSince1970 ?? 0
    }
    progress("learned", ["learned": costs.count, "ready": previous.count])
    warmed = try warm(original, costs)
    let candidates = costs.keys.filter { !previous.contains($0) && costs[$0]! >= 16667 }
    guard !candidates.isEmpty else { print("Learned pipelines are up to date"); return }
    let newest = modified.values.max() ?? 0
    let scores = costs.mapValues { min($0,250000) }.map { key, value in (key, value * (0.25 + 0.75 * pow(2,-(newest-modified[key]!)/21600))) }
    let weights = Dictionary(uniqueKeysWithValues: scores)
    func score(_ set: Set<String>) -> Double { set.reduce(0) { $0 + (weights[$1] ?? 0) } }
    let ranking = costs.keys.filter { costs[$0]! >= 16667 }.sorted { weights[$0]! == weights[$1]! ? $0 < $1 : weights[$0]! > weights[$1]! }
    // A full archive is rebuilt from the best-scoring pipelines, sized to fit with
    // room to spare. So is one listing pipelines with no recipe left to restore
    // (the game archives what it prewarms): offline preparation must cover every
    // listed key, so it could never extend that archive.
    let full = archiveBytes >= Int(128 * 1048576 * 0.85), orphaned = previous.subtracting(costs.keys).count
    let refresh = full || orphaned > 0
    let additional = previous.isEmpty || archiveBytes == 0 ? 256 : max(1,Int(Double(previous.count) * (Double(128 * 1048576) * 0.90 / Double(archiveBytes) - 1)))
    var limit = full ? min(7168,max(1,Int(Double(previous.count) * min(1, Double(128 * 1048576) * 0.85 / Double(archiveBytes)))),ranking.count)
        : refresh ? min(7168,previous.count - orphaned + min(candidates.count,additional,1024),ranking.count)
        : min(7168,previous.count + min(candidates.count,additional,1024))
    if refresh && score(Set(ranking.prefix(limit))) <= score(previous)*1.05 { print("Current archive covers comparable historical cost"); return }
    if !refresh && limit <= previous.count { return }
    let decisionFile = original.appendingPathComponent("refresh-decision-native.json")
    let decision: [String: Any] = ["inventory": costs.keys.sorted().map { [$0,String(costs[$0]!),String(modified[$0]!)] }, "archive": fm.fileExists(atPath: manifestPath.path) ? try sha(manifestPath) : ""]
    let decisionData = try JSONSerialization.data(withJSONObject: decision, options: [.sortedKeys])
    if refresh, let prior = try? Data(contentsOf: decisionFile), prior == decisionData { print("Refresh already evaluated"); return }
    let free = try fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? UInt64 ?? 0
    guard free > 2 << 30 else { print("Preparation skipped to preserve disk headroom"); return }
    let staging = root.appendingPathComponent("pipeline-staging")
    if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) } // Only unpublished output/one prior cache.
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    // Keep staging after interruption: swap is atomic and both versions remain complete.
    progress("checking")
    let baselineRecipes = try inventory(original.appendingPathComponent("recipes"))
    let baselineLibraries = try inventory(original.appendingPathComponent("libraries"))
    let clone = staging.appendingPathComponent("cache")
    let candidate = clone.appendingPathComponent(original.lastPathComponent)
    func invoke(_ mode: String, _ count: Int, _ selection: [String]?) throws -> [String: Any] {
        var env = ["PATH":"/usr/bin:/bin", "HOME":root.appendingPathComponent("home").path,
                   "DXMT_PIPELINE_CACHE_PATH":clone.path,"DXMT_PIPELINE_CACHE_NAMESPACE":namespaceBuild,
                   "DXMT_PIPELINE_CACHE_PREWARM_LIMIT":String(count),"DXMT_PIPELINE_CACHE_PREWARM_MS":"180000",
                   "DXMT_PIPELINE_CACHE_MIN_COST_US":"16667","DXMT_PIPELINE_CACHE_VERIFY_ONLY":mode == "verify" ? "1":"0"]
        if let selection { let file=staging.appendingPathComponent("selection.json"); try save(selection,file); env["DXMT_PIPELINE_CACHE_SELECTION"]=file.path }
        let feed = mode == "prepare" ? PipelineFeed(staging.appendingPathComponent("prepare-log"), previous) : nil
        if let feed { env["DXMT_PIPELINE_CACHE_LOG"] = feed.log.path }
        let output = staging.appendingPathComponent(mode + ".json")
        try require(try run(helper,[],env,output,270,tick:feed.map { feed in { feed.poll($0,$1) } }) == 0,"Pipeline tool failed")
        return try json(output)
    }
    var selected = Set<String>(), complete = false
    for _ in 0..<3 {
        if fm.fileExists(atPath: clone.path) { try fm.removeItem(at: clone) }
        try require(try run(URL(fileURLWithPath:"/bin/cp"),["-cR",cache.path,clone.path],nil,staging.appendingPathComponent("copy.log"),30) == 0,"Cache clone failed")
        if refresh {
            try? fm.removeItem(at: candidate.appendingPathComponent("archive.json"))
            for file in try fm.contentsOfDirectory(at: candidate.appendingPathComponent("archives"),includingPropertiesForKeys:nil) where file.pathExtension == "metallib" { try fm.removeItem(at:file) }
        }
        progress("preparing", ["target": limit])
        let prepared = try invoke("prepare",limit,refresh ? Array(ranking.prefix(limit)):nil)
        selected = try keys(candidate)
        try require(prepared["namespace_directory"] as? String == candidate.path && prepared["write_owner"] as? Bool == true,"Namespace or writer ownership changed")
        // A failed archive (too large, or not covering every listed key) leaves the
        // clone's catalog as it was, so the counts apply only to a saved one; a
        // failure tries again with fewer pipelines.
        let failures = prepared["archive_failures"] as? Int ?? 1
        if failures == 0 {
            try require(selected.count <= limit && prepared["prepared"] as? Int == selected.count,"Preparation count mismatch")
            if refresh { try require(selected.isSubset(of:Set(ranking.prefix(limit))),"Unexpected refresh selection") }
            complete = refresh ? !selected.subtracting(previous).isEmpty && score(selected)>score(previous)*1.05 : previous.isSubset(of:selected) && !selected.subtracting(previous).isEmpty
            break
        }
        let extra = refresh ? limit : limit-previous.count
        if extra <= 1 { break }
        limit = (refresh ? 0:previous.count) + max(1,extra*3/4)
    }
    if complete {
        progress("verifying", ["target": selected.count])
        let verified = try invoke("verify",max(4096,selected.count),nil)
        try require(verified["write_owner"] as? Bool == true && verified["verify_only"] as? Bool == true && verified["failures"] as? Int == 0 && verified["archive_failures"] as? Int == 0 && verified["prepared"] as? Int == selected.count,"Fresh-process verification failed")
        try require(try inventory(candidate.appendingPathComponent("recipes")) == baselineRecipes && inventory(candidate.appendingPathComponent("libraries")) == baselineLibraries,"Preparation changed learned input")
        let entries = try json(candidate.appendingPathComponent("archive.json"))["archives"] as? [[String:Any]] ?? []
        let retained = Set(entries.compactMap { $0["sha256"] as? String }.map { $0 + ".metallib" })
        for name in retained { try require(try sha(candidate.appendingPathComponent("archives/"+name)) == String(name.prefix(64)),"Archive hash mismatch") }
        for file in try fm.contentsOfDirectory(at:candidate.appendingPathComponent("archives"),includingPropertiesForKeys:nil) where file.pathExtension == "metallib" && !retained.contains(file.lastPathComponent) { try fm.removeItem(at:file) }
        try require(interrupted == 0,"Preparation cancelled")
        try require(renameatx_np(AT_FDCWD,original.path,AT_FDCWD,candidate.path,UInt32(RENAME_SWAP)) == 0,"Atomic cache publication failed")
        print("Prepared and verified \(selected.count) learned pipelines; previous cache retained")
        ready = selected.count; added = selected.subtracting(previous).count
    } else { print("Existing cache preserved: no verified improvement within budget") }
    if refresh { try decisionData.write(to:decisionFile,options:.atomic) }
}
do { try prepare() } catch { fputs("Pipeline preparation skipped; existing cache retained.\n",stderr); exit(1) }
