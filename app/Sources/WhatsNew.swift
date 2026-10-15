// Shown once after an update and from the Help menu, offline. Edit for each
// release alongside the public release notes; short, plain sentences.
enum WhatsNew {
    static let version="1.4.1"
    static var items:[(symbol:String, title:String, detail:String)] { [
        ("globe.asia.australia",L("China’s Battle.net"),
         L("Recall can set up China’s Battle.net (国服) for NetEase accounts. Choose it when you set up, or later in Settings › General.")),
        ("character.bubble",L("Recall in Simplified Chinese"),
         L("Recall follows your Mac’s language and is now available in Simplified Chinese.")),
        ("translate",L("Battle.net in your language"),
         L("When you set up, choose English, Simplified Chinese or Korean for Battle.net. Recall adds the fonts Chinese and Korean text needs.")),
    ] }
}

