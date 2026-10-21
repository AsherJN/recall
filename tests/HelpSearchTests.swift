import AppKit

// Help's search (HelpTopic.search in app/Sources/HelpSheet.swift): every word of the query in the
// question or its answer, questions first, ignoring case, accents, width, bold and curly quotes,
// and Chinese and Korean as typed. Build with every app source but Main.swift, and run:
//   mkdir -p runtime/phase-3/help-search-tests
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library $(ls app/Sources/*.swift | grep -v Main.swift) \
//     tests/HelpSearchTests.swift -o runtime/phase-3/help-search-tests/help-search-tests
//   runtime/phase-3/help-search-tests/help-search-tests
// Main.swift's AppDelegate, for the one menu action the app's views name.
final class AppDelegate: NSObject { @objc func forceQuit() {} }
@main struct HelpSearchTests {
    @MainActor static func main() {
        func ids(_ query:String,_ topics:[HelpTopic])->[String] { HelpTopic.search(query,in:topics).map(\.id) }
        func shown(_ topics:[HelpTopic],_ region:BattleNetRegion)->[HelpTopic] { topics.filter { $0.regions.isEmpty || $0.regions.contains(region) } }
        let questions=shown(HelpTopic.questions,.global),troubleshooting=shown(HelpTopic.troubleshooting,.global)

        // Nothing typed, or only spaces: no results (Help shows the tab).
        precondition(ids("",questions).isEmpty && ids("   ",questions).isEmpty)
        // A word from the question, in any case.
        precondition(ids("rtx",questions) == ["gpu"] && ids("RTX 4090",questions) == ["gpu"])
        // Every word must appear, anywhere in the question or the answer.
        precondition(ids("mouse acceleration",questions).first == "acceleration")
        precondition(ids("acceleration trackpad",questions) == ["acceleration"])
        precondition(ids("rtx trackpad",questions).isEmpty)
        // Words only in the answer, steps or note still find it: Reflex is in the RTX 4090 note,
        // Import Code in the warm-up steps.
        precondition(ids("reflex",questions) == ["gpu"])
        precondition(ids("import code",troubleshooting) == ["hitches"])
        // Questions that name the word come first, then answers that mention it, each in Help's order.
        let shader=ids("shader",questions)
        precondition(shader.first == "shaders" && shader.contains("stutter"),"\(shader)")
        // Straight quotes find curly ones; bold markers don't split words.
        precondition(ids("won't start",troubleshooting) == ["start"])
        precondition(ids("Repair Game Files",troubleshooting) == ["start"])
        // Full-width letters and accents fold.
        precondition(ids("ＲＴＸ",questions) == ["gpu"])
        precondition(HelpTopic.folded("Rétx **Café**") == HelpTopic.folded("retx cafe"))

        // Chinese and Korean match as typed, without spaces between words.
        let zh=HelpTopic(id:"zh",symbol:"",title:"为什么守望先锋显示 RTX 4090？",answer:"这是 MetalFX 超分辨率的缘故。")
        let ko=HelpTopic(id:"ko",symbol:"",title:"오버워치에 왜 RTX 4090이 표시되나요?",answer:"MetalFX 업스케일링 때문입니다.")
        precondition(ids("守望先锋",[zh,ko]) == ["zh"] && ids("超分辨率",[zh,ko]) == ["zh"])
        precondition(ids("오버워치",[zh,ko]) == ["ko"] && ids("업스케일링",[zh,ko]) == ["ko"] && ids("오버",[zh,ko]) == ["ko"])
        precondition(ids("rtx",[zh,ko]) == ["zh","ko"])

        // Results from both tabs show together, and one open id names one topic: no id is used
        // twice among the topics any one Battle.net shows.
        for region in BattleNetRegion.allCases {
            let all=(shown(HelpTopic.questions,region)+shown(HelpTopic.troubleshooting,region)).map(\.id)
            precondition(Set(all).count == all.count,"\(region): \(all)")
        }
        // The new answer is there for every Battle.net.
        for region in BattleNetRegion.allCases { precondition(shown(HelpTopic.questions,region).contains { $0.id == "acceleration" }) }
        print("PASS: Help search finds every word in questions and answers, questions first; case, width, bold and quotes fold; Chinese and Korean as typed; ids unique per Battle.net")
    }
}
