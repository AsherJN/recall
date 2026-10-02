import Foundation

struct Release: Decodable {
    let appVersion: String
    let runtimeVersion: String
    let runtimeArchive: String
    let runtimeSHA256: String
    let installerURL: String
    let installerSHA256: String
    let distribution: String
}
struct SetupFailure: Error {
    let code: String
    var message: String {
        switch code {
        case "cancelled": return "Setup is paused. Continue when you’re ready; completed steps are saved."
        case "apple_silicon_required": return "This version requires a Mac with Apple Silicon (M1 or later)."
        case "macos_26_required": return "This version requires macOS 26 or later. Update macOS, then check again."
        case "rosetta_required": return "Rosetta is needed to run the game. Choose Install Rosetta and follow Apple’s instructions."
        case "install_location_unavailable": return "The drive with your installation isn’t connected. Connect it, then try again."
        case "unsupported_volume_format": return "This drive’s format isn’t supported. Choose a drive formatted as APFS or Mac OS Extended."
        case "case_sensitive_volume": return "This drive is case-sensitive, which Windows games don’t support. Choose another drive."
        case "read_only_volume": return "This location is read-only. Choose another location."
        case "insufficient_disk_space": return "There isn’t enough free storage to finish this step. Free at least 6 GB, then retry."
        case "close_game_before_maintenance", "close_game_before_setup", "environment_busy_retry", "environment_initialization_busy": return "Close Overwatch and Battle.net, then retry. Your current session has been left running."
        case "setup_already_running", "pipeline_cache_busy": return "Another setup or launch is finishing. Wait a moment, then retry."
        case "download_interrupted_retry_to_resume": return "The download was interrupted. Check your connection and retry to resume."
        case "download_hash_mismatch", "client_installer_hash_mismatch": return "The download differs from the version this app expects. Retry once; if it happens again, check for a newer app release."
        case "archive_hash_mismatch", "runtime_file_hash_mismatch", "runtime_missing": return "An installation component is missing or damaged. Keep your game data and reinstall the app from the original download."
        case "close_installer_client": return "Close the Battle.net window opened by its installer, then choose Retry here. This app will reopen it with the required display settings."
        case "battlenet_not_installed": return "Finish installing Battle.net in its installer window, then choose Continue."
        case "retina_configuration_failed": return "The display setup couldn’t finish. Close Overwatch and Battle.net, then retry. If it happens again, open Help & FAQ to save a support report."
        case "directory_not_owned_by_app", "invalid_ownership_marker", "existing_environment_not_owned": return "The destination contains data this app did not create. Nothing was replaced. Open Help & FAQ for installation guidance."
        case "invalid_game_settings", "multiple_game_settings", "settings_outside_installation": return "The game’s settings could not be safely updated. They were preserved. Open Help & FAQ to save a support report."
        case "session_check_failed", "session_membership_unknown": return "The app couldn’t verify the running session. Close Battle.net and Overwatch normally, then retry."
        case "close_game_before_uninstall": return "Overwatch is running. Quit the game, then try again. Nothing was removed."
        case "client_close_failed": return "Battle.net couldn’t be closed. Quit it from the Dock, then try again. Nothing was removed."
        case "uninstall_move_failed": return "The game folder couldn’t be moved to the Trash. Nothing was deleted. Open Help & FAQ to save a support report."
        case "run_from_installed_app", "app_move_failed": return "\(Brand.name) couldn’t move itself. Drag \(Brand.name) to Applications, eject the disk image, then open it from Applications."
        case "app_name_taken": return "Another app named \(Brand.name) is in your Applications folders. Rename or remove that app, then try again."
        case "release_unavailable": return "This app is missing its verified setup components. Download a complete copy from the release page."
        default: return "This step couldn’t finish. Retry, or open Help & FAQ to save a support report. Your game data has been kept."
        }
    }
}

// A worker invocation owns the installation lock. Output is bounded JSON events,
// never raw Wine logs. Blocking reads live off the UI thread.
@MainActor
final class SetupService {
    var root: URL
    let helper: URL
    private var process: Process?
    private var cancelRequested=false
    init(root: URL, helper: URL) { self.root=root; self.helper=helper }
    func cancel() { cancelRequested=true; if process?.isRunning == true { process?.terminate() } }
    func run(_ command: String, _ args: [String] = [], event: @escaping @MainActor ([String:Any])->Void = { _ in }) async throws -> [[String:Any]] {
        guard process == nil else { throw SetupFailure(code:"setup_already_running") }
        let p=Process(), pipe=Pipe()
        p.executableURL=helper; p.arguments=[command,"--root",root.path]+args
        p.standardOutput=pipe; p.standardError=FileHandle.nullDevice
        p.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":NSHomeDirectory()]
        process=p;cancelRequested=false
        defer { process=nil }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                // First execution can wait for macOS signature assessment.
                // Keep both spawn and pipe reads off the main actor.
                do { try p.run() }
                catch { continuation.resume(throwing:SetupFailure(code:"process_launch_failed"));return }
                Task { @MainActor in if self.cancelRequested && self.process === p { self.cancel() } }
                var pending=Data(), events=[[String:Any]](), oversized=false
                while true {
                    let data=pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    if pending.count > 65536 { oversized=true; p.terminate(); break }
                    while let end=pending.firstIndex(of:10) {
                        let line=pending[..<end]; pending.removeSubrange(...end)
                        if let value=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any] {
                            events.append(value)
                            if events.count>256 { events.removeFirst() }
                            Task { @MainActor in event(value) }
                        }
                    }
                }
                p.waitUntilExit()
                try? pipe.fileHandleForReading.close()
                if let error=events.last(where:{$0["stage"] as? String == "error"})?["code"] as? String {
                    continuation.resume(throwing:SetupFailure(code:error))
                } else if p.terminationStatus != 0 || oversized {
                    continuation.resume(throwing:SetupFailure(code:p.terminationReason == .uncaughtSignal ? "cancelled":"process_failed"))
                } else { continuation.resume(returning:events) }
            }
        }
    }
}
