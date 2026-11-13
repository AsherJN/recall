// Shown once after an update and from the Help menu, offline. Edit for each
// release with the public release notes: the same items, in the same order
// (most important first); short, plain sentences. 1.6.4 lists only its own
// changes, as 1.6.2 and 1.6.3 did (owner's list, November 13).
enum WhatsNew {
    static let version="1.6.4"
    static var items:[(symbol:String, title:String, detail:String)] { [
        ("film",L("Highlights"),
         L("Highlights you record in Overwatch now save as MP4, in Movies › Overwatch. The new Highlights window lists them: open one in QuickTime, show it in Finder or share it.")),
        ("externaldrive",L("Move Overwatch"),
         L("Move Overwatch to another drive or folder from Settings › General, without downloading it again.")),
        ("person.wave.2",L("Discord activity"),
         L("Discord can show that you’re playing Overwatch on Mac with {0}, and for how long. Turn it on in Settings › General › Discord activity.",Brand.name)),
        ("person.2",L("Discord card"),
         L("The Discord card on the Play screen shows how many members are online.")),
        ("keyboard",L("Faster key response"),
         L("A new experimental switch in Settings › Advanced gets your key presses to Overwatch 1 to 3 ms sooner. It’s off unless you turn it on.")),
        ("slider.horizontal.3",L("Custom renderer settings"),
         L("Add your own renderer (dxmt.conf) settings in Settings › Advanced › Custom renderer settings. {0} keeps them at every launch and flags any line the renderer wouldn’t read.",Brand.name)),
        ("sparkles",L("Effects fix"),
         L("Fixed some effects flickering, such as Ana’s Sleep Dart, Sombra’s Hack and some mythic skins.")),
        ("bandage",L("Repair Game Files"),
         L("If {0}’s game files go missing or get damaged, for example when security software removes them, the setup screen now offers Repair Game Files. It keeps Overwatch, its settings and your Battle.net sign-in.",Brand.name)),
        ("wrench.and.screwdriver",L("More fixes"),
         L("Links you open from Battle.net or Overwatch now open your browser normally, so Chrome no longer signs you out of websites. On a MacBook Neo, macOS no longer sends you to the login screen mid-match. If {0} wasn’t in macOS’s Input Monitoring list, High-precision now asks macOS for you.",Brand.name)),
        ("questionmark.circle",L("Help"),
         L("Help now explains what to do when Overwatch opens on another screen, or when Dictation or the fn/Globe key pulls you out of a match.")),
    ] }
}
