import Foundation
import SystemConfiguration

/// What Save Logs removes before anything is saved (LogBundle; REC-40). Each rule is for something
/// a check of real logs found (owner's Mac, October 19): the Mac's user name in paths (Battle.net's
/// agent, Recall's logs), a person's name in a device name (Overwatch's voice chat: "Tom …’s
/// AirPods Pro"), Battle.net account numbers (Overwatch's crash reports, Battle.net's client log),
/// the codes of Battle.net's local agent ("authorization", "session"), Windows user IDs (SIDs),
/// the Mac's computer name and its IPv6 address (Wine's network log) and a controller's Bluetooth
/// address (Wine's device log). Email addresses, BattleTags and sign-in tickets weren't found but
/// are removed too. Blizzard's server addresses, the country Battle.net names and version numbers
/// stay: they help and say nothing about the player. Each is replaced with a word in brackets,
/// [user], [account-id] and the like, and counted for the summary.
struct LogCleaner {
    enum Category:String, CaseIterable {
        case userName="mac_user_name",personName="person_name",computerName="computer_name",accountID="account_id",
             signInCode="sign_in_code",windowsUser="windows_user_id",ipAddress="ip_address",hardwareAddress="hardware_address",
             email,battleTag="battletag"
        /// How the summary names it.
        var title:String {
            switch self {
            case .userName: return L("your Mac’s user name")
            case .personName: return L("people’s names")
            case .computerName: return L("your Mac’s name")
            case .accountID: return L("Battle.net account numbers")
            case .signInCode: return L("Battle.net sign-in codes")
            case .windowsUser: return L("Windows user IDs")
            case .ipAddress: return L("IPv6 addresses")
            case .hardwareAddress: return L("hardware addresses")
            case .email: return L("email addresses")
            case .battleTag: return L("BattleTags")
            }
        }
    }
    private struct Rule {
        let category:Category
        let regex:NSRegularExpression
        /// Text a line must hold for the rule to look at it (case-insensitive); nil: always.
        let trigger:String?
        /// The replacement for a match, or nil to keep it.
        let replace:(NSTextCheckingResult,NSString)->String?
    }
    private var rules:[Rule]=[]
    /// How many of each were removed.
    private(set) var found:[Category:Int]=[:]
    /// Patterns that didn't compile (tests check there are none).
    private(set) var broken:[String]=[]

    /// Whose details to look for: this Mac's (forThisMac), or a test's.
    struct Identity:Sendable { var user:String;var fullName:String;var hosts:[String] }
    /// For the player's own Mac: its user and computer names and the Battle.net accounts found.
    static func forThisMac(accountIDs:Set<String>)->LogCleaner {
        var hosts=Set<String>()
        if let name=SCDynamicStoreCopyComputerName(nil,nil) as String? { hosts.insert(name) }
        if let name=SCDynamicStoreCopyLocalHostName(nil) as String? { hosts.insert(name) }
        var buffer=[CChar](repeating:0,count:256)
        if gethostname(&buffer,buffer.count) == 0 {
            let name=String(decoding:buffer.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)
            hosts.insert(name);hosts.insert(String(name.split(separator:".").first ?? ""))
        }
        return LogCleaner(user:NSUserName(),fullName:NSFullUserName(),hosts:Array(hosts),accountIDs:accountIDs)
    }
    init(user:String, fullName:String, hosts:[String], accountIDs:Set<String>) {
        func rule(_ category:Category,_ pattern:String,_ trigger:String?=nil,_ replace:@escaping (NSTextCheckingResult,NSString)->String?) {
            if let regex=try? NSRegularExpression(pattern:pattern) { rules.append(Rule(category:category,regex:regex,trigger:trigger,replace:replace)) }
            else { broken.append(pattern) }
        }
        func group(_ match:NSTextCheckingResult,_ text:NSString,_ index:Int)->String {
            match.range(at:index).location == NSNotFound ? "" : text.substring(with:match.range(at:index))
        }
        // Sign-in codes first, so nothing else changes them halfway.
        rule(.signInCode,#"(?i)("(?:authorization|session|token|access_token|refresh_token|id_token|auth_token|session_key|ticket|password|secret|cookie)"\s*:\s*")[^"]*(")"#,"\"") {
            group($0,$1,1)+"[removed]"+group($0,$1,2) }
        rule(.signInCode,#"(?i)\b((?:access_|refresh_|id_|auth_)?token|ticket|password|secret|authorization|session_?key)(=)([^\s&"',;]{6,})"#,"=") {
            group($0,$1,1)+group($0,$1,2)+"[removed]" }
        rule(.signInCode,#"(?i)\b(Bearer[\x20]+)[A-Za-z0-9._~+/-]+=*"#,"bearer") { group($0,$1,1)+"[removed]" }
        rule(.signInCode,#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]+)?"#,"eyJ") { _,_ in "[removed]" }
        rule(.signInCode,#"\b[A-Z]{2}-[0-9a-f]{32}-[0-9]{6,}\b"#,"-") { _,_ in "[removed]" }
        // Whole email addresses before the names they may hold.
        rule(.email,#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#,"@") { _,_ in "[email]" }
        // The Mac's names: its computer name before people's names, since it usually holds one.
        for host in hosts.filter({ $0.count >= 3 }).sorted(by:{ $0.count > $1.count }) {
            rule(.computerName,"(?i)"+NSRegularExpression.escapedPattern(for:host),host) { _,_ in "[computer]" }
        }
        if user.count >= 2 {
            let name=NSRegularExpression.escapedPattern(for:user)
            rule(.userName,#"(?i)([/\\]{1,2}Users[/\\]{1,2})"#+name+#"(?=[/\\\x22'\s]|$)"#,user) { group($0,$1,1)+"[user]" }
            // Elsewhere only a name that isn't an everyday word.
            if user.count >= 4 && !["user","admin","guest","test","apple","home","player","crossover","library"].contains(user.lowercased()) {
                rule(.userName,#"(?<![\w.-])"#+name+#"(?![\w-])"#,user) { _,_ in "[user]" }
            }
        }
        // "Tom Smith’s AirPods Pro": whoever's name a device carries, before the account's own name
        // (which may be part of it). Companies' own names stay.
        let companies:Set<String>=["Apple","Blizzard","Overwatch","Battle.net","Recall","Wine","Microsoft","NVIDIA","Windows","Mac","Logitech","Razer","Sony","Xbox"]
        rule(.personName,#"(?<![\w\[])(\p{Lu}[\p{L}\p{M}.-]*(?:[\x20\x{00A0}]\p{Lu}[\p{L}\p{M}.-]*){0,2})(['’]s)(?=[\x20\x{00A0}]+(?:\p{Lu}|i[A-Z]))"#,"s ") { match,text in
            let name=group(match,text,1)
            return companies.contains(name) ? nil : "[name]"+group(match,text,2)
        }
        for part in Set(fullName.split(whereSeparator:{ $0 == " " || $0 == "," }).map(String.init)).filter({ $0.count >= 3 }) {
            rule(.personName,#"(?<![\w-])"#+NSRegularExpression.escapedPattern(for:part)+#"(?![\w-])"#,part) { _,_ in "[name]" }
        }
        rule(.personName,#"[\p{Han}]{1,6}(的)(?=[\x20]?(?:AirPods|iPhone|iPad|Mac|MacBook|iMac|Beats|HomePod|Apple))"#,"的") { "[name]"+group($0,$1,1) }
        rule(.personName,#"[\p{Hangul}]{1,6}(의)(?=[\x20]?(?:AirPods|iPhone|iPad|Mac|MacBook|iMac|Beats|HomePod|Apple))"#,"의") { "[name]"+group($0,$1,1) }
        // Battle.net account numbers: as Overwatch's crash reports label them, as Battle.net's client
        // names an account (1:0:3a9882ed), in Battle.net's folders, and wherever a known one appears.
        rule(.accountID,#"(?i)(account[\x20_]?id[\x20:=]+)([0-9]{5,})"#,"account") { group($0,$1,1)+"[account-id]" }
        rule(.accountID,#"\b[0-9]:[0-9]:[0-9a-f]{6,16}\b"#,":0:") { _,_ in "[account-id]" }
        rule(.accountID,#"(?i)(\b(?:Account|BrowserCaches)[\\/]{1,2})([0-9]{5,})(?![0-9])"#,nil) { group($0,$1,1)+"[account-id]" }
        for id in accountIDs.filter({ $0.count >= 5 }).sorted() {
            rule(.accountID,#"(?<![0-9])"#+id+#"(?![0-9])"#,id) { _,_ in "[account-id]" }
        }
        rule(.windowsUser,#"S-1-5-21(?:-[0-9]+){3,4}"#,"S-1-5-21") { _,_ in "[windows-user-id]" }
        rule(.hardwareAddress,#"(?i)(?<![0-9a-f:])(?:[0-9a-f]{2}(?::|-)){5}[0-9a-f]{2}(?![0-9a-f:])"#,nil) { _,_ in "[hardware-address]" }
        // IPv6 written out in full or shortened with ::, the Mac's own included. Loopback stays, and
        // C++'s a::b isn't one (three groups and a digit at least).
        rule(.ipAddress,#"(?i)(?<![0-9a-z:])(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{0,4}::(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{0,4})(?:%[0-9a-z]+)?(?![0-9a-z:])"#,":") { match,text in
            let address=text.substring(with:match.range)
            let groups=address.split(separator:":").filter { !$0.isEmpty }.count
            return address == "::" || address == "::1" || groups < 3 || !address.contains(where:\.isNumber) ? nil : "[ip-address]"
        }
        rule(.battleTag,#"(?<![^\s"'=(:,\[])\p{L}[\p{L}\p{N}]{2,11}#[0-9]{4,6}(?![^\s"'),\].;:])"#,"#") { _,_ in "[battletag]" }
    }
    /// The text with every match replaced, counted.
    mutating func clean(_ text:String)->String {
        let result=NSMutableString(string:text)
        for rule in rules {
            if let trigger=rule.trigger,result.range(of:trigger,options:.caseInsensitive).location == NSNotFound { continue }
            let snapshot=result.copy() as! NSString
            // From the end, so earlier ranges stay where they were.
            for match in rule.regex.matches(in:snapshot as String,range:NSRange(location:0,length:snapshot.length)).reversed() {
                guard let replacement=rule.replace(match,snapshot) else { continue }
                result.replaceCharacters(in:match.range,with:replacement)
                found[rule.category,default:0]+=1
            }
        }
        return result as String
    }
}
