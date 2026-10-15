import SwiftUI
import AppKit

// Offline vector from GitHub's official favicon. See GITHUB-MARK-NOTICE.txt.
private struct GitHubMark:Shape {
    func path(in rect:CGRect)->Path {
        var p=Path()
        p.move(to:CGPoint(x:16,y:0))
        p.addCurve(to:CGPoint(x:0,y:16),control1:CGPoint(x:7.16,y:0),control2:CGPoint(x:0,y:7.16))
        p.addCurve(to:CGPoint(x:10.94,y:31.18),control1:CGPoint(x:0,y:23.08),control2:CGPoint(x:4.58,y:29.06))
        p.addCurve(to:CGPoint(x:12.04,y:30.42),control1:CGPoint(x:11.74,y:31.32),control2:CGPoint(x:12.04,y:30.84))
        p.addCurve(to:CGPoint(x:12.02,y:27.44),control1:CGPoint(x:12.04,y:30.04),control2:CGPoint(x:12.02,y:28.78))
        p.addCurve(to:CGPoint(x:6.64,y:25.56),control1:CGPoint(x:8,y:28.18),control2:CGPoint(x:6.96,y:26.46))
        p.addCurve(to:CGPoint(x:5,y:23.3),control1:CGPoint(x:6.46,y:25.1),control2:CGPoint(x:5.68,y:23.68))
        p.addCurve(to:CGPoint(x:4.98,y:22.24),control1:CGPoint(x:4.44,y:23),control2:CGPoint(x:3.64,y:22.26))
        p.addCurve(to:CGPoint(x:7.44,y:23.88),control1:CGPoint(x:6.24,y:22.22),control2:CGPoint(x:7.14,y:23.4))
        p.addCurve(to:CGPoint(x:12.1,y:25.2),control1:CGPoint(x:8.88,y:26.3),control2:CGPoint(x:11.18,y:25.62))
        p.addCurve(to:CGPoint(x:13.12,y:23.06),control1:CGPoint(x:12.24,y:24.16),control2:CGPoint(x:12.66,y:23.46))
        p.addCurve(to:CGPoint(x:5.84,y:15.16),control1:CGPoint(x:9.56,y:22.66),control2:CGPoint(x:5.84,y:21.28))
        p.addCurve(to:CGPoint(x:7.48,y:10.86),control1:CGPoint(x:5.84,y:13.42),control2:CGPoint(x:6.46,y:11.98))
        p.addCurve(to:CGPoint(x:7.64,y:6.62),control1:CGPoint(x:7.32,y:10.46),control2:CGPoint(x:6.76,y:8.82))
        p.addCurve(to:CGPoint(x:12.04,y:8.26),control1:CGPoint(x:7.64,y:6.62),control2:CGPoint(x:8.98,y:6.2))
        p.addCurve(to:CGPoint(x:16.04,y:7.72),control1:CGPoint(x:13.32,y:7.9),control2:CGPoint(x:14.68,y:7.72))
        p.addCurve(to:CGPoint(x:20.04,y:8.26),control1:CGPoint(x:17.4,y:7.72),control2:CGPoint(x:18.76,y:7.9))
        p.addCurve(to:CGPoint(x:24.44,y:6.62),control1:CGPoint(x:23.1,y:6.18),control2:CGPoint(x:24.44,y:6.62))
        p.addCurve(to:CGPoint(x:24.6,y:10.86),control1:CGPoint(x:25.32,y:8.82),control2:CGPoint(x:24.76,y:10.46))
        p.addCurve(to:CGPoint(x:26.24,y:15.16),control1:CGPoint(x:25.62,y:11.98),control2:CGPoint(x:26.24,y:13.4))
        p.addCurve(to:CGPoint(x:18.94,y:23.06),control1:CGPoint(x:26.24,y:21.3),control2:CGPoint(x:22.5,y:22.66))
        p.addCurve(to:CGPoint(x:20.02,y:26.02),control1:CGPoint(x:19.52,y:23.56),control2:CGPoint(x:20.02,y:24.52))
        p.addCurve(to:CGPoint(x:20,y:30.42),control1:CGPoint(x:20.02,y:28.16),control2:CGPoint(x:20,y:29.88))
        p.addCurve(to:CGPoint(x:21.1,y:31.18),control1:CGPoint(x:20,y:30.84),control2:CGPoint(x:20.3,y:31.34))
        p.addCurve(to:CGPoint(x:32,y:16),control1:CGPoint(x:27.42,y:29.06),control2:CGPoint(x:32,y:23.06))
        p.addCurve(to:CGPoint(x:16,y:0),control1:CGPoint(x:32,y:7.16),control2:CGPoint(x:24.84,y:0))
        p.addLine(to:CGPoint(x:p.currentPoint!.x,y:0))
        p.closeSubpath()
        let scale=min(rect.width,rect.height)/32
        return p.applying(CGAffineTransform(scaleX:scale,y:scale))
    }
}
struct RepositoryLink:View {
    var compact=false
    var body:some View {
        Link(destination:Brand.repository) {
            HStack(spacing:10) {
                GitHubMark().fill(.white).frame(width:20,height:20).accessibilityHidden(true)
                Text(Brand.repositoryPath).font(LauncherStyle.font(14,.semibold))
                Image(systemName:"arrow.up.right").font(.system(size:11,weight:.semibold)).accessibilityHidden(true)
            }.foregroundStyle(.white).padding(.horizontal,compact ? 16 : 0)
                .frame(maxWidth:compact ? nil : .infinity,minHeight:compact ? 38 : 46)
                .background(.black,in:Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.18),lineWidth:1) }
                .contentShape(Capsule())
        }.buttonStyle(.plain).environment(\.colorScheme,.light).accessibilityLabel(L("{0} on GitHub",Brand.name))
            .help(L("Open the project repository in your browser"))
    }
}

// Offline vector from the Discord symbol on Discord's brand page. See PROJECT-LINKS-NOTICE.txt.
private struct DiscordMark:Shape {
    func path(in rect:CGRect)->Path {
        var p=Path()
        p.move(to:CGPoint(x:37.1937,y:0))
        p.addCurve(to:CGPoint(x:35.6541,y:3.1139),control1:CGPoint(x:36.6265,y:1.0071),control2:CGPoint(x:36.1172,y:2.0489))
        p.addCurve(to:CGPoint(x:22.365,y:3.1139),control1:CGPoint(x:31.2553,y:2.4541),control2:CGPoint(x:26.7754,y:2.4541))
        p.addCurve(to:CGPoint(x:20.8254,y:0),control1:CGPoint(x:21.9136,y:2.0489),control2:CGPoint(x:21.3926,y:1.0071))
        p.addCurve(to:CGPoint(x:8.8444,y:3.6927),control1:CGPoint(x:16.6928,y:0.7061),control2:CGPoint(x:12.6644,y:1.9447))
        p.addCurve(to:CGPoint(x:0.2435,y:36.6146),control1:CGPoint(x:1.2737,y:14.9098),control2:CGPoint(x:-0.7752,y:25.8374))
        p.addCurve(to:CGPoint(x:14.9333,y:43.9884),control1:CGPoint(x:4.677,y:39.8906),control2:CGPoint(x:9.6431,y:42.391))
        p.addCurve(to:CGPoint(x:18.0819,y:38.9182),control1:CGPoint(x:16.1256,y:42.391),control2:CGPoint(x:17.179,y:40.6893))
        p.addCurve(to:CGPoint(x:13.1274,y:36.5567),control1:CGPoint(x:16.3687,y:38.2815),control2:CGPoint(x:14.7133,y:37.4828))
        p.addCurve(to:CGPoint(x:14.3429,y:35.6422),control1:CGPoint(x:13.5442,y:36.2557),control2:CGPoint(x:13.9493,y:35.9432))
        p.addCurve(to:CGPoint(x:43.711,y:35.6422),control1:CGPoint(x:23.6384,y:40.0179),control2:CGPoint(x:34.4039,y:40.0179))
        p.addCurve(to:CGPoint(x:44.9264,y:36.5567),control1:CGPoint(x:44.1046,y:35.9663),control2:CGPoint(x:44.5097,y:36.2789))
        p.addCurve(to:CGPoint(x:39.9604,y:38.9298),control1:CGPoint(x:43.3405,y:37.4943),control2:CGPoint(x:41.6852,y:38.2815))
        p.addCurve(to:CGPoint(x:43.109,y:44),control1:CGPoint(x:40.8633,y:40.7009),control2:CGPoint(x:41.9167,y:42.4025))
        p.addCurve(to:CGPoint(x:57.7988,y:36.6377),control1:CGPoint(x:48.3992,y:42.4025),control2:CGPoint(x:53.3653,y:39.9137))
        p.addCurve(to:CGPoint(x:49.1748,y:3.7043),control1:CGPoint(x:59.0027,y:24.1358),control2:CGPoint(x:55.7383,y:13.3007))
        p.addCurve(to:CGPoint(x:37.2053,y:0.0232),control1:CGPoint(x:45.3663,y:1.9563),control2:CGPoint(x:41.3379,y:0.7177))
        p.addLine(to:CGPoint(x:37.1937,y:0))
        p.closeSubpath()
        p.move(to:CGPoint(x:19.3784,y:29.9816))
        p.addCurve(to:CGPoint(x:14.1461,y:24.1821),control1:CGPoint(x:16.5192,y:29.9816),control2:CGPoint(x:14.1461,y:27.3886))
        p.addCurve(to:CGPoint(x:19.3669,y:18.371),control1:CGPoint(x:14.1461,y:20.9755),control2:CGPoint(x:16.4266,y:18.371))
        p.addCurve(to:CGPoint(x:24.5992,y:24.1821),control1:CGPoint(x:22.3071,y:18.371),control2:CGPoint(x:24.6455,y:20.9871))
        p.addCurve(to:CGPoint(x:19.3784,y:29.9816),control1:CGPoint(x:24.5529,y:27.377),control2:CGPoint(x:22.2956,y:29.9816))
        p.closeSubpath()
        p.move(to:CGPoint(x:38.6639,y:29.9816))
        p.addCurve(to:CGPoint(x:33.4431,y:24.1821),control1:CGPoint(x:35.7931,y:29.9816),control2:CGPoint(x:33.4431,y:27.3886))
        p.addCurve(to:CGPoint(x:38.6639,y:18.371),control1:CGPoint(x:33.4431,y:20.9755),control2:CGPoint(x:35.7236,y:18.371))
        p.addCurve(to:CGPoint(x:43.8846,y:24.1821),control1:CGPoint(x:41.6042,y:18.371),control2:CGPoint(x:43.9309,y:20.9871))
        p.addCurve(to:CGPoint(x:38.6639,y:29.9816),control1:CGPoint(x:43.8383,y:27.377),control2:CGPoint(x:41.581,y:29.9816))
        p.closeSubpath()
        let scale=min(rect.width/59,rect.height/44)
        return p.applying(CGAffineTransform(scaleX:scale,y:scale))
    }
}
/// The community server, in Discord's own blurple with its mark, so it is clear where it
/// leads. On every main-window screen, above the support card; a link, never a pop-up.
struct DiscordLink:View {
    static let blurple=Color(red:0x58/255,green:0x65/255,blue:0xF2/255)  // #5865F2, Discord's brand colour; white text 4.6:1
    static let hover=Color(red:0x47/255,green:0x52/255,blue:0xC4/255)  // #4752C4, Discord's own hover shade
    @Environment(\.openURL) private var openURL
    var body:some View {
        Button { openURL(Brand.discord) } label: {
            HStack(spacing:14) {
                DiscordMark().fill(.white).frame(width:30,height:23).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:3) {
                    Text(L("Join the {0} Discord",Brand.name)).font(LauncherStyle.font(15,.semibold))
                    Text(L("Get help, compare setups, and find other Mac Overwatch players."))
                        .font(LauncherStyle.font(12)).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
                Image(systemName:"arrow.up.right").font(.system(size:12,weight:.semibold)).accessibilityHidden(true)
            }.foregroundStyle(.white).multilineTextAlignment(.leading)
                .padding(.horizontal,18).padding(.vertical,13).frame(maxWidth:.infinity,minHeight:60,alignment:.leading)
        }.buttonStyle(DiscordLinkStyle())
            .accessibilityLabel(L("Join the {0} Discord",Brand.name)).accessibilityHint(L("Opens the invite in your browser"))
            .help(L("Open the {0} Discord invite in your browser",Brand.name))
    }
}
/// Help's footer, beside Report a Problem: questions go to the community, bugs to GitHub.
struct DiscordHelpLink:View {
    var body:some View {
        Link(destination:Brand.discord) {
            Label {
                Text(L("Ask on Discord")).font(LauncherStyle.font(13,.medium))
            } icon: {
                DiscordMark().fill(DiscordLink.blurple).frame(width:17,height:13).accessibilityHidden(true)
            }
        }.buttonStyle(.borderless).help(L("Open the {0} Discord invite in your browser",Brand.name))
    }
}
/// In place of the Discord card for players who chose China's Battle.net (AppModel.showsDiscord):
/// Discord is blocked in mainland China, so questions go to GitHub (owner, October 15). Same
/// place and size as the Discord card, in Recall's own colours.
struct GitHubHelpLink:View {
    @Environment(\.openURL) private var openURL
    var body:some View {
        Button { openURL(Brand.issues) } label: {
            HStack(spacing:14) {
                Image(systemName:"bubble.left.and.text.bubble.right").font(.system(size:19,weight:.medium))
                    .foregroundStyle(LauncherStyle.accent).frame(width:30).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:3) {
                    Text(L("Questions? Ask on GitHub")).font(LauncherStyle.font(15,.semibold))
                    Text(L("Get help, report a problem or suggest an idea."))
                        .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
                Image(systemName:"arrow.up.right").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }.foregroundStyle(.primary).multilineTextAlignment(.leading)
                .padding(.horizontal,18).padding(.vertical,13).frame(maxWidth:.infinity,minHeight:60,alignment:.leading)
        }.buttonStyle(GitHubLinkStyle())
            .accessibilityLabel(L("Questions? Ask on GitHub")).accessibilityHint(L("Opens GitHub in your browser"))
            .help(L("Open a new issue on GitHub in your browser"))
    }
}
private struct GitHubLinkStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View { GitHubLinkBody(configuration:configuration) }
}
private struct GitHubLinkBody:View {
    let configuration:ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    @State private var hovering=false
    var body:some View {
        let shape=RoundedRectangle(cornerRadius:16,style:.continuous)
        configuration.label
            .background(LauncherStyle.surface(scheme).opacity(hovering ? 1 : 0.72),in:shape)
            .overlay { shape.strokeBorder(focused ? Color.primary.opacity(0.8) : .primary.opacity(0.08),lineWidth:focused ? 2 : 1) }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { hovering=$0 }
    }
}
private struct DiscordLinkStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View { DiscordLinkBody(configuration:configuration) }
}
private struct DiscordLinkBody:View {
    let configuration:ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @State private var hovering=false
    var body:some View {
        let shape=RoundedRectangle(cornerRadius:16,style:.continuous)
        configuration.label
            .background(hovering ? DiscordLink.hover : DiscordLink.blurple,in:shape)
            .overlay { shape.strokeBorder(focused ? Color.primary.opacity(0.8) : .white.opacity(0.18),lineWidth:focused ? 2 : 1) }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { hovering=$0 }
    }
}
// Loaded once, offline; progress timer updates never decode these assets again.
private enum ProjectArtwork {
    static let mosaic=load("MosaicLogo","png")
    static let linkedIn=load("LinkedInMark","png")
    static let author=load("AuthorPhoto","jpg")
    static let wordmark=load("Wordmark","png")
    static let wordmarkDark=load("WordmarkDark","png")
    private static func load(_ name:String,_ type:String)->NSImage {
        Bundle.main.url(forResource:name,withExtension:type).flatMap { NSImage(contentsOf:$0) } ?? NSImage()
    }
}
/// The Recall lockup (mark and name) in the owner's light- and dark-appearance
/// versions; the mark is the square at its leading edge. A badge marks a state, as
/// on the app icon (a failure, a paused setup, a missing drive).
struct Wordmark:View {
    var height:CGFloat
    var badge:String?
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        Image(nsImage:scheme == .dark ? ProjectArtwork.wordmarkDark : ProjectArtwork.wordmark)
            .resizable().interpolation(.high).scaledToFit().frame(height:height)
            .overlay(alignment:.leading) {
                if let badge {
                    Color.clear.frame(width:height,height:height).overlay(alignment:.bottomTrailing) {
                        Image(systemName:badge).font(.system(size:height*0.2,weight:.semibold))
                            .foregroundStyle(LauncherStyle.ink).frame(width:height*0.4,height:height*0.4)
                            .background(LauncherStyle.accent,in:Circle())
                            .overlay { Circle().strokeBorder(.background,lineWidth:2) }
                            .offset(x:height*0.08,y:height*0.04)
                    }
                }
            }
            .accessibilityElement().accessibilityLabel(Brand.name).accessibilityAddTraits(.isHeader)
    }
}
struct AuthorPhoto:View {
    var size:CGFloat
    var body:some View {
        Image(nsImage:ProjectArtwork.author).resizable().interpolation(.high).scaledToFill()
            .frame(width:size,height:size).clipShape(Circle())
            .overlay { Circle().strokeBorder(.primary.opacity(0.08),lineWidth:1) }
            .accessibilityHidden(true)
    }
}
struct MosaicButton:View {
    let placement:Brand.Placement
    var body:some View {
        Link(destination:Brand.mosaic(placement)) {
            HStack(spacing:8) {
                Text(L("Get")).font(LauncherStyle.font(13,.semibold))
                Image(nsImage:ProjectArtwork.mosaic).renderingMode(.original).resizable().scaledToFit()
                    .frame(width:100,height:19).accessibilityHidden(true)
                Image(systemName:"arrow.up.right").font(.system(size:9,weight:.semibold)).accessibilityHidden(true)
            }.foregroundStyle(.white).padding(.horizontal,16).frame(height:38)
                .background(.black,in:Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.18),lineWidth:1) }
                .contentShape(Capsule())
        }.buttonStyle(.plain).environment(\.colorScheme,.light)
            .accessibilityLabel(L("Get Mosaic News, free on the App Store")).help(L("Open Mosaic News on the App Store. It’s free."))
    }
}
struct CoffeeButton:View {
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        Link(destination:Brand.koFi) {
            HStack(spacing:7) {
                Image(systemName:"cup.and.saucer.fill").font(.system(size:13,weight:.semibold)).foregroundStyle(LauncherStyle.accent)
                    .accessibilityHidden(true)
                Text(L("Buy me a coffee")).font(LauncherStyle.font(13,.semibold))
                Image(systemName:"arrow.up.right").font(.system(size:9,weight:.semibold)).accessibilityHidden(true)
            }.foregroundStyle(.primary).padding(.horizontal,16).frame(height:38)
                .background(LauncherStyle.surface(scheme),in:Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.14),lineWidth:1) }
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(L("Buy me a coffee on Ko-fi")).help(L("Open Josh’s Ko-fi page in your browser"))
    }
}
struct LinkedInLink:View {
    @Environment(\.colorScheme) private var scheme
    private var blue:Color {
        scheme == .dark ? Color(red:0.51,green:0.73,blue:0.95) : Color(red:0.11,green:0.36,blue:0.61)
    }
    var body:some View {
        Link(destination:Brand.linkedIn) {
            HStack(spacing:6) {
                Image(nsImage:ProjectArtwork.linkedIn).renderingMode(.template).resizable().scaledToFit()
                    .frame(width:17,height:15).accessibilityHidden(true)
                Text(verbatim:"Joshua Nelson").font(LauncherStyle.font(13,.medium))
                Image(systemName:"arrow.up.right").font(.system(size:8,weight:.medium)).accessibilityHidden(true)
            }.foregroundStyle(blue).padding(.horizontal,10).frame(height:28)
                .background(blue.opacity(0.10),in:Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(L("{0} on LinkedIn","Joshua Nelson"))
            .help(L("Open {0}’s LinkedIn profile in your browser","Joshua Nelson"))
    }
}
// Josh's own ask, on the home, running and loading screens once Battle.net has
// opened for the first time. Part of the window, never a pop-up.
struct SupportCard:View {
    let placement:Brand.Placement
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.top,spacing:12) {
                AuthorPhoto(size:40)
                Text(L("Hey there! I’m Josh, the creator of {0}. If you’re enjoying it, you can support my work by trying Mosaic News, my free news app, or buying me a coffee :)",Brand.name))
                    .font(LauncherStyle.font(13)).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            }
            HStack(spacing:10) {
                MosaicButton(placement:placement)
                CoffeeButton()
            }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(LauncherStyle.surface(scheme),in:RoundedRectangle(cornerRadius:LauncherStyle.radius,style:.continuous))
            .overlay { RoundedRectangle(cornerRadius:LauncherStyle.radius,style:.continuous).strokeBorder(.primary.opacity(0.06),lineWidth:1) }
            .accessibilityElement(children:.contain).accessibilityLabel(L("Support {0}",Brand.name))
    }
}
