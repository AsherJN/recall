// Shown once after an update and from the Help menu, offline. Edit for each
// release alongside the public release notes; short, plain sentences.
enum WhatsNew {
    static let version="1.3.1"
    static let items:[(symbol:String, title:String, detail:String)]=[
        ("macwindow","Better Battle.net window sizing",
         "Fixed a compatibility issue that made the Battle.net window too small on Mac displays, so it’s now easier to read and use."),
        ("bolt","Optimized shader preparation",
         "Recall now prepares shaders after you quit Overwatch instead of when you press Play, so launches are faster and new shaders keep being added as you play."),
    ]
}
