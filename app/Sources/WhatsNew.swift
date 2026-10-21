// Shown once after an update and from the Help menu, offline. Edit for each
// release alongside the public release notes; short, plain sentences.
enum WhatsNew {
    static let version="1.5.0"
    static var items:[(symbol:String, title:String, detail:String)] { [
        ("globe.asia.australia",L("China’s Battle.net"),
         L("Recall can install China’s Battle.net for NetEase accounts. Choose your Battle.net region and language when you set up, or later in Settings › General.")),
        ("character.bubble",L("Simplified Chinese and Korean"),
         L("Recall’s interface is available in Simplified Chinese and Korean, and follows your Mac’s language.")),
        ("cursorarrow.motionlines",L("High-precision mouse input"),
         L("Clicks and movement are delivered to Overwatch together, for more precise aim.")),
        ("hand.point.up.left",L("Trackpad support"),
         L("Aim with a MacBook trackpad or Magic Trackpad in matches.")),
        ("magnifyingglass",L("Help & FAQ search"),
         L("Search all of Help’s answers from one field.")),
        ("gauge.with.dots.needle.33percent",L("Shader cache"),
         L("Updated the shader cache UI.")),
        ("app.badge",L("Performance check"),
         L("Before you play, Recall shows apps using enough of your Mac to lower FPS, each with a Quit button, and notes Low Power Mode, overheating and low memory.")),
        ("doc.zipper",L("Save and share logs"),
         L("Save Recall’s, Battle.net’s and Overwatch’s logs as one file to share when you report a problem, from Help & FAQ › Support. Detailed logging is in Settings › Advanced.")),
        ("eraser",L("Clear Shader Cache"),
         L("If Overwatch crashes or shows graphics glitches, clear its shaders in Settings › Graphics. Recall rebuilds them as you play.")),
        ("wrench.and.screwdriver",L("Fixes"),
         L("Fixed the Battle.net update issue and camera control after switching apps. Left Option now works as Alt in Overwatch, and the support report shows MetalFX upscaling correctly.")),
    ] }
}

