// Shown once after an update and from the Help menu, offline. Edit for each
// release alongside the public release notes; short, plain sentences.
enum WhatsNew {
    static let version="1.4.0"
    static let items:[(symbol:String, title:String, detail:String)]=[
        ("square.stack.3d.up","Better shader caching",
         "Recall now compiles and loads shaders more efficiently, and uses your Mac’s memory to keep them ready when Overwatch starts. Expect fewer stutters on new maps and in big fights."),
        ("memorychip","Shader memory",
         "Choose how much of your shader cache Overwatch loads in Settings › Graphics. Handy on Macs with 8 GB of memory."),
        ("bubble.left.and.bubble.right","Recall Discord",
         "Join the Recall Discord from the main window to get help, compare setups, and find other Mac Overwatch players."),
        ("questionmark.circle","Help in tabs",
         "Help & FAQ now has FAQ, Troubleshooting and Support tabs, with step-by-step fixes and buttons that open the right setting."),
    ]
}

