import Foundation

// BattleNetRegion (app/Sources/BattleNetChoice.swift): the region an installation is on, read from the
// worker's state.json, and the Battle.net setup hands the worker. Build and run:
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/Localization.swift \
//     app/Sources/BattleNetChoice.swift tests/RegionTests.swift -o runtime/phase-3/region-tests
//   runtime/phase-3/region-tests
@main struct RegionTests {
    static func main() {
        // Before 1.4.1 nothing kept a region: Global, or Korea where 1.3's Korean account support is on.
        precondition(BattleNetRegion.kept([:]) == .global)
        precondition(BattleNetRegion.kept(["korean_support":true]) == .korea)
        precondition(BattleNetRegion.kept(["korean_support":false]) == .global)
        // From 1.4.1: Global's Battle.net is Korea while Korean account support is on; China's never is.
        precondition(BattleNetRegion.kept(["battlenet_region":"global"]) == .global)
        precondition(BattleNetRegion.kept(["battlenet_region":"global","korean_support":true]) == .korea)
        precondition(BattleNetRegion.kept(["battlenet_region":"cn"]) == .china)
        precondition(BattleNetRegion.kept(["battlenet_region":"cn","korean_support":true]) == .china)
        // Korean accounts sign in to Global's Battle.net.
        precondition(BattleNetRegion.global.battleNet == "global" && BattleNetRegion.korea.battleNet == "global")
        precondition(BattleNetRegion.china.battleNet == "cn")
        precondition(BattleNetRegion.china.suggestedLanguage == .simplifiedChinese && BattleNetRegion.korea.suggestedLanguage == .korean)
        precondition(BattleNetRegion(rawValue:"kr") == .korea && BattleNetRegion.allCases == [.global,.korea,.china])
        print("PASS: region from state.json (before 1.4.1, Korean account support, China), the worker's Battle.net, suggested languages")
    }
}
