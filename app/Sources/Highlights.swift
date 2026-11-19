import AppKit
import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import IOKit
import QuickLook
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

/// A highlight Overwatch is still saving, or one whose save didn't finish. Overwatch creates the
/// file when a save starts and writes it all at the end (about two minutes for an MP4), so an
/// empty file is a save under way; it has failed once it is 10 minutes old, or a minute old with
/// neither Battle.net nor Overwatch running. A file changed in the last 3 seconds is still being
/// written (a WebM grows as Overwatch saves it).
struct PendingHighlight:Identifiable,Hashable {
    let url:URL
    let date:Date
    let failed:Bool
    var id:URL { url }
}

/// A tile in the Highlights window, newest first.
enum HighlightItem:Identifiable,Hashable {
    case clip(HighlightClip)
    case pending(PendingHighlight)
    var id:URL { url }
    var url:URL {
        switch self {
        case .clip(let clip): return clip.url
        case .pending(let pending): return pending.url
        }
    }
    var date:Date {
        switch self {
        case .clip(let clip): return clip.date
        case .pending(let pending): return pending.date
        }
    }
    var asClip:HighlightClip? { if case .clip(let clip)=self { return clip };return nil }
}

/// Something Recall is making from a clip, with how far it has got (0–1).
struct HighlightWork:Equatable {
    enum Kind { case discord,cut }
    var kind:Kind
    var progress:Double=0
}

/// The clips in Movies › Overwatch, their previews and what Recall reads from them, the mark
/// going into them, and the copies and cuts made from them.
@MainActor @Observable final class HighlightLibrary {
    private(set) var clips:[HighlightClip]=[]
    /// Saves under way or that didn't finish (not clips: nothing else in Recall touches them).
    private(set) var pending:[PendingHighlight]=[]
    private(set) var loaded=false
    private(set) var thumbnails:[URL:NSImage]=[:]
    /// The hero and the play (HighlightAnalysis), once read; a clip keeps what was read while it is
    /// read again (after the mark goes in, say).
    private(set) var facts:[URL:HighlightFacts]=[:]
    /// Strips of frames for the tiles under the pointer, a few at a time.
    private(set) var strips:[URL:NSImage]=[:]
    /// Clips being marked now: their tiles show progress, and a share or drag waits for them.
    private(set) var marking:Set<URL>=[]
    /// Copies for Discord and cuts under way.
    private(set) var work:[URL:HighlightWork]=[:]
    /// A line the window's footer shows for a few seconds after a copy or cut.
    private(set) var notice:String?
    /// Whether Battle.net or Overwatch runs (AppModel.screen): without them nothing is saving.
    var gameMayBeSaving=true
    var folder:URL { HighlightFolder.url }
    @ObservationIgnored let previews=HighlightPreviewStore(folder:HighlightPreviewStore.standard)
    @ObservationIgnored private var durations:[URL:(Date,Double)]=[:]
    @ObservationIgnored private var watcher:DispatchSourceFileSystemObject?
    @ObservationIgnored private var markLoop:Task<Void,Never>?
    /// Clips that couldn't be marked (their identity), not tried again until they change.
    @ObservationIgnored private var unmarkable:Set<String>=[]
    /// Clips whose length or preview is being read, so a reload doesn't start them again.
    @ObservationIgnored private var reading:Set<URL>=[]
    @ObservationIgnored private var analysisQueue:[HighlightClip]=[]
    @ObservationIgnored private var analysing=false
    /// Clips that couldn't be read (their identity), not tried again until they change.
    @ObservationIgnored private var unreadable:Set<String>=[]
    /// Cuts Recall wrote: finished as soon as they're in the folder.
    @ObservationIgnored private var made:Set<String>=[]
    @ObservationIgnored private var noticeTask:Task<Void,Never>?

    /// Help's topic on saving and sharing highlights (HelpSheet).
    nonisolated static let helpTopic="highlights"
    /// What a cut adds to the clip's name: "file_26-11-16_17-58-03-play.mp4".
    nonisolated static let playSuffix="play",trimSuffix="trim"

    /// Where 1.6.4 RC1 kept marked copies of shared clips; removed.
    static var oldCopies:URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.overwatch2mac.launcher",isDirectory:true)
            .appendingPathComponent("Highlights",isDirectory:true)
    }
    /// Copies made for Discord, kept a day so a paste still finds them.
    static var discordCopies:URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.overwatch2mac.launcher",isDirectory:true)
            .appendingPathComponent("DiscordCopies",isDirectory:true)
    }

    /// Reads the folder: video files Overwatch has finished writing, newest first, and saves under
    /// way or that didn't finish.
    func reload() {
        let manager=FileManager.default
        let keys:[URLResourceKey]=[.contentModificationDateKey,.fileSizeKey,.isRegularFileKey]
        let entries=(try? manager.contentsOfDirectory(at:folder,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles])) ?? []
        let now=Date()
        var found:[HighlightClip]=[],saving:[PendingHighlight]=[]
        for entry in entries where HighlightFolder.videoExtensions.contains(entry.pathExtension.lowercased()) {
            guard let values=try? entry.resourceValues(forKeys:Set(keys)),values.isRegularFile == true,
                  let size=values.fileSize,let date=values.contentModificationDate else { continue }
            let age=now.timeIntervalSince(date)
            if size == 0 {
                saving.append(PendingHighlight(url:entry,date:date,failed:age > 600 || (!gameMayBeSaving && age > 60)))
                continue
            }
            if age < 3 && !made.contains(entry.resolvingSymlinksInPath().path) {
                saving.append(PendingHighlight(url:entry,date:date,failed:false))
                continue
            }
            var clip=HighlightClip(url:entry,date:date,bytes:Int64(size))
            if let known=durations[entry],known.0 == date { clip.duration=known.1 }
            found.append(clip)
        }
        found.sort { $0.date > $1.date }
        saving.sort { $0.date > $1.date }
        if found != clips { clips=found }
        if saving != pending { pending=saving }
        loaded=true
        for clip in found where clip.playable && clip.duration == nil { measure(clip) }
        for clip in found { if let known=previews.facts(for:clip),facts[clip.url] != known { facts[clip.url]=known } }
        let present=Set(found.map(\.url))
        for url in facts.keys where !present.contains(url) { facts[url]=nil }
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
                && !HighlightMark.isMarked(clip.url) && work[clip.url] == nil
        }
    }
    /// A clip the mark is about to go into: read it once it's in.
    private func awaitsMark(_ clip:HighlightClip)->Bool {
        markLoop != nil && clip.url.pathExtension.lowercased() == "mp4" && !unmarkable.contains(clip.identity) && !HighlightMark.isMarked(clip.url)
    }
    private func mark(_ clip:HighlightClip) async {
        marking.insert(clip.url)
        do {
            try await HighlightMark.markInPlace(clip.url,text:HighlightMark.text)
            thumbnails[clip.url]=nil  // its preview shows the mark too
            strips[clip.url]=nil
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

    /// When the window opens: forgets previews of clips that are gone, and Discord copies over a day old.
    func tidy() {
        previews.keep(clips)
        let manager=FileManager.default,old=Date().addingTimeInterval(-86_400)
        for url in (try? manager.contentsOfDirectory(at:Self.discordCopies,includingPropertiesForKeys:[.contentModificationDateKey])) ?? [] {
            if let date=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,date < old {
                try? manager.removeItem(at:url)
            }
        }
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
        }
    }

    /// A tile is showing CLIP: its preview from Recall's caches, or made now from a frame 40% in,
    /// which is in the play rather than the intro; then the hero, the play and the strip of frames.
    func prepare(_ clip:HighlightClip) {
        guard clip.playable else { return }
        if thumbnails[clip.url] == nil {
            if let saved=previews.picture(clip,"preview") { thumbnails[clip.url]=saved } else { thumbnail(clip) }
        }
        analyse(clip)
    }
    private func thumbnail(_ clip:HighlightClip) {
        guard reading.insert(clip.url.appendingPathExtension("preview")).inserted else { return }
        Task { [weak self] in
            defer { self?.reading.remove(clip.url.appendingPathExtension("preview")) }
            let asset=AVURLAsset(url:clip.url)
            guard let duration=try? await asset.load(.duration).seconds,duration > 0 else { return }
            let generator=AVAssetImageGenerator(asset:asset)
            generator.appliesPreferredTrackTransform=true
            generator.maximumSize=CGSize(width:640,height:360)
            guard let image=try? await generator.image(at:CMTime(seconds:duration*0.4,preferredTimescale:600)).image,let self else { return }
            // The clip may have changed meanwhile (the mark went in): its next look makes another.
            guard clips.contains(where:{ $0.identity == clip.identity }) else { return }
            previews.store(image,for:clip,"preview")
            thumbnails[clip.url]=NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
        }
    }

    /// Reads CLIP's hero, play and strip once (HighlightAnalyzer), newest clip first, one at a time.
    private func analyse(_ clip:HighlightClip) {
        let stored=previews.facts(for:clip) != nil && FileManager.default.fileExists(atPath:previews.pictureURL(clip,"strip").path)
        guard !stored,!unreadable.contains(clip.identity),!awaitsMark(clip),
              !analysisQueue.contains(where:{ $0.identity == clip.identity }) else { return }
        analysisQueue.append(clip)
        guard !analysing else { return }
        analysing=true
        Task { [weak self] in
            while let self,let next=nextToAnalyse() {
                do {
                    let (facts,strip)=try await HighlightAnalyzer.analyze(next.url)
                    guard clips.contains(where:{ $0.identity == next.identity }) else { continue }
                    if let strip { previews.store(strip,for:next,"strip") }
                    previews.set(facts,for:next)
                    self.facts[next.url]=facts
                    strips[next.url]=nil
                } catch {
                    unreadable.insert(next.identity)
                }
            }
            self?.analysing=false
        }
    }
    private func nextToAnalyse()->HighlightClip? {
        analysisQueue.removeAll { queued in !clips.contains(where:{ $0.identity == queued.identity }) }
        guard let newest=analysisQueue.indices.max(by:{ analysisQueue[$0].date < analysisQueue[$1].date }) else { return nil }
        return analysisQueue.remove(at:newest)
    }

    /// The strip of frames for CLIP's tile, from Recall's caches.
    func loadStrip(_ clip:HighlightClip) {
        guard strips[clip.url] == nil,let image=previews.picture(clip,"strip") else { return }
        if strips.count >= 8 { strips.removeAll() }
        strips[clip.url]=image
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
    func showInFinder(_ url:URL?) {
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else {
            try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            NSWorkspace.shared.open(folder)
        }
    }
    /// Moves the file to the Trash; returns where it went, for Undo.
    @discardableResult func moveToTrash(_ url:URL)->URL? {
        var trashed:NSURL?
        try? FileManager.default.trashItem(at:url,resultingItemURL:&trashed)
        reload()
        return trashed as URL?
    }
    /// Undo of Move to Trash: the file goes back where it was.
    func putBack(_ trashed:URL,to url:URL) {
        try? FileManager.default.moveItem(at:trashed,to:url)
        reload()
    }

    /// Copies the clip, as Finder would, to paste into Messages or Discord.
    func copy(_ clip:HighlightClip) async {
        let url=await shareable(clip)
        put(url)
        say(L("Copied. Paste it with ⌘V."))
    }
    /// Copies a version of the clip under Discord's 20 MB limit for free accounts: the clip itself
    /// when it fits, else a smaller copy (720p for a whole highlight, 1080p for just the play).
    func copyForDiscord(_ clip:HighlightClip) async {
        guard work[clip.url] == nil else { return }
        work[clip.url]=HighlightWork(kind:.discord)
        defer { work[clip.url]=nil }
        let source=await shareable(clip)
        if let size=try? source.resourceValues(forKeys:[.fileSizeKey]).fileSize,Int64(size) <= HighlightEncoder.discordLimit {
            put(source)
            say(L("Copied. Paste it into Discord with ⌘V."))
            return
        }
        let destination=Self.discordCopies.appendingPathComponent(clip.name).appendingPathExtension("mp4")
        do {
            try FileManager.default.createDirectory(at:Self.discordCopies,withIntermediateDirectories:true)
            try await HighlightEncoder.smallCopy(source,to:destination) { [weak self] progress in
                Task { @MainActor in self?.work[clip.url]?.progress=progress }
            }
            put(destination)
            say(L("Copied. Paste it into Discord with ⌘V."))
        } catch {
            say(L("Couldn’t make a copy for Discord."))
        }
    }
    private func put(_ url:URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    /// Saves RANGE (seconds) of CLIP as a new clip beside it, "<name>-<SUFFIX>.mp4", at the clip's own
    /// size and quality. A cut of a marked clip carries the mark and isn't marked again; a cut of an
    /// unmarked one gets it, like any clip, when the mark is on. The original stays as it is.
    func cut(_ clip:HighlightClip,to range:ClosedRange<Double>,suffix:String) async {
        guard work[clip.url] == nil else { return }
        work[clip.url]=HighlightWork(kind:.cut)
        defer { work[clip.url]=nil }
        let manager=FileManager.default
        let source=await shareable(clip)
        let marked=HighlightMark.isMarked(source)
        var destination=folder.appendingPathComponent("\(clip.name)-\(suffix).mp4")
        var number=2
        while manager.fileExists(atPath:destination.path) {
            destination=folder.appendingPathComponent("\(clip.name)-\(suffix)-\(number).mp4")
            number+=1
        }
        do {
            // Written beside the folder, then moved in whole, so nothing reads it half written.
            let scratch=try manager.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:folder,create:true)
            defer { try? manager.removeItem(at:scratch) }
            let written=scratch.appendingPathComponent(destination.lastPathComponent)
            let span=CMTimeRange(start:CMTime(seconds:range.lowerBound,preferredTimescale:600),end:CMTime(seconds:range.upperBound,preferredTimescale:600))
            try await HighlightEncoder.encode(source,to:written,range:span,tag:marked ? HighlightMark.tag : nil) { [weak self] progress in
                Task { @MainActor in self?.work[clip.url]?.progress=progress }
            }
            if marked { HighlightMark.setMarked(written) }
            made.insert(destination.resolvingSymlinksInPath().path)
            try manager.moveItem(at:written,to:destination)
            reload()
            say(L("Saved as a new highlight."))
        } catch {
            say(L("Couldn’t save the new highlight."))
        }
    }

    /// Shows TEXT in the window's footer for a few seconds.
    func say(_ text:String) {
        notice=text
        noticeTask?.cancel()
        noticeTask=Task { [weak self] in
            try? await Task.sleep(for:.seconds(6))
            if !Task.isCancelled { self?.notice=nil }
        }
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

/// The Highlights window: the player's clips by day, newest first, each named by its hero.
/// The pointer runs through a clip's play; a double-click opens it in QuickTime. The keyboard works as in
/// Finder: arrows choose a clip, Space shows it in Quick Look, Return opens it, ⌘C copies it and
/// ⌘⌫ moves it to the Trash (Undo puts it back).
struct HighlightsSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.undoManager) private var undoManager
    @State private var askMark=false
    @State private var hero:String?
    @State private var selection:URL?
    @State private var quickLook:URL?
    @State private var trimming:HighlightClip?
    @FocusState private var focused:Bool
    private var library:HighlightLibrary { model.highlights }
    private let columns=[GridItem(.flexible(),spacing:14,alignment:.top),GridItem(.flexible(),spacing:14,alignment:.top)]

    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            header
            if showsHeroes { heroes }
            if library.loaded && library.clips.isEmpty && library.pending.isEmpty { empty } else { grid }
            footer
        }.padding(28).frame(width:LauncherStyle.sheetWidth,height:LauncherStyle.largeSheetHeight,alignment:.top).tint(.primary)
            .background(LauncherStyle.ground(scheme))
            .onAppear {
                library.gameMayBeSaving=model.screen == .running
                library.reload();library.watch();library.tidy()
                askMark=model.shouldAskAboutMark
                focused=true
            }
            .onDisappear { library.stopWatching() }
            // A clip still being written changes no entry of the folder: look again while open.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(2))
                    library.gameMayBeSaving=model.screen == .running
                    library.reload()
                    if !askMark && model.shouldAskAboutMark { askMark=true }
                    if let selected=selection,!flat.contains(where:{ $0.url == selected }) { selection=nil }
                }
            }
            .sheet(isPresented:$askMark) { HighlightMarkSheet(model:model) }
            .sheet(item:$trimming) { clip in HighlightTrimSheet(clip:clip,library:library) }
            .quickLookPreview($quickLook,in:library.clips.filter(\.playable).map(\.url))
    }

    private var header:some View {
        HStack(alignment:.firstTextBaseline) {
            VStack(alignment:.leading,spacing:4) {
                Text(L("Highlights")).font(LauncherStyle.font(28,.bold)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                Text(summary).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
            }
            Spacer(minLength:12)
            Button(L("Show in Finder")) { library.showInFinder(nil) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
    /// "5 highlights · 195 MB in Movies › Overwatch".
    private var summary:String {
        let count=library.clips.count
        guard count > 0 else { return L("Saved in Movies › Overwatch") }
        let size=ByteCountFormatter.string(fromByteCount:library.clips.reduce(0) { $0+$1.bytes },countStyle:.file)
        return count == 1 ? L("1 highlight · {0} in Movies › Overwatch",size) : L("{0} highlights · {1} in Movies › Overwatch",String(count),size)
    }

    /// The heroes in the player's clips, most saved first.
    private var heroNames:[String] {
        var counts:[String:Int]=[:]
        for clip in library.clips { if let hero=library.facts[clip.url]?.hero { counts[hero,default:0]+=1 } }
        return counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
    }
    /// Worth it once there are enough clips to look through, of more than one hero.
    private var showsHeroes:Bool { library.clips.count >= 6 && heroNames.count > 1 }
    private var heroes:some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:6) {
                HeroChip(title:L("All"),selected:hero == nil) { hero=nil }
                ForEach(heroNames,id:\.self) { name in
                    HeroChip(title:name,verbatim:true,selected:hero == name) { hero=hero == name ? nil : name }
                }
            }
        }.scrollBounceBehavior(.basedOnSize)
    }

    private var items:[HighlightItem] {
        // The filter applies only while it shows (deleting a hero's last clips hides it).
        let hero=showsHeroes ? hero : nil
        let clips=library.clips.filter { hero == nil || library.facts[$0.url]?.hero == hero }.map(HighlightItem.clip)
        let saves=hero == nil ? library.pending.map(HighlightItem.pending) : []
        return (clips+saves).sorted { $0.date > $1.date }
    }
    /// The items under a heading for each day: Today, Yesterday, then dates.
    struct Day:Identifiable { let title:String;let items:[HighlightItem];var id:String { title } }
    private var days:[Day] {
        let calendar=Calendar.current
        var groups:[(day:Date,items:[HighlightItem])]=[]
        for item in items {
            let day=calendar.startOfDay(for:item.date)
            if groups.last?.day == day { groups[groups.count-1].items.append(item) } else { groups.append((day,[item])) }
        }
        return groups.map { group in
            let title:String
            if calendar.isDateInToday(group.day) { title=L("Today") }
            else if calendar.isDateInYesterday(group.day) { title=L("Yesterday") }
            else if calendar.isDate(group.day,equalTo:Date(),toGranularity:.year) { title=group.day.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
            else { title=group.day.formatted(date:.long,time:.omitted) }
            return Day(title:title,items:group.items)
        }
    }
    /// Every item in the order shown, for the arrow keys.
    private var flat:[HighlightItem] { days.flatMap(\.items) }

    private var grid:some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    ForEach(days) { day in
                        VStack(alignment:.leading,spacing:10) {
                            Text(day.title).font(LauncherStyle.font(13,.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns:columns,spacing:16) {
                                ForEach(day.items) { item in
                                    HighlightTile(item:item,model:model,selected:selection == item.url,
                                                  select:{ selection=item.url;focused=true },
                                                  quickLook:{ quickLook=$0.url },trim:{ trimming=$0 },trash:trash).id(item.url)
                                }
                            }
                        }
                    }
                    if items.isEmpty { Text(L("No highlights of this hero.")).font(LauncherStyle.font(13)).foregroundStyle(.secondary) }
                }.padding(.vertical,2).padding(.horizontal,4)
            }.scrollBounceBehavior(.basedOnSize).frame(maxHeight:.infinity,alignment:.top).padding(.horizontal,-4)
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(keys:[.leftArrow,.rightArrow,.upArrow,.downArrow]) { press in
                    move(press.key)
                    if let selection { withAnimation(.easeOut(duration:0.15)) { scroller.scrollTo(selection) } }
                    return .handled
                }
                .onKeyPress(.space) {
                    guard let clip=selectedClip,clip.playable else { return .ignored }
                    quickLook=quickLook == nil ? clip.url : nil
                    return .handled
                }
                .onKeyPress(.return) {
                    if let clip=selectedClip { library.open(clip) } else { dismiss() }
                    return .handled
                }
                .onKeyPress(keys:[.delete]) { press in
                    guard press.modifiers.contains(.command),let selected=flat.first(where:{ $0.url == selection }) else { return .ignored }
                    // A save Overwatch is still writing stays.
                    if case .pending(let save)=selected,!save.failed { return .handled }
                    trash(selected)
                    return .handled
                }
                .onCopyCommand {
                    guard let clip=selectedClip else { return [] }
                    library.say(L("Copied. Paste it with ⌘V."))
                    return [NSItemProvider(contentsOf:clip.url)].compactMap { $0 }
                }
        }
    }
    private var selectedClip:HighlightClip? { flat.first(where:{ $0.url == selection })?.asClip }
    /// Left and right step through the tiles; up and down go a row (two tiles).
    private func move(_ key:KeyEquivalent) {
        let all=flat
        guard !all.isEmpty else { return }
        guard let selection,let index=all.firstIndex(where:{ $0.url == selection }) else { self.selection=all[0].url;return }
        let step:Int
        switch key {
        case .leftArrow: step = -1
        case .rightArrow: step=1
        case .upArrow: step = -2
        default: step=2
        }
        self.selection=all[min(max(index+step,0),all.count-1)].url
    }
    /// Moves the item to the Trash; Edit › Undo puts it back.
    private func trash(_ item:HighlightItem) {
        let url=item.url
        guard let trashed=library.moveToTrash(url) else { return }
        if selection == url { selection=nil }
        undoManager?.registerUndo(withTarget:library) { library in library.putBack(trashed,to:url) }
        undoManager?.setActionName(L("Move to Trash"))
    }

    private var empty:some View {
        VStack(spacing:18) {
            Spacer(minLength:0)
            SheetHero(symbol:"film.stack",title:L("No highlights yet"),
                      subtitle:L("In Overwatch, open Career Profile › History › Highlights, choose a highlight and select Save. Saved highlights show up here."))
            Spacer(minLength:0)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }

    private var footer:some View {
        HStack(alignment:.center,spacing:16) {
            Group {
                if let notice=library.notice {
                    Text(notice)
                } else if model.highlightMark {
                    HStack(spacing:6) {
                        Text(L("Your MP4 highlights carry the {0} mark.",Brand.name))
                        Button(L("Change")) { model.settingsTab = .general;model.sheet = .settings }.buttonStyle(.link).foregroundStyle(.primary)
                    }
                } else {
                    Text(L("Drag a highlight into Discord or Messages, or copy it with ⌘C."))
                }
            }.font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                .animation(.easeOut(duration:0.2),value:library.notice)
            Spacer(minLength:0)
            Button(L("Done")) { dismiss() }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .controlSize(.large).closesOnEscape { dismiss() }
        }
    }
}

/// A hero in the filter above the clips.
struct HeroChip:View {
    let title:String
    var verbatim=false
    let selected:Bool
    let action:()->Void
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        Button(action:action) {
            Group { if verbatim { Text(verbatim:title) } else { Text(title) } }
                .font(LauncherStyle.font(12,selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal,12).frame(height:26)
                .background {
                    Capsule().fill(selected ? LauncherStyle.surface(scheme) : .clear)
                        .overlay { Capsule().strokeBorder(.primary.opacity(selected ? 0.10 : 0.08),lineWidth:1) }
                }.contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct HighlightTile:View {
    let item:HighlightItem
    @Bindable var model:AppModel
    let selected:Bool
    let select:()->Void
    let quickLook:(HighlightClip)->Void
    let trim:(HighlightClip)->Void
    let trash:(HighlightItem)->Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering=false
    /// Where the pointer is across the preview (0–1), while it's over it.
    @State private var scrub:Double?
    @State private var width:CGFloat=1
    private var library:HighlightLibrary { model.highlights }
    private let shape=RoundedRectangle(cornerRadius:14,style:.continuous)

    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            switch item {
            case .clip(let clip):
                // As in Finder, a click chooses the clip and a double-click opens it (a single click
                // that opened it left the double-click's second click to bring Recall back over
                // QuickTime). Its own buttons sit beside the preview, on top, so a click on them
                // is theirs.
                ZStack(alignment:.topTrailing) {
                    preview(clip)
                        .onTapGesture(count:2) { select();library.open(clip) }
                        .simultaneousGesture(TapGesture().onEnded { select() })
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel(L("Open {0} in QuickTime",title))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { select();library.open(clip) }
                        .help(clip.playable ? L("Double-click to open in QuickTime") : L("Double-click to open"))
                    controls(clip).padding(8)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hovering=true
                        guard clip.playable else { return }
                        library.loadStrip(clip)
                        scrub=min(max(point.x/width,0),0.999)
                    case .ended:
                        hovering=false
                        scrub=nil
                    }
                }
                .task(id:clip.identity) { library.prepare(clip) }
            case .pending(let save):
                pendingPreview(save).onTapGesture(perform:select)
            }
            VStack(alignment:.leading,spacing:2) {
                Text(verbatim:title).font(LauncherStyle.font(13,.semibold)).lineLimit(1).truncationMode(.middle)
                caption.font(LauncherStyle.font(11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onDrag {
            guard let clip=item.asClip else { return NSItemProvider() }
            // The file goes as itself (Discord and Messages take it at once); one still being marked
            // is promised and arrives when it's done.
            guard library.marking.contains(clip.url) else { return NSItemProvider(contentsOf:clip.url) ?? NSItemProvider() }
            let provider=NSItemProvider()
            provider.suggestedName=clip.name
            provider.registerFileRepresentation(forTypeIdentifier:UTType.mpeg4Movie.identifier,fileOptions:[],visibility:.all) { done in
                Task { @MainActor in
                    done(await library.shareable(clip),false,nil)
                }
                return nil
            }
            return provider
        }
        .contextMenu { menu }
    }

    private var title:String {
        switch item {
        case .clip(let clip): return library.facts[clip.url]?.hero ?? L("Highlight")
        case .pending: return L("Highlight")
        }
    }
    private var caption:Text {
        let time=item.date.formatted(date:.omitted,time:.shortened)
        switch item {
        case .clip(let clip):
            if !clip.playable { return Text(L("{0} · WebM",time)) }
            guard let duration=clip.duration else { return Text(verbatim:time) }
            return Text(L("{0} · {1}",time,Duration.seconds(duration.rounded()).formatted(.time(pattern:.minuteSecond))))
        case .pending(let save):
            return save.failed ? Text(L("{0} · Didn’t finish",time)) : Text(L("{0} · Saving",time))
        }
    }

    @ViewBuilder private var menu:some View {
        switch item {
        case .clip(let clip):
            let busy=library.work[clip.url] != nil
            Button(clip.playable ? L("Open in QuickTime") : L("Open")) { library.open(clip) }
            if clip.playable { Button(L("Quick Look")) { quickLook(clip) } }
            Button(L("Show in Finder")) { library.showInFinder(clip.url) }
            Divider()
            Button(L("Copy")) { Task { await library.copy(clip) } }
            if clip.playable && model.showsDiscord {
                Button(L("Copy for Discord")) { Task { await library.copyForDiscord(clip) } }.disabled(busy)
            }
            ShareLink(item:SharedHighlight(clip:clip,library:library),preview:SharePreview(clip.name)) { Text(L("Share…")) }
            if clip.playable {
                Divider()
                if let play=library.facts[clip.url].flatMap({ $0.cuttable ? $0.play : nil }) {
                    Button(L("Save Just the Play")) { Task { await library.cut(clip,to:play,suffix:HighlightLibrary.playSuffix) } }.disabled(busy)
                }
                Button(L("Trim…")) { trim(clip) }.disabled(busy)
            }
            Divider()
            Button(L("Move to Trash"),role:.destructive) { trash(item) }
        case .pending(let save):
            if save.failed {
                Button(L("Get Help")) { model.openHelp(.questions,topic:HighlightLibrary.helpTopic) }
                Divider()
                Button(L("Move to Trash"),role:.destructive) { trash(item) }
            } else {
                Button(L("Show in Finder")) { library.showInFinder(save.url) }
            }
        }
    }

    private func tileFrame<Content:View>(@ViewBuilder _ content:()->Content)->some View {
        ZStack { content() }
            .aspectRatio(16/9,contentMode:.fit).clipShape(shape)
            .overlay {
                shape.strokeBorder(selected ? AnyShapeStyle(LauncherStyle.accent) : AnyShapeStyle(.primary.opacity(hovering ? 0.22 : 0.08)),
                                   lineWidth:selected ? 2.5 : 1)
            }
            .contentShape(shape)
            .onGeometryChange(for:CGFloat.self) { $0.size.width } action: { width=max($0,1) }
    }

    private func preview(_ clip:HighlightClip)->some View {
        tileFrame {
            shape.fill(Color.black.opacity(scheme == .dark ? 0.45 : 0.08))
            if let scrub,let strip=library.strips[clip.url] {
                StripFrame(strip:strip,frames:HighlightAnalyzer.stripFrames,position:scrub)
                    .overlay(alignment:.bottom) {
                        // How far through the play the pointer is.
                        GeometryReader { bar in
                            ZStack(alignment:.leading) {
                                Capsule().fill(.white.opacity(0.35))
                                Capsule().fill(.white).frame(width:max(3,bar.size.width*scrub))
                            }
                        }.frame(height:3).padding(.horizontal,12).padding(.bottom,9).shadow(color:.black.opacity(0.35),radius:2)
                    }
            } else if let image=library.thumbnails[clip.url] {
                Image(nsImage:image).resizable().aspectRatio(contentMode:.fill)
            } else if clip.playable {
                Image(systemName:"film").font(.system(size:26,weight:.light)).foregroundStyle(.secondary)
            } else {
                VStack(spacing:8) {
                    Image(systemName:"film").font(.system(size:24,weight:.light))
                    Text(L("WebM can’t be previewed")).font(LauncherStyle.font(11,.medium))
                }.foregroundStyle(.secondary)
            }
            if let work=library.work[clip.url] {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing:8) {
                        ProgressView(value:work.progress).progressViewStyle(.circular).controlSize(.small).tint(.white)
                        Text(work.kind == .discord ? L("Making a copy for Discord…") : L("Saving a new highlight…"))
                            .font(LauncherStyle.font(11,.semibold)).foregroundStyle(.white)
                    }
                }
            }
        }
    }

    /// Top right of the preview: the mark going in, or the clip's buttons while it's under the
    /// pointer or chosen (with the keyboard, say).
    @ViewBuilder private func controls(_ clip:HighlightClip)->some View {
        if library.work[clip.url] == nil {
            if library.marking.contains(clip.url) {
                ProgressView().controlSize(.small).padding(8).background(.ultraThinMaterial,in:Circle())
            } else if hovering || selected {
                actions(clip)
            }
        }
    }

    /// Over the preview while the pointer is on it: Copy for Discord, and the rest in a menu.
    private func actions(_ clip:HighlightClip)->some View {
        HStack(spacing:6) {
            if clip.playable && model.showsDiscord {
                Button { Task { await library.copyForDiscord(clip) } } label: {
                    Text(L("Copy for Discord")).font(LauncherStyle.font(11,.semibold)).padding(.horizontal,10).frame(height:26)
                        .background(Color.black.opacity(0.55),in:Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain).foregroundStyle(.white)
                    .help(L("Copies a version under Discord’s 20 MB limit, to paste into a chat"))
            }
            Menu { menu } label: {
                Image(systemName:"ellipsis").font(.system(size:12,weight:.bold)).foregroundStyle(.white)
                    .frame(width:26,height:26).background(Color.black.opacity(0.55),in:Circle()).contentShape(Circle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("More"))
        }
    }

    private func pendingPreview(_ save:PendingHighlight)->some View {
        tileFrame {
            shape.fill(Color.black.opacity(scheme == .dark ? 0.45 : 0.06))
            VStack(spacing:10) {
                if save.failed {
                    Image(systemName:"exclamationmark.triangle").font(.system(size:22,weight:.regular))
                    Text(L("This save didn’t finish")).font(LauncherStyle.font(12,.semibold))
                    Button(L("Get Help")) { model.openHelp(.questions,topic:HighlightLibrary.helpTopic) }.buttonStyle(.link).font(LauncherStyle.font(12))
                } else {
                    ProgressView().controlSize(.small)
                    Text(L("Saving…")).font(LauncherStyle.font(12,.semibold))
                    Text(L("Overwatch takes a minute or two")).font(LauncherStyle.font(11))
                }
            }.foregroundStyle(.secondary).multilineTextAlignment(.center).padding(12)
        }
        .onHover { hovering=$0 }
    }
}

/// One frame of a strip (HighlightAnalyzer), the one at POSITION (0–1) along it.
struct StripFrame:View {
    let strip:NSImage
    let frames:Int
    let position:Double
    var body:some View {
        GeometryReader { space in
            let index=min(frames-1,max(0,Int(position*Double(frames))))
            Image(nsImage:strip).resizable().interpolation(.medium)
                .frame(width:space.size.width*CGFloat(frames),height:space.size.height)
                .offset(x:-space.size.width*CGFloat(index))
                .frame(width:space.size.width,height:space.size.height,alignment:.leading)
                .clipped()
        }
    }
}

/// Trim, inside Recall: the clip in macOS's own player with its trim bar (as in QuickTime), set to
/// the play when Recall found it. Trim saves the part kept as a new highlight.
struct HighlightTrimSheet:View {
    let clip:HighlightClip
    let library:HighlightLibrary
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        FittedSheet(spacing:20) {
            VStack(spacing:10) {
                Text(L("Trim")).font(LauncherStyle.font(24,.bold)).tracking(-0.5).accessibilityAddTraits(.isHeader)
                Text(L("Drag the yellow ends to the part you want, then choose Trim. It’s saved as a new highlight; this one stays as it is."))
                    .font(LauncherStyle.font(14)).lineSpacing(3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal:false,vertical:true)
            }
            TrimmingPlayer(url:clip.url,start:library.facts[clip.url]?.play) { range in
                if let range { Task { await library.cut(clip,to:range,suffix:HighlightLibrary.trimSuffix) } }
                dismiss()
            }.aspectRatio(16/9,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:16,style:.continuous))
        } actions: {
            EmptyView()
        }
    }
}

/// macOS's player with its trim bar open as soon as the clip is ready. DONE gets the part kept, in
/// seconds, or nil when the player chose Cancel.
struct TrimmingPlayer:NSViewRepresentable {
    let url:URL
    let start:ClosedRange<Double>?
    let done:(ClosedRange<Double>?)->Void
    final class Coordinator { var status:NSKeyValueObservation?;var began=false }
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeNSView(context:Context)->AVPlayerView {
        let view=AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        let item=AVPlayerItem(url:url)
        if let start {
            item.reversePlaybackEndTime=CMTime(seconds:start.lowerBound,preferredTimescale:600)
            item.forwardPlaybackEndTime=CMTime(seconds:start.upperBound,preferredTimescale:600)
        }
        let player=AVPlayer(playerItem:item)
        view.player=player
        let done=self.done,coordinator=context.coordinator
        coordinator.status=item.observe(\.status,options:[.initial,.new]) { [weak view] item,_ in
            guard item.status != .unknown else { return }
            DispatchQueue.main.async { [weak view] in
                guard let view,!coordinator.began else { return }
                coordinator.began=true
                guard item.status == .readyToPlay else { done(nil);return }
                if let start { player.seek(to:CMTime(seconds:start.lowerBound,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) }
                Self.trim(view,tries:30,done:done)
            }
        }
        return view
    }
    /// The trim bar, once the player can show it: a clip that loads at once may be ready before the
    /// view is in its window, so it's tried every 0.1 s for a while.
    static func trim(_ view:AVPlayerView,tries:Int,done:@escaping (ClosedRange<Double>?)->Void) {
        guard view.canBeginTrimming else {
            guard tries > 0 else { done(nil);return }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { [weak view] in
                if let view { trim(view,tries:tries-1,done:done) }
            }
            return
        }
        view.beginTrimming { result in
            guard result == .okButton,let item=view.player?.currentItem else { done(nil);return }
            let from=item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
            let to=item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : item.duration.seconds
            done(to-from >= 0.5 ? from...to : nil)
        }
    }
    func updateNSView(_ view:AVPlayerView,context:Context) {}
    static func dismantleNSView(_ view:AVPlayerView,coordinator:Coordinator) {
        view.player?.pause()
        coordinator.status=nil
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
