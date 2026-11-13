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
        catch let e as SetupFailure { precondition(e.code=="app_worker_busy") }
        service.cancel()
        do { _ = try await slow.value;fatalError("Cancellation succeeded") }
        catch let e as SetupFailure { precondition(e.code=="cancelled") }
        let resumed=try await service.run("success");precondition(resumed.count==2)
        // Support reports name the failure; anything that isn't a plain code stays generic.
        precondition(SetupFailure(code:"process_launch_failed").reportCode=="process_launch_failed")
        precondition(SetupFailure(code:"rosetta_required").reportCode=="rosetta_required")
        precondition(SetupFailure(code:"").reportCode=="none")
        for odd in ["/private/tmp/folder","Some Error","code-with-dash","x\n","_leading",String(repeating:"a",count:65)] {
            precondition(SetupFailure(code:odd).reportCode=="other_setup_error",odd)
        }
        // REC-54: a folder macOS keeps locked gets its own message, never the generic one.
        let generic=SetupFailure(code:"unexpected_setup_error").message
        for code in SetupFailure.folderAccessCodes {
            let failure=SetupFailure(code:code)
            precondition(failure.isFolderAccess && failure.message != generic && failure.message.contains("permissions"),code)
        }
        precondition(!SetupFailure(code:"process_launch_failed").isFolderAccess && !SetupFailure(code:"").isFolderAccess)
        // REC-94: damaged game files make Repair Game Files the main button, with their own message.
        for code in SetupFailure.damagedFileCodes {
            let failure=SetupFailure(code:code)
            precondition(failure.filesDamaged && failure.repairOffer == .main && failure.message != generic && failure.message.contains("Repair"),code)
        }
        // A step that failed for a reason Recall doesn't name offers Repair beside Try Again.
        for code in ["unexpected_setup_error","process_launch_failed","environment_initialization_failed","runtime_required_component_missing"] {
            precondition(SetupFailure(code:code).repairOffer == .beside && SetupFailure(code:code).message == generic,code)
        }
        // Where the message gives the fix, there's no Repair.
        for code in ["cancelled","insufficient_disk_space","download_interrupted_retry_to_resume","cached_download_hash_mismatch","rosetta_required",
                     "close_game_before_setup","setup_already_running","install_location_unavailable","archive_hash_mismatch","directory_creation_failed"] {
            precondition(SetupFailure(code:code).repairOffer == .none,code)
        }
        // A damaged copy of the app itself still asks for a reinstall (Repair unpacks from it); damaged
        // game files no longer do, since a reinstall only checks the same files again.
        precondition(SetupFailure(code:"archive_hash_mismatch").message.contains("reinstall"))
        precondition(!SetupFailure(code:"runtime_file_hash_mismatch").message.contains("reinstall") && !SetupFailure(code:"runtime_missing").message.contains("reinstall"))
        print("PASS: native event stream, graphics progress, structured errors, concurrent operation exclusion, cancellation and resume, support report codes, folder access messages, repair offers")
    }
}
