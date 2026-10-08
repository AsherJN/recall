// Shown once after an update and from the Help menu, offline. Edit for each
// release alongside the public release notes; short, plain sentences.
enum WhatsNew {
    static let version="1.3"
    static let items:[(symbol:String, title:String, detail:String)]=[
        ("speedometer","MetalFX upscaling",
         "Turn it on in Settings › Graphics, then pick NVIDIA DLSS in Overwatch’s Video settings. Quality looks closest to full resolution; Performance and Ultra Performance give the most FPS."),
        ("mic","Voice chat",
         "Your microphone now works in Overwatch voice chat."),
        ("headphones","Better AirPods and Bluetooth audio",
         "Game sound stays high quality while you use voice chat."),
        ("slider.horizontal.3","Redesigned Settings",
         "Easier to find what you’re looking for."),
    ]
}
