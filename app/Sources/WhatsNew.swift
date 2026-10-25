// Shown once after an update and from the Help menu, offline. Edit for each
// release with the public release notes: the same items, in the same order
// (most important first); short, plain sentences. 1.6.1 follows 1.6.0 closely and
// most players update from 1.5, so it keeps 1.6.0's items, with Mouse options
// worded for 1.6.1 (owner, October 25).
enum WhatsNew {
    static let version="1.6.1"
    static var items:[(symbol:String, title:String, detail:String)] { [
        ("computermouse",L("Mouse options"),
         L("Choose how Overwatch reads your mouse in Settings › General › Mouse: Standard, Classic (the mouse as it worked in Recall 1.4) or High-precision, recommended for playing with a mouse. High-precision reads your mouse directly, skipping macOS’s mouse layer, and needs Input Monitoring.")),
        ("wrench.and.screwdriver",L("Fixes"),
         L("Fixed Overwatch freezing or the camera ignoring your mouse after Cmd-Tab in fullscreen, and Cmd-Tab bouncing back to Overwatch with Game Mode on. Improved display and monitor support. Fixed Battle.net reinstalling its update agent, Korean typing in Overwatch’s chat, and Overwatch closing at start on Korean accounts on macOS 27. You can go back to your external drive after choosing Set Up on This Mac Instead, and updates now show during setup and on error screens.")),
        ("headphones",L("Switch sound output any time"),
         L("Connect headphones or change your Mac’s sound output during a match, and Overwatch follows.")),
        ("gamecontroller",L("Game Mode setting"),
         L("Turn macOS Game Mode off for Overwatch in Settings › Graphics.")),
        ("questionmark.circle",L("Help & FAQ"),
         L("New answers for a locked Recall folder, case-sensitive drives, and Battle.net showing Play instead of Install.")),
        ("list.bullet.rectangle",L("Logging presets"),
         L("Turn on several logging presets at once in Settings › Advanced. A new Mouse preset records how your mouse reaches Overwatch.")),
    ] }
}

