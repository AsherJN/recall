import Foundation

/// Recall's text in the Mac's language (English or Simplified Chinese). Every string a player
/// sees goes through L: the English is the key, and the app's Localizable.strings
/// (zh-Hans.lproj, written by build_native_app.py from app/Resources/Localizations/zh-Hans.json)
/// holds its translation; without one the English shows. {0}, {1}… in the text stand for VALUES,
/// in order, and are filled in after the lookup, so a translation can put them where its grammar
/// needs. tests/test_localization.py checks that every L("…") has a translation with the same
/// {n} and that no on-screen text skips L.
func L(_ english: String, _ values: String...) -> String {
    let text=Bundle.main.localizedString(forKey:english,value:english,table:nil)
    guard !values.isEmpty else { return text }
    // One pass, so a value that itself contains "{1}" is never filled in again.
    var result="", rest=Substring(text)
    while let open=rest.firstIndex(of:"{") {
        result+=rest[..<open]
        let after=rest[rest.index(after:open)...]
        if let close=after.firstIndex(of:"}"),let index=Int(after[..<close]),values.indices.contains(index) {
            result+=values[index];rest=after[after.index(after:close)...]
        } else { result+="{";rest=after }
    }
    return result+rest
}

/// Whole sentences, one after another: a space between them in English, none in Chinese (the
/// pattern "{0} {1}" is translated like any other text). Empty parts are left out.
func sentences(_ parts:String...) -> String {
    parts.filter { !$0.isEmpty }.reduce("") { $0.isEmpty ? $1 : L("{0} {1}",$0,$1) }
}

enum AppLanguage {
    /// The language Recall shows, as macOS chose it from the Mac's (or, in System Settings ›
    /// General › Language & Region › Applications, Recall's own) languages: "en" or "zh-Hans".
    static var current:String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var isChinese:Bool { current.hasPrefix("zh") }
    /// What goes between a bold lead-in and its text: a space in English, none in Chinese.
    static var gap:String { L("{0} {1}","","") }
}
