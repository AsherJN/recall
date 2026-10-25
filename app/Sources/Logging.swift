import Foundation

/// Settings › Advanced › Logging (REC-40; worker: launch --logging, portable_logs.h). Off unless the
/// player turns it on. Each preset is named for a kind of problem, and any mix of them can be on at
/// once (REC-51): the worker joins their Wine channels. Custom is Wine's own WINEDEBUG text, as a
/// player would type it in Terminal; with presets on too, its items come after theirs. Mouse turns on
/// the window driver's mouse report, one line a second, and no Wine logging. Battle.net carries the
/// setting from when it opens, as it does the HUD, and logging costs FPS, so turning it on warns first
/// and the home screen says so while it's on (LoggingReminder). What each preset records is the worker's.
enum LoggingPreset:String, CaseIterable, Identifiable {
    case crashes, graphics, battlenet, mouse, custom
    var id:String { rawValue }
    var title:String {
        switch self {
        case .crashes: return L("Crashes and freezes")
        case .graphics: return L("Graphics")
        case .battlenet: return L("Battle.net")
        case .mouse: return L("Mouse")
        case .custom: return L("Custom")
        }
    }
    /// What it's for, under its name.
    var detail:String {
        switch self {
        case .crashes: return L("Errors, and what Overwatch was loading, for crashes and freezes.")
        case .graphics: return L("The graphics layer’s messages, for black screens, glitches and odd frame rates.")
        case .battlenet: return L("Network and sign-in messages, for Battle.net problems.")
        case .mouse: return L("How your mouse’s movement and clicks reach Overwatch, once a second, for aim problems.")
        case .custom: return L("Wine’s own logging settings, as you’d type them in Terminal.")
        }
    }
}

/// The presets that are on, in the order Settings lists them; none is off. Kept as their names joined
/// with commas ("crashes,mouse", "off" for none), as the worker takes them, so a 1.5 setting (one name)
/// reads as it was.
struct LoggingSetting:Equatable {
    private(set) var presets:[LoggingPreset]
    init(_ presets:[LoggingPreset]=[]) { self.presets=LoggingPreset.allCases.filter(presets.contains) }
    static let off=LoggingSetting()
    var isOff:Bool { presets.isEmpty }
    func contains(_ preset:LoggingPreset)->Bool { presets.contains(preset) }
    func with(_ preset:LoggingPreset, on:Bool)->LoggingSetting { LoggingSetting(on ? presets+[preset] : presets.filter { $0 != preset }) }
    /// Names it doesn't know are left out: "off", or a later version's preset.
    init(rawValue:String) {
        self.init(rawValue.split(separator:",").compactMap { LoggingPreset(rawValue:$0.trimmingCharacters(in:.whitespaces)) })
    }
    var rawValue:String { isOff ? "off" : presets.map(\.rawValue).joined(separator:",") }
    /// The presets' names, as the home screen and saved logs show them, between dots (a name may hold
    /// an "and" of its own): Custom as its text when given.
    func title(custom:String?=nil)->String {
        presets.map { preset in
            guard preset == .custom,let custom,!custom.isEmpty else { return preset.title }
            return custom
        }.joined(separator:" · ")
    }
    /// The worker's arguments for a launch with this setting.
    func launchArguments(custom:String)->[String] {
        contains(.custom) ? ["--logging",rawValue,"--logging-custom",custom] : ["--logging",rawValue]
    }
    /// What a player pastes for Custom, as Wine reads it: without a WINEDEBUG= in front, quotes or
    /// backticks around it, spaces around each item, or empty items.
    static func normalized(_ text:String)->String {
        var value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.lowercased().hasPrefix("winedebug=") { value=String(value.dropFirst(10)) }
        value=value.trimmingCharacters(in:CharacterSet(charactersIn:"\"'`“”‘’ \n\t"))
        return value.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }.joined(separator:",")
    }
    /// Wine's grammar, as the worker checks it (validCustomLogging): [process:][class]+channel or
    /// -channel, comma-separated, where a bare name turns a channel on. Classes are fixme, err, warn
    /// and trace; channel names are lowercase, at most 15 characters.
    static func valid(_ text:String)->Bool {
        guard !text.isEmpty,text.count <= 1024 else { return false }
        return text.split(separator:",",omittingEmptySubsequences:false).allSatisfy { item in
            String(item).range(of:#"^([A-Za-z0-9\x20._()-]{1,64}:)?((fixme|err|warn|trace)?[+-])?(all|[a-z0-9_]{1,15})$"#,options:.regularExpression) != nil
        }
    }
}

/// The window driver's mouse report (Logging › Mouse, REC-51; WINEMAC_INPUT_STATS): one JSON line a
/// second for each Wine process that is frontmost or has input, input-<pid>.jsonl in the session's
/// folder. Beside the mouse it counts key presses (key_*: how many, never which) for a timing check;
/// saved logs hold mouse data only, so Save Logs takes those fields out (LogBundle).
enum MouseReport {
    static func isReport(_ url:URL)->Bool { url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("input-") }
    private static let keyFields=try! NSRegularExpression(pattern:#""key_[a-z_]+":[-+0-9.eE]+,|,"key_[a-z_]+":[-+0-9.eE]+(?=\})"#)
    static func withoutKeys(_ text:String)->String {
        keyFields.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:"")
    }
}
