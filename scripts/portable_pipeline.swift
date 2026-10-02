// Native counterpart of prepare_dxmt_pipelines.py. No player-side compiler/Python.
import Foundation
import CryptoKit
import Darwin

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let cache = root.appendingPathComponent("cache/pipelines")
let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("pipeline-prepare")
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
func run(_ executable: URL, _ args: [String], _ env: [String: String]?, _ output: URL, _ seconds: Double) throws -> Int32 {
    let p = Process(); p.executableURL = executable; p.arguments = args; p.environment = env
    fm.createFile(atPath: output.path, contents: nil)
    let log = try FileHandle(forWritingTo: output); defer { try? log.close() }
    p.standardOutput = log; p.standardError = FileHandle.nullDevice
    try p.run(); child = p; defer { child = nil }
    let end = Date().addingTimeInterval(seconds)
    while p.isRunning && Date() < end && interrupted == 0 { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning {
        p.terminate(); let grace = Date().addingTimeInterval(2)
        while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit(); throw PreparationError(message: "Preparation cancelled or timed out")
    }
    p.waitUntilExit(); return p.terminationStatus
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
func prepare() throws {
    guard fm.fileExists(atPath: cache.path) else { print("No learned pipelines yet"); return }
    let directories = try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).filter { fm.fileExists(atPath: $0.appendingPathComponent("recipes").path) }
    guard directories.count == 1 else { print("No single learned device namespace"); return }
    let original = directories[0]
    let lock = open(original.appendingPathComponent("write.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { if lock >= 0 { close(lock) }; exit(75) }
    defer { close(lock) }
    let previous = try keys(original)
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
    let candidates = costs.keys.filter { !previous.contains($0) && costs[$0]! >= 16667 }
    guard !candidates.isEmpty else { print("Learned pipelines are up to date"); return }
    let newest = modified.values.max() ?? 0
    let scores = costs.mapValues { min($0,250000) }.map { key, value in (key, value * (0.25 + 0.75 * pow(2,-(newest-modified[key]!)/21600))) }
    let weights = Dictionary(uniqueKeysWithValues: scores)
    func score(_ set: Set<String>) -> Double { set.reduce(0) { $0 + (weights[$1] ?? 0) } }
    let ranking = costs.keys.filter { costs[$0]! >= 16667 }.sorted { weights[$0]! == weights[$1]! ? $0 < $1 : weights[$0]! > weights[$1]! }
    let refresh = archiveBytes >= Int(128 * 1048576 * 0.85)
    let additional = previous.isEmpty || archiveBytes == 0 ? 256 : max(1,Int(Double(previous.count) * (Double(128 * 1048576) * 0.90 / Double(archiveBytes) - 1)))
    var limit = refresh ? min(7168,max(1,previous.count),ranking.count) : min(7168,previous.count + min(candidates.count,additional,1024))
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
    let baselineRecipes = try inventory(original.appendingPathComponent("recipes"))
    let baselineLibraries = try inventory(original.appendingPathComponent("libraries"))
    let clone = staging.appendingPathComponent("cache")
    let candidate = clone.appendingPathComponent(original.lastPathComponent)
    func invoke(_ mode: String, _ count: Int, _ selection: [String]?) throws -> [String: Any] {
        var env = ["PATH":"/usr/bin:/bin", "HOME":root.appendingPathComponent("home").path,
                   "DXMT_PIPELINE_CACHE_PATH":clone.path,"DXMT_PIPELINE_CACHE_NAMESPACE":"ow2-source-v1",
                   "DXMT_PIPELINE_CACHE_PREWARM_LIMIT":String(count),"DXMT_PIPELINE_CACHE_PREWARM_MS":"180000",
                   "DXMT_PIPELINE_CACHE_MIN_COST_US":"16667","DXMT_PIPELINE_CACHE_VERIFY_ONLY":mode == "verify" ? "1":"0"]
        if let selection { let file=staging.appendingPathComponent("selection.json"); try save(selection,file); env["DXMT_PIPELINE_CACHE_SELECTION"]=file.path }
        let output = staging.appendingPathComponent(mode + ".json")
        try require(try run(helper,[],env,output,270) == 0,"Pipeline tool failed")
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
        let prepared = try invoke("prepare",limit,refresh ? Array(ranking.prefix(limit)):nil)
        selected = try keys(candidate)
        try require(prepared["namespace_directory"] as? String == candidate.path && prepared["write_owner"] as? Bool == true,"Namespace or writer ownership changed")
        try require(selected.count <= limit && prepared["prepared"] as? Int == selected.count,"Preparation count mismatch")
        if refresh { try require(selected.isSubset(of:Set(ranking.prefix(limit))),"Unexpected refresh selection") }
        complete = refresh ? !selected.subtracting(previous).isEmpty && score(selected)>score(previous)*1.05 : previous.isSubset(of:selected) && !selected.subtracting(previous).isEmpty
        let failures = prepared["archive_failures"] as? Int ?? 1
        if complete && failures == 0 { break }
        complete = false
        let extra = refresh ? limit : limit-previous.count
        if failures == 0 || extra <= 1 { break }
        limit = (refresh ? 0:previous.count) + max(1,extra/2)
    }
    if complete {
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
    } else { print("Existing cache preserved: no verified improvement within budget") }
    if refresh { try decisionData.write(to:decisionFile,options:.atomic) }
}
do { try prepare() } catch { fputs("Pipeline preparation skipped; existing cache retained.\n",stderr); exit(1) }
