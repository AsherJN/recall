import Foundation

@main struct ServiceTests {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let helper=root.appendingPathComponent("fixture-worker")
        let script="""
        #!/bin/sh
        case "$1" in
        success) printf '%s\\n' '{"stage":"downloading"}' '{"stage":"download_verified"}';;
        progress) printf '%s\\n' '{"stage":"display_fitted"}' '{"stage":"graphics","phase":"preparing","target":2}' '{"stage":"graphics","phase":"done","ready":2}' '{"stage":"battlenet_open"}';;
        failure) printf '%s\\n' '{"stage":"error","code":"download_hash_mismatch"}'; exit 1;;
        slow) trap 'printf "{\\"stage\\":\\"error\\",\\"code\\":\\"cancelled\\"}\\n"; exit 1' TERM; while true; do sleep 0.1; done;;
        esac
        """
        try script.write(to:helper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let service=SetupService(root:root,helper:helper)
        let events=try await service.run("success")
        precondition(events.count==2 && events.last?["stage"] as? String == "download_verified")
        // Graphics progress reaches the callback but is not kept with the launch's events.
        var seen=[String]()
        let launched=try await service.run("progress") { seen.append(($0["stage"] as? String ?? "")+"/"+($0["phase"] as? String ?? "")) }
        try await Task.sleep(for:.milliseconds(50))
        precondition(launched.map { $0["stage"] as? String ?? "" } == ["display_fitted","battlenet_open"])
        precondition(seen == ["display_fitted/","graphics/preparing","graphics/done","battlenet_open/"],"\(seen)")
        do { _ = try await service.run("failure"); fatalError("Missing worker error") }
        catch let e as SetupFailure { precondition(e.code=="download_hash_mismatch") }
        let slow=Task { try await service.run("slow") }
        try await Task.sleep(for:.milliseconds(200))
        do { _ = try await service.run("success");fatalError("Concurrent mutation accepted") }
        catch let e as SetupFailure { precondition(e.code=="setup_already_running") }
        service.cancel()
        do { _ = try await slow.value;fatalError("Cancellation succeeded") }
        catch let e as SetupFailure { precondition(e.code=="cancelled") }
        let resumed=try await service.run("success");precondition(resumed.count==2)
        print("PASS: native event stream, graphics progress, structured errors, concurrent operation exclusion, cancellation and resume")
    }
}
