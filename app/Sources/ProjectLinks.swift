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
        }.buttonStyle(.plain).environment(\.colorScheme,.light).accessibilityLabel("\(Brand.name) on GitHub")
            .help("Open the project repository in your browser")
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
                Text("Try").font(LauncherStyle.font(13,.semibold))
                Image(nsImage:ProjectArtwork.mosaic).renderingMode(.original).resizable().scaledToFit()
                    .frame(width:100,height:19).accessibilityHidden(true)
                Image(systemName:"arrow.up.right").font(.system(size:9,weight:.semibold)).accessibilityHidden(true)
            }.foregroundStyle(.white).padding(.horizontal,16).frame(height:38)
                .background(.black,in:Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.18),lineWidth:1) }
                .contentShape(Capsule())
        }.buttonStyle(.plain).environment(\.colorScheme,.light)
            .accessibilityLabel("Try Mosaic News, free").help("Open Mosaic News in your browser. It’s free; no account needed.")
    }
}
struct CoffeeButton:View {
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        Link(destination:Brand.koFi) {
            HStack(spacing:7) {
                Image(systemName:"cup.and.saucer.fill").font(.system(size:13,weight:.semibold)).foregroundStyle(LauncherStyle.accent)
                    .accessibilityHidden(true)
                Text("Buy me a coffee").font(LauncherStyle.font(13,.semibold))
                Image(systemName:"arrow.up.right").font(.system(size:9,weight:.semibold)).accessibilityHidden(true)
            }.foregroundStyle(.primary).padding(.horizontal,16).frame(height:38)
                .background(LauncherStyle.surface(scheme),in:Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.14),lineWidth:1) }
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel("Buy me a coffee on Ko-fi").help("Open Josh’s Ko-fi page in your browser")
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
                Text("Joshua Nelson").font(LauncherStyle.font(13,.medium))
                Image(systemName:"arrow.up.right").font(.system(size:8,weight:.medium)).accessibilityHidden(true)
            }.foregroundStyle(blue).padding(.horizontal,10).frame(height:28)
                .background(blue.opacity(0.10),in:Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel("Joshua Nelson on LinkedIn")
            .help("Open Joshua Nelson’s LinkedIn profile in your browser")
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
                Text("Hey there! I’m Josh, the creator of \(Brand.name). If you’re enjoying it and want to support my continued work, here are two ways to help :)")
                    .font(LauncherStyle.font(13)).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            }
            HStack(spacing:10) {
                MosaicButton(placement:placement)
                CoffeeButton()
            }
            Text("Mosaic News is another free project of mine: a news app designed to be the most transparent, customizable, and privacy-focused way to follow the news, aggregating reporting from 850+ publishers across the political spectrum to help readers “see the whole picture.”")
                .font(LauncherStyle.font(12)).lineSpacing(2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(LauncherStyle.surface(scheme),in:RoundedRectangle(cornerRadius:LauncherStyle.radius,style:.continuous))
            .overlay { RoundedRectangle(cornerRadius:LauncherStyle.radius,style:.continuous).strokeBorder(.primary.opacity(0.06),lineWidth:1) }
            .accessibilityElement(children:.contain).accessibilityLabel("Support \(Brand.name)")
    }
}
