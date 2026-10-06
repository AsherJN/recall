import SwiftUI
import AppKit

// Shared visual vocabulary. The system font (SF Pro) needs no bundled font or
// download and matches the menus, sheets and alerts macOS draws.
enum LauncherStyle {
    static let accent=Color(red:1,green:0.62,blue:0.10)
    static let ink=Color(red:0.15,green:0.13,blue:0.10)
    static let contentWidth:CGFloat=440
    static let radius:CGFloat=22
    static func font(_ size:CGFloat, _ weight:Font.Weight = .regular) -> Font {
        .system(size:size,weight:weight)
    }
    static func ground(_ scheme:ColorScheme) -> Color {
        scheme == .dark ? Color(red:0.09,green:0.095,blue:0.105) : Color(red:0.975,green:0.970,blue:0.958)
    }
    static func surface(_ scheme:ColorScheme) -> Color {
        scheme == .dark ? Color(red:0.14,green:0.145,blue:0.16) : .white
    }
}
struct LauncherBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body:some View {
        LauncherStyle.ground(scheme)
            .overlay(alignment:.top) {
                if !reduceTransparency {
                    RadialGradient(colors:[LauncherStyle.accent.opacity(scheme == .dark ? 0.10 : 0.13),.clear],center:.center,startRadius:10,endRadius:240)
                        .frame(width:520,height:420).offset(y:-90)
                }
            }
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct AppArtwork: View {
    var size:CGFloat=128
    var badge:String?
    private var artwork:NSImage {
        Bundle.main.url(forResource:"AppIcon",withExtension:"icns").flatMap { NSImage(contentsOf:$0) }
            ?? NSImage(named:NSImage.applicationIconName) ?? NSImage()
    }
    var body:some View {
        Image(nsImage:artwork).resizable().interpolation(.high).frame(width:size,height:size)
            .overlay(alignment:.bottomTrailing) {
                if let badge {
                    Image(systemName:badge).font(.system(size:22,weight:.semibold))
                        .foregroundStyle(LauncherStyle.ink).frame(width:44,height:44)
                        .background(LauncherStyle.accent,in:Circle()).offset(x:8,y:4)
                }
            }.accessibilityHidden(true)
    }
}
struct LauncherHeading: View {
    let title:String
    let subtitle:String
    var compact=false
    var body:some View {
        VStack(spacing:12) {
            Text(title).font(LauncherStyle.font(compact ? 28 : 36,.bold))
                .tracking(-0.8).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).font(LauncherStyle.font(16)).lineSpacing(3).foregroundStyle(.secondary)
            }
        }.multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
    }
}
struct LauncherPanel<Content:View>: View {
    @Environment(\.colorScheme) private var scheme
    var inset:CGFloat=20
    @ViewBuilder let content:Content
    var body:some View {
        content.padding(inset).frame(maxWidth:.infinity,alignment:.leading)
            .background(LauncherStyle.surface(scheme),in:RoundedRectangle(cornerRadius:LauncherStyle.radius,style:.continuous))
            .overlay { RoundedRectangle(cornerRadius:LauncherStyle.radius,style:.continuous).strokeBorder(.primary.opacity(0.05),lineWidth:1) }
    }
}
struct LauncherPrimaryAction: View {
    let title:String
    let action:()->Void
    var body:some View {
        Button(action:action) { Text(title).font(LauncherStyle.font(15,.semibold)) }
            .buttonStyle(LauncherActionStyle())
    }
}
/// "Open Battle.net" in Battle.net's own blue, with its icon, so it is clear where it leads.
/// The icon comes from the player's installed Battle.net.exe (BattleNetIcon); until it has
/// loaded, or if it cannot be read, the button shows the title alone.
struct BattleNetAction: View {
    static let blue=Color(red:0,green:0.455,blue:0.878)  // #0074E0, white text 4.6:1
    let title:String
    let executable:URL
    let action:()->Void
    @State private var icon:NSImage?
    var body:some View {
        Button(action:action) {
            HStack(spacing:9) {
                if let icon {
                    Image(nsImage:icon).resizable().interpolation(.high).frame(width:22,height:22)
                        .padding(1.5).background(Circle().fill(.white)).accessibilityHidden(true)
                }
                Text(title).font(LauncherStyle.font(15,.semibold))
            }
        }.buttonStyle(LauncherActionStyle(fill:Self.blue,text:.white))
        .task(id:executable) { icon=await Self.cachedIcon(executable) }
    }
    @MainActor private static var cache:[URL:NSImage]=[:]
    @MainActor private static func cachedIcon(_ url:URL) async -> NSImage? {
        if let hit=cache[url] { return hit }
        let image=await Task.detached(priority:.utility) { BattleNetIcon.load(from:url) }.value
        if let image { cache[url]=image }
        return image
    }
}
/// Stops what the launcher is doing (the launching screen's Cancel).
struct LauncherCancelAction: View {
    let title:String
    let action:()->Void
    var body:some View {
        Button(action:action) { Text(title).font(LauncherStyle.font(15,.semibold)) }
            .buttonStyle(LauncherActionStyle(fill:Color(red:0.85,green:0.18,blue:0.16),text:.white))
    }
}
private struct LauncherActionStyle: ButtonStyle {
    var fill=LauncherStyle.accent
    var text=LauncherStyle.ink
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration)->some View {
        configuration.label.frame(minWidth:200,minHeight:46).padding(.horizontal,16)
            .foregroundStyle(enabled ? text : Color.secondary)
            .background(enabled ? fill : Color.secondary.opacity(0.12),in:Capsule())
            .contentShape(Capsule())
            .overlay { Capsule().strokeBorder(focused ? Color.primary.opacity(0.8) : .clear,lineWidth:2).padding(3) }
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration:0.16),value:configuration.isPressed)
    }
}
struct LauncherNotice: View {
    let text:String
    var symbol="info.circle"
    /// A button under the text that does what it asks.
    var action:(title:String, run:()->Void)?=nil
    var body:some View {
        Label {
            VStack(alignment:.leading,spacing:12) {
                Text(text).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                if let action {
                    Button(action.title,action:action.run).buttonStyle(.bordered).buttonBorderShape(.capsule).foregroundStyle(.primary)
                }
            }
        } icon: { Image(systemName:symbol) }
            .font(LauncherStyle.font(13)).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(LauncherStyle.accent.opacity(0.09),in:RoundedRectangle(cornerRadius:16,style:.continuous))
    }
}
struct SheetHero: View {
    let symbol:String
    let title:String
    let subtitle:String
    var body:some View {
        VStack(spacing:20) {
            Image(systemName:symbol).font(.system(size:28,weight:.medium))
                .foregroundStyle(.primary).frame(width:64,height:64)
                .background(LauncherStyle.accent.opacity(0.14),in:RoundedRectangle(cornerRadius:20,style:.continuous))
                .accessibilityHidden(true)
            LauncherHeading(title:title,subtitle:subtitle,compact:true)
        }
    }
}
