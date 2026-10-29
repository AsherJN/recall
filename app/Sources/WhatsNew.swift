// Shown once after an update and from the Help menu, offline. Edit for each
// release with the public release notes: the same items, in the same order
// (most important first); short, plain sentences. 1.6.2 is three fixes a few days
// after 1.6.1, so it lists only those (October 29).
enum WhatsNew {
    static let version="1.6.2"
    static var items:[(symbol:String, title:String, detail:String)] { [
        ("gamecontroller",L("Crash fix"),
         L("Fixed Overwatch sometimes crashing while a map or the Practice Range loads.")),
        ("keyboard",L("Keyboard layouts"),
         L("Fixed switching keyboard layouts while Overwatch is running.")),
        ("person.crop.circle.badge.checkmark",L("Battle.net sign-in"),
         L("Fixed Battle.net’s sign-in page staying blank the first time it opens during setup.")),
    ] }
}
