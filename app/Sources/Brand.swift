import Foundation

// The product's public identity in one place: name, tagline, project links,
// update feed and release file name. Renaming the app or moving its repository
// changes only this file and the build scripts' APP_NAME. The bundle identifier
// (org.overwatch2mac.launcher) and the data folder (Overwatch2Mac) are internal
// and keep their original values, so installations and updates carry over.
enum Brand {
    static let name="Recall"
    static var tagline:String { L("Making Overwatch playable on Apple Silicon.") }
    static let repositoryPath="AsherJN/recall"
    static let repository=URL(string:"https://github.com/\(repositoryPath)")!
    static let releases=URL(string:"https://github.com/\(repositoryPath)/releases")!
    static let issues=URL(string:"https://github.com/\(repositoryPath)/issues/new/choose")!
    /// GitHub's latest-release API for the repository. GitHub redirects a
    /// renamed repository, and the updater accepts any release disk image named
    /// "<anything>-<version>.dmg", so a later rename cannot strand an install.
    static let releaseFeed=URL(string:"https://api.github.com/repos/\(repositoryPath)/releases/latest")!
    static func diskImage(_ version:String)->String { "\(name)-\(version).dmg" }
    /// The community server's permanent invite (unlimited uses); it lands in #start-here.
    /// Opens in the browser, which hands it to the Discord app when one is installed.
    static let discord=URL(string:"https://discord.gg/pexasKezCn")!
    static var trademarks:String { L("Not affiliated with or endorsed by Blizzard Entertainment or Apple. Overwatch is a trademark of Blizzard Entertainment, Inc. Mac is a trademark of Apple Inc.") }

    // The author's links. Mosaic News opens on the App Store, where every Mac that runs
    // Recall can install it. Each placement keeps its own call, so App Store Connect
    // campaign links (pt and ct) can tell them apart once a provider token is added.
    static let linkedIn=URL(string:"https://www.linkedin.com/in/asherjn/")!
    static let koFi=URL(string:"https://ko-fi.com/asherjn")!
    enum Placement: String { case home, running, loading, about }
    static func mosaic(_ placement:Placement)->URL {
        URL(string:"https://apps.apple.com/us/app/mosaic-news-build-your-news/id6760421352")!
    }
}
