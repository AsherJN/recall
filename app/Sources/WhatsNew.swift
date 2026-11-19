// Shown once after an update and from the Help menu, offline. Edit for each
// release with the public release notes: the same items, in the same order
// (most important first); short, plain sentences. 1.6.5 lists only its own
// changes, as 1.6.2 to 1.6.4 did.
enum WhatsNew {
    static let version="1.6.5"
    static var items:[(symbol:String, title:String, detail:String)] { [
        ("film",L("Highlights"),
         L("Improved the Highlights window. Clips are named after their hero and grouped by day, Copy for Discord makes a copy that fits Discord’s upload limit, and Save Just the Play and Trim… save just the part you want as a new clip.")),
        ("wrench.and.screwdriver",L("More fixes"),
         L("Fixed MP4 highlights saving as empty files on some Macs. A save that doesn’t finish now shows in the Highlights window, with a link to Help.")),
    ] }
}
