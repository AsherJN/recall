import Foundation

// The product's public identity in one place: name, tagline, project links,
// update feed and release file name. Renaming the app or moving its repository
// changes only this file and the build scripts' APP_NAME. The bundle identifier
// (org.overwatch2mac.launcher) and the data folder (Overwatch2Mac) are internal
// and keep their original values, so installations and updates carry over.
enum Brand {
    static let name="Recall"
    static let tagline="Making Overwatch playable on Apple Silicon."
    static let repositoryPath="AsherJN/recall"
    static let repository=URL(string:"https://github.com/\(repositoryPath)")!
    static let releases=URL(string:"https://github.com/\(repositoryPath)/releases")!
    static let issues=URL(string:"https://github.com/\(repositoryPath)/issues/new/choose")!
    /// GitHub's latest-release API for the repository. GitHub redirects a
    /// renamed repository, and the updater accepts any release disk image named
    /// "<anything>-<version>.dmg", so a later rename cannot strand an install.
    static let releaseFeed=URL(string:"https://api.github.com/repos/\(repositoryPath)/releases/latest")!
    static func diskImage(_ version:String)->String { "\(name)-\(version).dmg" }
    /// The "Share how it runs on your Mac" issue form with the macOS and app versions filled in.
    static func howItRuns(macOS:String, version:String)->URL {
        var link=URLComponents(string:"https://github.com/\(repositoryPath)/issues/new")!
        link.queryItems=[URLQueryItem(name:"template",value:"performance_report.yml"),URLQueryItem(name:"title",value:"How it runs: \(macOS)"),
                         URLQueryItem(name:"macos",value:macOS),URLQueryItem(name:"version",value:version)]
        return link.url!
    }
    static let trademarks="Not affiliated with or endorsed by Blizzard Entertainment or Apple. Overwatch is a trademark of Blizzard Entertainment, Inc. Mac is a trademark of Apple Inc."

    // The author's links. Mosaic News links say where in the app they were
    // opened (utm_content), so its analytics can tell the placements apart.
    static let linkedIn=URL(string:"https://www.linkedin.com/in/asherjn/")!
    static let koFi=URL(string:"https://ko-fi.com/asherjn")!
    enum Placement: String { case home, running, loading, about }
    static func mosaic(_ placement:Placement)->URL {
        var link=URLComponents(string:"https://mosaicnews.app/")!
        link.queryItems=[URLQueryItem(name:"utm_source",value:"recall"),URLQueryItem(name:"utm_medium",value:"app"),
                         URLQueryItem(name:"utm_campaign",value:"support"),URLQueryItem(name:"utm_content",value:placement.rawValue)]
        return link.url!
    }
}
