import Foundation

/// Which Battle.net account setup is for (worker: battlenet, portable_region.h): Global, Korea or
/// China's (国服, run by NetEase). Korean accounts linked to Nexon sign in to Global's Battle.net:
/// Korea is Global's with Korean account support on (portable_korea.h), so switching between the
/// two changes only that. China's Battle.net is its own, and accounts don't carry over, so changing
/// to or from China moves the installation to the Trash and sets up again (Settings › General).
enum BattleNetRegion:String, CaseIterable, Identifiable {
    case global, korea="kr", china="cn"
    var id:String { rawValue }
    var title:String {
        switch self {
        case .global: return L("Global")
        case .korea: return L("Korea (한국)")
        case .china: return L("China (国服)")
        }
    }
    var detail:String {
        switch self {
        case .global: return L("Blizzard accounts outside Korea and mainland China.")
        case .korea: return L("Korean accounts linked to Nexon.")
        case .china: return L("NetEase accounts for mainland China.")
        }
    }
    /// The Battle.net the worker installs (battlenet --region).
    var battleNet:String { self == .china ? "cn" : "global" }
    /// The region a worker's state.json keeps: China's Battle.net, or Global's, which is Korea while
    /// Korean account support is on. Installations from before 1.4.1 keep no region: Global's.
    static func kept(_ state:[String:Any]) -> BattleNetRegion {
        if state["battlenet_region"] as? String == "cn" { return .china }
        return state["korean_support"] as? Bool == true ? .korea : .global
    }
    /// What setup suggests, from the Mac's region.
    static var suggested:BattleNetRegion {
        switch Locale.current.region?.identifier {
        case "CN": return .china
        case "KR": return .korea
        default: return .global
        }
    }
    /// The Battle.net language that goes with it: China's comes only in Simplified Chinese, Korea
    /// suggests Korean, Global the Mac's language.
    var suggestedLanguage:BattleNetLanguage {
        switch self {
        case .global: return .suggested
        case .korea: return .korean
        case .china: return .simplifiedChinese
        }
    }
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
