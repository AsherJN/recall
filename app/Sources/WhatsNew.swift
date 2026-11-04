// Shown once after an update and from the Help menu, offline. Edit for each
// release with the public release notes: the same items, in the same order
// (most important first); short, plain sentences. 1.6.3 lists only its own
// changes, as 1.6.2 did (November 3).
enum WhatsNew {
    static let version="1.6.3"
    static var items:[(symbol:String, title:String, detail:String)] { [
        ("command",L("Cmd-Tab fix"),
         L("Fixed Overwatch freezing after you Cmd-Tab back to it in fullscreen.")),
        ("person.crop.circle.badge.checkmark",L("Battle.net fix"),
         L("Fixed Battle.net closing by itself a few seconds after it opens.")),
        ("bolt",L("Shaders after a macOS update"),
         L("After a macOS update, {0} offers to optimize your shaders for the new version before you play. To build them all again at any time, choose Rebuild Shaders in Settings › Graphics.",Brand.name)),
        ("computermouse",L("Mouse settings"),
         L("Settings › General › Mouse has a simpler layout, and its (i) button explains each mode.")),
        ("wrench.and.screwdriver",L("More fixes"),
         L("Fixed {0}’s window running off the screen when your display is set to larger text. If your Mac’s graphics stop responding, {0} now closes Overwatch and tells you, instead of leaving the picture frozen.",Brand.name)),
    ] }
}
