import AppKit
import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import IOKit
import SwiftUI
import UniformTypeIdentifiers

/// Overwatch's saved highlights (REC-53, REC-96, REC-97).
///
/// The worker points Overwatch's highlights folder at the player's Movies › Overwatch
/// (portable_highlights.h), and the engine saves highlights there as MP4 (winemacmf). The
/// Highlights window lists them, newest first; a click opens one in QuickTime, the Mac's own
/// player, and a clip can be shown in Finder, shared, dragged into Discord or Messages, or moved to
/// the Trash. Recall plays nothing itself.
///
/// The Recall mark is the player's choice, asked once (HighlightMarkSheet): Recall's lockup and
/// "Played on [their Mac] using Recall" above Overwatch's ability and ammo counters. With it on,
/// Recall puts it into each MP4 in the folder once Overwatch has finished saving it, in place, with
/// no extra copy (owner, November 13). WebM can't carry it.
enum HighlightFolder {
    /// Movies › Overwatch, as the worker makes it (highlightsFolder in portable_highlights.h).
    static var url:URL {
        FileManager.default.urls(for:.moviesDirectory,in:.userDomainMask).first!.appendingPathComponent("Overwatch",isDirectory:true)
    }
    /// What Overwatch saves: MP4, or WebM when the player chooses it in the game.
    static let videoExtensions:Set<String>=["mp4","m4v","mov","webm"]
}

/// The player's Mac as the mark names it: its family and its chip, "MacBook Air M2".
enum MacName {
    /// "MacBook Air (13-inch, M2, 2022)" → "MacBook Air"; "Mac mini (2024)" → "Mac mini".
    static func family(fromProductName name:String)->String? {
        let family=name.components(separatedBy:" (").first?.trimmingCharacters(in:.whitespaces) ?? ""
        return family.isEmpty ? nil : family
    }
    /// "MacBook Air" from an older model identifier ("MacBookAir10,1"); newer ones say only "Mac14,2".
    static func family(fromModel model:String)->String? {
        let known=[("MacBookAir","MacBook Air"),("MacBookPro","MacBook Pro"),("Macmini","Mac mini"),("MacPro","Mac Pro"),
                   ("iMac","iMac"),("MacStudio","Mac Studio")]
        return known.first { model.hasPrefix($0.0) }?.1
    }
    /// "Apple M2 Pro" → "M2 Pro"; anything else names no chip.
    static func chip(fromBrand brand:String)->String {
        let trimmed=brand.trimmingCharacters(in:.whitespaces)
        guard trimmed.hasPrefix("Apple ") else { return "" }
        return String(trimmed.dropFirst("Apple ".count))
    }
    static func compose(family:String?,chip:String)->String {
        let family=family ?? "Mac"
        return chip.isEmpty ? family : family+" "+chip
    }
    static let current:String=compose(family:productFamily(),chip:chip(fromBrand:sysctlString("machdep.cpu.brand_string")))

    private static func productFamily()->String? {
        let entry=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,let data=IORegistryEntryCreateCFProperty(entry,"product-name" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? Data {
            let name=String(decoding:data.prefix { $0 != 0 },as:UTF8.self)
            if let family=family(fromProductName:name) { return family }
        }
        return family(fromModel:sysctlString("hw.model"))
    }
    private static func sysctlString(_ name:String)->String {
        var size=0
        guard sysctlbyname(name,nil,&size,nil,0) == 0,size > 0 else { return "" }
        var value=[CChar](repeating:0,count:size)
        guard sysctlbyname(name,&value,&size,nil,0) == 0 else { return "" }
        return String(decoding:value.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)
    }
}

/// The mark on shared highlights: Recall's icon and "Played on MacBook Air M2 using Recall" on a
/// dark, translucent capsule in the top-left corner, sized to the video, where Overwatch's own
/// interface leaves the frame free.
enum HighlightMark {
    static var text:String { L("Played on {0} using {1}",MacName.current,Brand.name) }
    /// The mark's look: 1 was 1.6.4 RC1's small capsule on shared copies; 2 the lockup above the
    /// HUD, washing in, put into the saved MP4 itself.
    static let style=2
    /// A marked file carries this extended attribute (a quick check) and, in the MP4 itself, a
    /// software entry "Recall mark 2" (which travels with the file), so it's never marked twice. Of
    /// the software identifiers, only the common one survives AVAssetExportSession's MP4 (ISO user
    /// data `swre`).
    static let attribute="org.overwatch2mac.mark"
    static var tag:String { "\(Brand.name) mark \(style)" }

    /// Recall's lockup (mark and name) for dark backgrounds, as in the app's dark appearance.
    nonisolated(unsafe) static var logo:CGImage?=Bundle.main.url(forResource:"WordmarkDark",withExtension:"png")
        .flatMap { NSImage(contentsOf:$0) }?.cgImage(forProposedRect:nil,context:nil,hints:nil)

    /// Where the lockup and the line under it go in a frame of SIZE (origin top left): bottom right,
    /// just above Overwatch's ability and ammo counters, the line centred under the lockup. At 1080 the
    /// counters start 908 down and the weapon panel ends 55 from the right edge; the HUD scales with
    /// the picture's height.
    static func layout(size:CGSize,text:String)->(logo:CGRect,text:CGRect,font:NSFont) {
        let unit=size.height/1080
        let right=55*unit,bottom=194*unit,logoHeight=76*unit,gap=8*unit
        let font=NSFont.systemFont(ofSize:26*unit,weight:.semibold)
        let textSize=NSAttributedString(string:text,attributes:[.font:font]).size()
        let logoWidth=logoHeight*(logo.map { CGFloat($0.width)/CGFloat($0.height) } ?? 1045.0/412)
        let centre=size.width-right-max(logoWidth,textSize.width)/2
        let textRect=CGRect(x:centre-textSize.width/2,y:size.height-bottom-textSize.height,width:textSize.width,height:textSize.height)
        return (CGRect(x:centre-logoWidth/2,y:textRect.minY-gap-logoHeight,width:logoWidth,height:logoHeight),textRect,font)
    }

    /// The mark over a transparent frame the video's size: the lockup and the line under it, slightly
    /// see-through, with a soft shadow so both read over bright scenes.
    static func overlay(size:CGSize,text:String)->CIImage? {
        let width=Int(size.width.rounded()),height=Int(size.height.rounded())
        guard width > 0,height > 0,let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let unit=CGFloat(height)/1080
        let place=layout(size:CGSize(width:width,height:height),text:text)
        // The bitmap's origin is its bottom left.
        let bottomUp={ (rect:CGRect) in CGRect(x:rect.minX,y:CGFloat(height)-rect.maxY,width:rect.width,height:rect.height) }
        let previous=NSGraphicsContext.current
        NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
        defer { NSGraphicsContext.current=previous }
        context.setAlpha(0.92)
        context.setShadow(offset:CGSize(width:0,height:-2*unit),blur:9*unit,color:NSColor.black.withAlphaComponent(0.6).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo:nil)
        if let logo {
            context.interpolationQuality = .high
            context.draw(logo,in:bottomUp(place.logo))
        }
        NSAttributedString(string:text,attributes:[.font:place.font,.foregroundColor:NSColor.white])
            .draw(at:bottomUp(place.text).origin)
        context.endTransparencyLayer()
        guard let image=context.makeImage() else { return nil }
        return CIImage(cgImage:image)
    }

    /// The clip's frames with the mark over them, for the preview and the shared copy alike.
    static func composition(for asset:AVAsset,text:String) async throws -> AVVideoComposition {
        guard let track=try await asset.loadTracks(withMediaType:.video).first else { throw CocoaError(.fileReadCorruptFile) }
        let size=try await track.load(.naturalSize)
        guard let animation=Animation(size:size,text:text) else { throw CocoaError(.fileWriteUnknown) }
        return try await AVVideoComposition.videoComposition(with:asset) { request in
            request.finish(with:animation.frame(at:request.compositionTime.seconds).composited(over:request.sourceImage),context:nil)
        }
    }

    /// The mark over time: a moment after the clip starts it washes in from the left, drifting into
    /// place; then a sheen crosses the logo, and crosses it again every few seconds.
    struct Animation {
        static let start=0.3,reveal=0.8,sheen=0.7,sheenEvery=8.0
        let overlay:CIImage
        let logo:CIImage?
        let mark:CGRect,logoRect:CGRect,unit:CGFloat

        init?(size:CGSize,text:String) {
            let width=CGFloat(Int(size.width.rounded())),height=CGFloat(Int(size.height.rounded()))
            guard let overlay=HighlightMark.overlay(size:CGSize(width:width,height:height),text:text) else { return nil }
            let place=HighlightMark.layout(size:CGSize(width:width,height:height),text:text)
            // Core Image's origin is the bottom left.
            let bottomUp={ (rect:CGRect) in CGRect(x:rect.minX,y:height-rect.maxY,width:rect.width,height:rect.height) }
            let unit=height/1080,logoRect=bottomUp(place.logo)
            self.overlay=overlay
            self.unit=unit
            self.logoRect=logoRect
            mark=logoRect.union(bottomUp(place.text)).insetBy(dx:-24*unit,dy:-24*unit)
            logo=HighlightMark.logo.map { image in
                CIImage(cgImage:image)
                    .transformed(by:CGAffineTransform(scaleX:logoRect.width/CGFloat(image.width),y:logoRect.height/CGFloat(image.height)))
                    .transformed(by:CGAffineTransform(translationX:logoRect.minX,y:logoRect.minY))
            }
        }

        /// The mark at TIME seconds into the clip; nothing before it starts.
        func frame(at time:Double)->CIImage {
            let revealed=(time-Self.start)/Self.reveal
            guard revealed > 0 else { return CIImage.empty() }
            var image=overlay
            if revealed < 1 {
                let eased=CGFloat(1-pow(1-revealed,3)),band=mark.width*0.35
                let edge=mark.minX+eased*(mark.width+band)
                let mask=Self.ramp(CGPoint(x:edge-band,y:0),1,CGPoint(x:edge,y:0),0)
                image=overlay.transformed(by:CGAffineTransform(translationX:-14*unit*(1-eased),y:0))
                    .applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage.empty(),
                                                                       kCIInputMaskImageKey:mask])
                    .cropped(to:overlay.extent)
            }
            let since=time-Self.start-Self.reveal
            if since >= 0,let logo {
                let phase=CGFloat(since.truncatingRemainder(dividingBy:Self.sheenEvery)/Self.sheen)
                if phase < 1 {
                    // A soft white band, tilted about 20°, crossing the logo left to right.
                    let half=logoRect.height*0.55,dx=0.94*half,dy=0.34*half
                    let x=logoRect.minX-half+phase*(logoRect.width+2*half),y=logoRect.midY
                    let rising=Self.ramp(CGPoint(x:x-dx,y:y-dy),0,CGPoint(x:x,y:y),0.6)
                    let falling=Self.ramp(CGPoint(x:x,y:y),0.6,CGPoint(x:x+dx,y:y+dy),0)
                    let glint=rising.applyingFilter("CIMinimumCompositing",parameters:[kCIInputBackgroundImageKey:falling])
                        .applyingFilter("CISourceInCompositing",parameters:[kCIInputBackgroundImageKey:logo])
                        .cropped(to:logoRect)
                    image=glint.composited(over:image)
                }
            }
            return image
        }

        /// White from one alpha at FROM to another at TO, flat beyond both.
        static func ramp(_ from:CGPoint,_ fromAlpha:CGFloat,_ to:CGPoint,_ toAlpha:CGFloat)->CIImage {
            let gradient=CIFilter.smoothLinearGradient()
            gradient.point0=from
            gradient.point1=to
            gradient.color0=CIColor(red:1,green:1,blue:1,alpha:fromAlpha)
            gradient.color1=CIColor(red:1,green:1,blue:1,alpha:toAlpha)
            return gradient.outputImage ?? CIImage.empty()
        }
    }

    /// Writes the clip with the mark to DESTINATION (H.264 and AAC, as the original), tagged.
    static func export(_ source:URL,to destination:URL,text:String) async throws {
        let asset=AVURLAsset(url:source)
        let composition=try await composition(for:asset,text:text)
        guard let session=AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.videoComposition=composition
        session.shouldOptimizeForNetworkUse=true
        let item=AVMutableMetadataItem()
        item.identifier = .commonIdentifierSoftware
        item.value=tag as NSString
        session.metadata=[item]
        try? FileManager.default.removeItem(at:destination)
        try await session.export(to:destination,as:.mp4)
    }

    static func isMarked(_ url:URL)->Bool { getxattr(url.path,attribute,nil,0,0,XATTR_NOFOLLOW) >= 0 }
    static func setMarked(_ url:URL) {
        let value=Array(String(style).utf8)
        _=setxattr(url.path,attribute,value,value.count,0,XATTR_NOFOLLOW)
    }
    /// Whether the MP4 itself says Recall marked it (a marked clip copied back in, say).
    static func carriesTag(_ url:URL) async -> Bool {
        let asset=AVURLAsset(url:url)
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            for item in (try? await asset.loadMetadata(for:format)) ?? [] {
                if let value=try? await item.load(.stringValue),value.hasPrefix("\(Brand.name) mark") { return true }
            }
        }
        return false
    }

    /// Puts the mark into the MP4 at URL: the marked version is written beside it (same volume), then
    /// swapped in with the clip's date kept, so it keeps its place in the list. On any failure, or if
    /// the clip changed meanwhile, the clip stays as it was.
    static func markInPlace(_ url:URL,text:String) async throws {
        if await carriesTag(url) { setMarked(url);return }
        let manager=FileManager.default
        let keys:Set<URLResourceKey>=[.fileSizeKey,.contentModificationDateKey]
        let before=try url.resourceValues(forKeys:keys)
        let scratch=try manager.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:url,create:true)
        defer { try? manager.removeItem(at:scratch) }
        let marked=scratch.appendingPathComponent(url.lastPathComponent)
        try await export(url,to:marked,text:text)
        var current=url
        current.removeAllCachedResourceValues()
        let after=try current.resourceValues(forKeys:keys)
        guard after.fileSize == before.fileSize,after.contentModificationDate == before.contentModificationDate else {
            throw CocoaError(.fileWriteUnknown)
        }
        _=try manager.replaceItemAt(url,withItemAt:marked)
        if let date=before.contentModificationDate { try? manager.setAttributes([.modificationDate:date],ofItemAtPath:url.path) }
        setMarked(url)
    }
}

struct HighlightClip:Identifiable,Hashable {
    let url:URL
    let date:Date
    let bytes:Int64
    var duration:Double?=nil
    var id:URL { url }
    var name:String { url.deletingPathExtension().lastPathComponent }
    /// AVFoundation reads MP4 (and QuickTime's own formats), not WebM.
    var playable:Bool { url.pathExtension.lowercased() != "webm" }
    /// The clip as it is now: changes when Overwatch rewrites it.
    var identity:String { "\(url.path)|\(bytes)|\(Int64(date.timeIntervalSince1970*1000))" }
}

/// The clips in Movies › Overwatch, their previews, and the mark going into them.
@MainActor @Observable final class HighlightLibrary {
    private(set) var clips:[HighlightClip]=[]
    private(set) var loaded=false
    private(set) var thumbnails:[URL:NSImage]=[:]
    /// Clips being marked now: their tiles show progress, and a share or drag waits for them.
    private(set) var marking:Set<URL>=[]
    var folder:URL { HighlightFolder.url }
    @ObservationIgnored private var durations:[URL:(Date,Double)]=[:]
    @ObservationIgnored private var watcher:DispatchSourceFileSystemObject?
    @ObservationIgnored private var markLoop:Task<Void,Never>?
    /// Clips that couldn't be marked (their identity), not tried again until they change.
    @ObservationIgnored private var unmarkable:Set<String>=[]
    /// Clips whose length or preview is being read, so a reload doesn't start them again.
    @ObservationIgnored private var reading:Set<URL>=[]

    /// Where 1.6.4 RC1 kept marked copies of shared clips; removed.
    static var oldCopies:URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.overwatch2mac.launcher",isDirectory:true)
            .appendingPathComponent("Highlights",isDirectory:true)
    }

    /// Reads the folder: video files Overwatch has finished writing, newest first.
    func reload() {
        let manager=FileManager.default
        let keys:[URLResourceKey]=[.contentModificationDateKey,.fileSizeKey,.isRegularFileKey]
        let entries=(try? manager.contentsOfDirectory(at:folder,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles])) ?? []
        var found:[HighlightClip]=[]
        for entry in entries where HighlightFolder.videoExtensions.contains(entry.pathExtension.lowercased()) {
            guard let values=try? entry.resourceValues(forKeys:Set(keys)),values.isRegularFile == true,
                  let size=values.fileSize,size > 0,let date=values.contentModificationDate else { continue }
            var clip=HighlightClip(url:entry,date:date,bytes:Int64(size))
            if let known=durations[entry],known.0 == date { clip.duration=known.1 }
            found.append(clip)
        }
        found.sort { $0.date > $1.date }
        if found != clips { clips=found }
        loaded=true
        for clip in found where clip.playable && clip.duration == nil { measure(clip) }
        for clip in found where thumbnails[clip.url] == nil && clip.playable { thumbnail(clip) }
    }

    /// With the mark on, every MP4 Overwatch has finished saving (untouched for 3 seconds) that isn't
    /// marked yet gets it, newest first, one at a time; the folder is looked at every 3 seconds.
    /// Turning it off stops there: clips already marked keep it.
    func markSaved(_ on:Bool,every interval:Duration = .seconds(3)) {
        try? FileManager.default.removeItem(at:Self.oldCopies)
        markLoop?.cancel()
        markLoop=nil
        guard on else { return }
        markLoop=Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                while !Task.isCancelled,let self,let clip=nextToMark() { await mark(clip) }
                try? await Task.sleep(for:interval)
            }
        }
    }
    private func nextToMark()->HighlightClip? {
        let settled=Date().addingTimeInterval(-3)
        return clips.first { clip in
            clip.url.pathExtension.lowercased() == "mp4" && clip.date < settled && !unmarkable.contains(clip.identity)
                && !HighlightMark.isMarked(clip.url)
        }
    }
    private func mark(_ clip:HighlightClip) async {
        marking.insert(clip.url)
        do {
            try await HighlightMark.markInPlace(clip.url,text:HighlightMark.text)
            thumbnails[clip.url]=nil  // its preview shows the mark too
        } catch {
            unmarkable.insert(clip.identity)
        }
        marking.remove(clip.url)
        reload()
    }

    /// Follows the folder while something shows it: new and removed files at once, and every
    /// two seconds a clip still being written, which changes no entry of the folder.
    func watch() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let descriptor=Darwin.open(folder.path,O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:descriptor,eventMask:[.write,.rename,.delete],queue:.main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher=source
    }
    func stopWatching() {
        watcher?.cancel()
        watcher=nil
    }

    private func measure(_ clip:HighlightClip) {
        guard reading.insert(clip.url).inserted else { return }
        Task { [weak self] in
            defer { self?.reading.remove(clip.url) }
            let asset=AVURLAsset(url:clip.url)
            // A clip Overwatch is still writing doesn't load yet; the next reload tries again.
            guard let duration=try? await asset.load(.duration),duration.isNumeric,duration.seconds > 0 else { return }
            guard let self else { return }
            durations[clip.url]=(clip.date,duration.seconds)
            if let index=clips.firstIndex(where:{ $0.url == clip.url && $0.date == clip.date }) { clips[index].duration=duration.seconds }
            if thumbnails[clip.url] == nil { thumbnail(clip) }
        }
    }

    private func thumbnail(_ clip:HighlightClip) {
        guard reading.insert(clip.url.appendingPathExtension("thumbnail")).inserted else { return }
        Task { [weak self] in
            defer { self?.reading.remove(clip.url.appendingPathExtension("thumbnail")) }
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:clip.url))
            generator.appliesPreferredTrackTransform=true
            generator.maximumSize=CGSize(width:640,height:360)
            guard let image=try? await generator.image(at:CMTime(seconds:1,preferredTimescale:600)).image else { return }
            self?.thumbnails[clip.url]=NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
        }
    }

    /// The file a share or drag hands over: the clip itself, once any marking under way is done.
    func shareable(_ clip:HighlightClip) async -> URL {
        while marking.contains(clip.url) { try? await Task.sleep(for:.milliseconds(250)) }
        return clip.url
    }

    func open(_ clip:HighlightClip) {
        // MP4 opens in QuickTime, the Mac's own player; WebM in whatever the player chose for it.
        if clip.playable,let quickTime=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.QuickTimePlayerX") {
            NSWorkspace.shared.open([clip.url],withApplicationAt:quickTime,configuration:NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(clip.url)
        }
    }
    func showInFinder(_ clip:HighlightClip?) {
        if let clip { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
        else {
            try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            NSWorkspace.shared.open(folder)
        }
    }
    func moveToTrash(_ clip:HighlightClip) {
        try? FileManager.default.trashItem(at:clip.url,resultingItemURL:nil)
        reload()
    }

}

/// What a share hands over: the clip, once any marking under way is done.
struct SharedHighlight:Transferable {
    let clip:HighlightClip
    let library:HighlightLibrary
    static var transferRepresentation:some TransferRepresentation {
        FileRepresentation(exportedContentType:.mpeg4Movie) { shared in
            SentTransferredFile(await shared.library.shareable(shared.clip))
        }
    }
}

struct HighlightsSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var askMark=false
    private var library:HighlightLibrary { model.highlights }
    private let columns=[GridItem(.flexible(),spacing:14),GridItem(.flexible(),spacing:14)]
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.firstTextBaseline) {
                VStack(alignment:.leading,spacing:4) {
                    Text(L("Highlights")).font(LauncherStyle.font(28,.bold)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                    Text(L("Saved in Movies › Overwatch")).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                }
                Spacer(minLength:12)
                Button(L("Show in Finder")) { library.showInFinder(nil) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
            if library.loaded && library.clips.isEmpty { empty } else {
                ScrollView {
                    LazyVGrid(columns:columns,spacing:16) {
                        ForEach(library.clips) { clip in HighlightTile(clip:clip,model:model) }
                    }.padding(.vertical,2)
                }.scrollBounceBehavior(.basedOnSize).frame(maxHeight:.infinity,alignment:.top)
            }
            HStack(alignment:.center,spacing:16) {
                Text(model.highlightMark ? L("Your MP4 highlights carry the {0} mark.",Brand.name) : L("Drag a highlight into Discord or Messages to share it."))
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
                Button(L("Done")) { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction).closesOnEscape { dismiss() }
            }
        }.padding(28).frame(width:LauncherStyle.sheetWidth,height:LauncherStyle.largeSheetHeight,alignment:.top).tint(.primary)
            .background(LauncherStyle.ground(scheme))
            .onAppear {
                library.reload();library.watch()
                askMark=model.shouldAskAboutMark
            }
            .onDisappear { library.stopWatching() }
            // A clip still being written changes no entry of the folder: look again while open.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(2))
                    library.reload()
                    if !askMark && model.shouldAskAboutMark { askMark=true }
                }
            }
            .sheet(isPresented:$askMark) { HighlightMarkSheet(model:model) }
    }
    private var empty:some View {
        VStack(spacing:18) {
            Spacer(minLength:0)
            SheetHero(symbol:"film.stack",title:L("No highlights yet"),
                      subtitle:L("In Overwatch, open Career Profile › History › Highlights, choose a highlight and select Record. Saved highlights show up here."))
            Spacer(minLength:0)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

struct HighlightTile:View {
    let clip:HighlightClip
    @Bindable var model:AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var hovering=false
    private var library:HighlightLibrary { model.highlights }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Button { library.open(clip) } label: { preview }.buttonStyle(.plain)
                .accessibilityLabel(L("Open {0} in QuickTime",clip.name))
                .help(clip.playable ? L("Open in QuickTime") : L("Open"))
            VStack(alignment:.leading,spacing:2) {
                Text(verbatim:clip.name).font(LauncherStyle.font(13,.semibold)).lineLimit(1).truncationMode(.middle)
                Text(caption).font(LauncherStyle.font(11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onHover { hovering=$0 }
        .onDrag {
            // The file goes as itself (Discord and Messages take it at once); one still being marked
            // is promised and arrives when it's done.
            guard library.marking.contains(clip.url) else { return NSItemProvider(contentsOf:clip.url) ?? NSItemProvider() }
            let provider=NSItemProvider()
            provider.suggestedName=clip.url.deletingPathExtension().lastPathComponent
            provider.registerFileRepresentation(forTypeIdentifier:UTType.mpeg4Movie.identifier,fileOptions:[],visibility:.all) { done in
                Task { @MainActor in
                    done(await library.shareable(clip),false,nil)
                }
                return nil
            }
            return provider
        }
        .contextMenu {
            Button(clip.playable ? L("Open in QuickTime") : L("Open")) { library.open(clip) }
            Button(L("Show in Finder")) { library.showInFinder(clip) }
            ShareLink(item:SharedHighlight(clip:clip,library:library),
                      preview:SharePreview(clip.name)) { Text(L("Share…")) }
            Divider()
            Button(L("Move to Trash"),role:.destructive) { library.moveToTrash(clip) }
        }
    }
    private var caption:String {
        let date=clip.date.formatted(date:.abbreviated,time:.shortened)
        if !clip.playable { return L("{0} · WebM",date) }
        guard let duration=clip.duration else { return date }
        return L("{0} · {1}",date,Duration.seconds(duration.rounded()).formatted(.time(pattern:.minuteSecond)))
    }
    private var preview:some View {
        let shape=RoundedRectangle(cornerRadius:14,style:.continuous)
        return ZStack {
            shape.fill(Color.black.opacity(scheme == .dark ? 0.45 : 0.08))
            if let image=library.thumbnails[clip.url] {
                Image(nsImage:image).resizable().aspectRatio(contentMode:.fill)
            } else {
                Image(systemName:clip.playable ? "film" : "doc").font(.system(size:26,weight:.light)).foregroundStyle(.secondary)
            }
            if library.marking.contains(clip.url) {
                ProgressView().controlSize(.small).padding(8)
                    .background(.ultraThinMaterial,in:Circle())
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing).padding(8)
            } else if hovering {
                ShareLink(item:SharedHighlight(clip:clip,library:library),preview:SharePreview(clip.name)) {
                    Image(systemName:"square.and.arrow.up").font(.system(size:13,weight:.semibold)).frame(width:30,height:30)
                }.buttonStyle(.plain).foregroundStyle(.white)
                    .background(Color.black.opacity(0.45),in:Circle())
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing).padding(8)
                    .help(L("Share"))
            }
        }.aspectRatio(16/9,contentMode:.fit).clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(hovering ? 0.22 : 0.08),lineWidth:1) }
            .contentShape(shape)
    }
}

/// Asked once, the first time the player has a saved highlight (REC-97): their own clip, playing
/// with the mark, and the choice. Settings › General changes the answer later.
struct HighlightMarkSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player:AVQueuePlayer?
    @State private var looper:AVPlayerLooper?
    var body:some View {
        FittedSheet(spacing:22) {
            VStack(spacing:12) {
                Text(L("Help other Mac players find {0}",Brand.name)).font(LauncherStyle.font(24,.bold)).tracking(-0.5)
                    .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                Text(L("Add a small “{0}” mark to the MP4 highlights you save. It’s a free way to support the project.",HighlightMark.text))
                    .font(LauncherStyle.font(14)).lineSpacing(3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal:false,vertical:true)
            }
            ZStack {
                RoundedRectangle(cornerRadius:16,style:.continuous).fill(.black)
                if let player { LoopingVideo(player:player) } else { ProgressView().controlSize(.small) }
            }.aspectRatio(16/9,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:16,style:.continuous))
                .accessibilityLabel(L("Preview of your highlight with the mark"))
        } actions: {
            HStack(spacing:12) {
                Button(L("Not Now")) { model.answerMark(false);dismiss() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
                Button(L("Add Mark")) { model.answerMark(true);dismiss() }
                    .buttonStyle(AccentButtonStyle(large:true)).keyboardShortcut(.defaultAction)
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }
    private func load() async {
        // A clip without the mark yet, so the preview never shows it twice.
        guard let clip=model.highlights.clips.first(where:{ $0.playable && !HighlightMark.isMarked($0.url) }) else { return }
        let asset=AVURLAsset(url:clip.url)
        guard let composition=try? await HighlightMark.composition(for:asset,text:HighlightMark.text) else { return }
        let item=AVPlayerItem(asset:asset)
        item.videoComposition=composition
        let queue=AVQueuePlayer()
        queue.isMuted=true
        looper=AVPlayerLooper(player:queue,templateItem:item)
        player=queue
        queue.play()
    }
}

/// A muted video without controls, as the mark's preview shows it.
struct LoopingVideo:NSViewRepresentable {
    let player:AVPlayer
    func makeNSView(context:Context)->AVPlayerView {
        let view=AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player=player
        return view
    }
    func updateNSView(_ view:AVPlayerView,context:Context) { view.player=player }
}
