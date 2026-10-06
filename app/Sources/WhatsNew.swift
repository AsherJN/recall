// Shown once after an update and from the Help menu, offline. Edit for each
// release alongside the public release notes; short, plain sentences.
enum WhatsNew {
    static let version="1.2"
    static let items:[(symbol:String, title:String, detail:String)]=[
        ("gamecontroller","Xbox controllers",
         "Xbox controllers now work in Overwatch, alongside PlayStation ones."),
        ("display","Scaled monitor check",
         "Settings now tells you when macOS is resizing your monitor, and which setting fixes it."),
    ]
}
