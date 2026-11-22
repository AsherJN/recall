// Shown once after an update and from the Help menu, offline. Edit for each
// release with the public release notes: the same items, in the same order
// (most important first); short, plain sentences.
enum WhatsNew {
    static let version="1.6.7"
    static var items:[(symbol:String, title:String, detail:String)] { [
        ("arrow.down.circle",L("Installing games"),
         L("Fixed Battle.net freezing when you click Install on a game.")),
    ] }
}
