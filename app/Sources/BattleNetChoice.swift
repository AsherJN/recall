import Foundation

/// Which Battle.net Recall installs, chosen at setup (worker: battlenet, portable_region.h): Global
/// or China's (国服, run by NetEase). Accounts don't carry over between the two, so changing
/// region later moves the installation to the Trash and sets up again (Settings › General).
enum BattleNetRegion:String, CaseIterable, Identifiable {
    case global, china="cn"
    var id:String { rawValue }
    var title:String { self == .global ? L("Global") : L("China (国服)") }
    var detail:String {
        self == .global ? L("Blizzard accounts everywhere outside mainland China.") : L("NetEase accounts for mainland China.")
    }
    /// What setup suggests: China's Battle.net on a Mac whose region is mainland China.
    static var suggested:BattleNetRegion { Locale.current.region?.identifier == "CN" ? .china : .global }
}

/// The language Battle.net installs in (the installer's --lang). China's Battle.net comes only in
/// Simplified Chinese. Chinese and Korean also have the worker add the fonts Wine needs for them.
enum BattleNetLanguage:String, CaseIterable, Identifiable {
    case english="enUS", simplifiedChinese="zhCN", korean="koKR"
    var id:String { rawValue }
    /// Each in its own language, as language menus name them.
    var name:String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .korean: return "한국어"
        }
    }
    /// What setup suggests: the Mac's first language, when it is one of these.
    static var suggested:BattleNetLanguage {
        let first=(Locale.preferredLanguages.first ?? "").lowercased()
        if first.hasPrefix("ko") { return .korean }
        if first.hasPrefix("zh-hans") || ["zh","zh-cn","zh-sg"].contains(first) { return .simplifiedChinese }
        return .english
    }
}
