import Foundation

/// Settings › Advanced › Logging (REC-40; worker: launch --logging, portable_logs.h). Off unless the
/// player turns it on. A preset is named for the kind of problem; Custom is Wine's own WINEDEBUG
/// text, as a player would type it in Terminal. Battle.net carries the setting from when it opens,
/// as it does the HUD, and logging costs FPS, so turning it on warns first and the home screen
/// says so while it's on (LoggingReminder). What each preset records is the worker's.
enum LoggingSetting:String, CaseIterable, Identifiable {
    case off, crashes, graphics, battlenet, custom
    var id:String { rawValue }
    var title:String {
        switch self {
        case .off: return L("Off")
        case .crashes: return L("Crashes and freezes")
        case .graphics: return L("Graphics")
        case .battlenet: return L("Battle.net")
        case .custom: return L("Custom")
        }
    }
    /// What it's for, under the setting's name.
    var detail:String {
        switch self {
        case .off: return L("Records more of what Battle.net and Overwatch do, for a bug report.")
        case .crashes: return L("Errors, and what Overwatch was loading, for crashes and freezes.")
        case .graphics: return L("The graphics layer’s messages, for black screens, glitches and odd frame rates.")
        case .battlenet: return L("Network and sign-in messages, for Battle.net problems.")
        case .custom: return L("Wine’s own logging settings, as you’d type them in Terminal.")
        }
    }
    /// The worker's arguments for a launch with this setting.
    func launchArguments(custom:String)->[String] {
        self == .custom ? ["--logging","custom","--logging-custom",custom] : ["--logging",rawValue]
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
