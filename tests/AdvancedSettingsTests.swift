import AppKit
import Foundation

// Run: python3 tests/run_advanced_settings.py
// The runner compiles the app sources except Main.swift into a disposable .app.
// The fixture worker only edits a temporary directory; no Wine, Battle.net,
// game or saved app settings are changed.
@MainActor final class AppDelegate:NSObject { @objc func forceQuit() {} }

@main struct AdvancedSettingsTests {
    @MainActor static func main() async throws {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("recall-settings-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ow2-setup")
        try fm.createDirectory(at:helper.deletingLastPathComponent(),withIntermediateDirectories:true)
        let fixture="""
        #!/usr/bin/python3
        import json, sys, time
        from pathlib import Path
        command, root = sys.argv[1], Path(sys.argv[3])
        state_file = root / 'fixture-state.json'
        state = json.loads(state_file.read_text()) if state_file.exists() else {}
        if command == 'status':
            if (root / 'fail-status').exists():
                print(json.dumps({'stage':'error', 'code':'status_unavailable'}))
                sys.exit(1)
            print(json.dumps({'state':state}))
        else:
            assert command in ('korean-support', 'network'), command
            enabled = sys.argv[5] == '1'
            with (root / 'calls').open('a') as log:
                log.write(command + ':' + str(enabled) + '\\n')
            time.sleep(0.1)
            if (root / 'fail-setting').exists():
                print(json.dumps({'stage':'error', 'code':'setting_change_failed'}))
                sys.exit(1)
            state['korean_support' if command == 'korean-support' else 'proxy_auto_detect'] = enabled
            state_file.write_text(json.dumps(state))
            print(json.dumps({'stage':'setting_saved'}))
        """
        try fixture.write(to:helper,atomically:true,encoding:.utf8)
        try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let model=AppModel()
        model.root=root;model.service.root=root

        // Display's HUD is live, persisted, and never invokes a game/setup worker.
        _ = NSApplication.shared
        let savedHUD=model.systemStatsHUD
        model.systemStatsHUD=true
        precondition(model.statsHUD.isEnabled && AppModel().systemStatsHUD)
        model.systemStatsHUD=false
        precondition(!model.statsHUD.isEnabled && !model.statsHUD.isVisible && !AppModel().systemStatsHUD)
        model.systemStatsHUD=savedHUD
        precondition(!fm.fileExists(atPath:root.appendingPathComponent("calls").path))

        func calls() -> [String] {
            ((try? String(contentsOf:root.appendingPathComponent("calls"),encoding:.utf8)) ?? "").split(separator:"\n").map(String.init)
        }
        func wait(_ done:() -> Bool) async throws {
            let deadline=Date().addingTimeInterval(8)
            while !done() {
                precondition(Date()<deadline,"Settings task did not finish: \(model.notice)")
                try await Task.sleep(for:.milliseconds(20))
            }
        }

        model.setAdvanced(.koreanSupport,true)
        precondition(model.busy,"The worker must be reserved synchronously")
        precondition(!model.koreanSupport,"Do not show an unpersisted choice")
        var launched=false
        model.perform { launched=true }
        model.setAdvanced(.koreanSupport,false)
        model.setAdvanced(.proxyAutoDetect,true)
        try await wait { !model.busy }
        precondition(!launched && !model.koreanSupport && model.proxyAutoDetect)
        precondition(calls()==["korean-support:True","korean-support:False","network:True"])

        // Keep a choice queued behind another operation, including the interval
        // between that operation releasing busy and the queued task waking.
        model.busy=true
        model.setAdvanced(.koreanSupport,true)
        model.busy=false
        model.perform { launched=true }
        try await wait { model.koreanSupport && !model.busy }
        precondition(!launched)

        try Data().write(to:root.appendingPathComponent("fail-setting"))
        model.setAdvanced(.koreanSupport,false)
        try await wait { !model.busy }
        precondition(model.koreanSupport && !model.notice.isEmpty,"Failed writes must keep the saved choice")
        try fm.removeItem(at:root.appendingPathComponent("fail-setting"))

        try Data().write(to:root.appendingPathComponent("fail-status"))
        model.setAdvanced(.koreanSupport,false)
        try await wait { !model.busy }
        precondition(!model.koreanSupport && !model.notice.isEmpty,"A failed refresh must not undo a successful write")
        print("PASS: immediate launch exclusion, queued opposite choices, busy-operation handoff, failed writes and failed status reads")
    }
}
