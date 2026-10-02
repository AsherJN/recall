// Shown once after an update and from the Help menu, offline. Edit for each
// release alongside the public release notes; short, plain sentences.
enum WhatsNew {
    static let version="1.0"
    static let items:[(symbol:String, title:String, detail:String)]=[
        ("sparkles","Overwatch 2 Mac is now Recall",
         "Same app, new name and icon. Your game and settings are kept."),
        ("gauge.with.dots.needle.67percent","Lower latency, fewer hitches",
         "Frames reach your screen sooner, and the regular freezes during matches are gone."),
        ("display","Any display, up to 4K",
         "Choose 1080p, 1440p or 4K in Settings, shaped for your MacBook or for a monitor or TV."),
        ("arrow.down.circle","Updates itself",
         "Recall checks for new versions when it opens and installs them for you."),
    ]
}
