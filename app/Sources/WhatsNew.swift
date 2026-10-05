// Shown once after an update and from the Help menu, offline. Edit for each
// release alongside the public release notes; short, plain sentences.
enum WhatsNew {
    static let version="1.1"
    static let items:[(symbol:String, title:String, detail:String)]=[
        ("laptopcomputer","Now on macOS Sequoia",
         "Recall opens on macOS Sequoia 15 as well as Tahoe."),
        ("gamecontroller","Game Mode",
         "Overwatch now runs in macOS Game Mode, with less lag from AirPods and wireless controllers."),
        ("arrow.clockwise","Smoother after restarts and updates",
         "Shaders Recall learned while you played now carry over when your Mac restarts or updates."),
        ("chart.xyaxis.line","Metal Performance HUD",
         "Turn it on in Settings to see FPS, frame times and shader compiles in game."),
        ("square.stack.3d.up","Graphics prep, in detail",
         "Open Details while Recall prepares graphics to watch each shader get ready."),
        ("display","Ultrawide and 5K monitors",
         "Pick any resolution in Overwatch’s Video settings. Recall remembers it for each display, so your MacBook and monitor keep their own."),
    ]
}
