import AppKit
import AVFoundation
import CryptoKit
import Vision

/// What Recall reads from a saved highlight, all on the Mac: the hero, and where the play is.
///
/// A highlight Overwatch saves is about 27 seconds: about 5 of the player's highlight intro, a white
/// flash, about 14 of play, then about 8 of a black end card with Overwatch's logo (measured on the
/// owner's clips, November 18). The flash and the end card are found by brightness. The intro
/// writes "AS SOLDIER: 76" under the player's name, and the play has a "HIGHLIGHT SOLDIER: 76" banner
/// with "BY <player>" under it, so the hero is read with macOS's text recognition. A clip without
/// these (another language, a clip already cut) simply has no hero or play, and the window shows its
/// time instead.
struct HighlightFacts:Codable,Equatable {
    var hero:String?
    /// Seconds into the clip where the play starts (just after the flash) and ends (where the end
    /// card goes black); nil unless the clip has both.
    var playStart:Double?
    var playEnd:Double?
    var duration:Double
    var play:ClosedRange<Double>? {
        guard let playStart,let playEnd,playEnd-playStart >= 2 else { return nil }
        return playStart...playEnd
    }
    /// Whether "Just the Play" leaves out enough to be worth a new clip.
    var cuttable:Bool {
        guard let play else { return false }
        return duration-(play.upperBound-play.lowerBound) >= 2
    }
}

/// One frame's brightness: its mean (0–1) and the share of it that isn't near black.
struct FrameBrightness:Equatable {
    var time:Double
    var mean:Double
    var lit:Double
}

enum HighlightParts {
    /// The play between the intro's flash and the end card. The flash is a nearly all-white frame in
    /// the first 12 seconds; the play starts once it has faded. The end card is the run of dark frames
    /// that lasts to the clip's last second (its final moment may flash) and is at least 2 seconds long.
    static func find(_ frames:[FrameBrightness],duration:Double)->ClosedRange<Double>? {
        guard let flash=frames.firstIndex(where:{ $0.time > 1 && $0.time < 12 && $0.mean > 0.85 && $0.lit > 0.98 }) else { return nil }
        var start=flash
        while start < frames.count && frames[start].mean > 0.6 { start+=1 }
        guard start < frames.count,var end=frames.lastIndex(where:{ $0.time <= duration-1 }),end > start,frames[end].lit < 0.15 else { return nil }
        while end > start+1 && frames[end-1].lit < 0.15 { end-=1 }
        let range=frames[start].time...frames[end].time
        guard duration-range.upperBound >= 2,range.upperBound-range.lowerBound >= 2 else { return nil }
        return range
    }
}

enum HeroName {
    /// Names whose capitals or accents the game's all-caps text loses.
    static let spelled=["D.VA":"D.Va","D. VA":"D.Va","LUCIO":"Lúcio","LÚCIO":"Lúcio","TORBJORN":"Torbjörn","TORBJÖRN":"Torbjörn",
                        "SOLDIER:76":"Soldier: 76"]
    /// The hero in the text read off a frame: the intro's "AS <HERO>", else the banner's
    /// "HIGHLIGHT <HERO>" when "BY <player>" is there too (so the intro's "HIGHLIGHT" and the
    /// player's name, if read as one line, are never taken for a hero).
    static func from(lines:[String])->String? {
        let lines=lines.map { $0.split(whereSeparator:\.isWhitespace).joined(separator:" ").uppercased() }
        if let line=lines.first(where:{ $0.hasPrefix("AS ") }),let name=clean(String(line.dropFirst(3))) { return display(name) }
        guard let by=lines.first(where:{ $0.hasPrefix("BY ") }) else { return nil }
        let player=String(by.dropFirst(3))
        if let line=lines.first(where:{ $0.hasPrefix("HIGHLIGHT ") }),let name=clean(String(line.dropFirst(10))),name != player {
            return display(name)
        }
        return nil
    }
    static func clean(_ text:String)->String? {
        let name=text.trimmingCharacters(in:.whitespaces)
        guard (2...20).contains(name.count),name.first?.isLetter == true,!name.contains("RECALL"),
              name.allSatisfy({ $0.isLetter || $0.isNumber || " .:'-".contains($0) }) else { return nil }
        return name
    }
    /// "WRECKING BALL" → "Wrecking Ball", "SOLDIER: 76" → "Soldier: 76".
    static func display(_ name:String)->String {
        if let known=spelled[name] { return known }
        return name.split(separator:" ").map { $0.prefix(1).uppercased()+$0.dropFirst().lowercased() }.joined(separator:" ")
    }
}

enum HighlightAnalyzer {
    /// How many frames the pointer runs through on a tile.
    static let stripFrames=10
    static let stripFrameSize=CGSize(width:480,height:270)

    /// Reads the clip: its brightness frame by frame (one pass, about 1.5 s for a 27-second
    /// clip), then a few frames for the hero's name and the strip of frames a tile shows under the
    /// pointer, across the play when there is one.
    static func analyze(_ url:URL) async throws -> (facts:HighlightFacts,strip:CGImage?) {
        let asset=AVURLAsset(url:url)
        let duration=try await asset.load(.duration).seconds
        guard let track=try await asset.loadTracks(withMediaType:.video).first,duration.isFinite,duration > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let frames=try await Task.detached(priority:.utility) { try brightness(asset:asset,track:track) }.value
        let play=HighlightParts.find(frames,duration:duration)
        var facts=HighlightFacts(hero:nil,playStart:play?.lowerBound,playEnd:play?.upperBound,duration:duration)
        let generator=AVAssetImageGenerator(asset:asset)
        generator.appliesPreferredTrackTransform=true
        generator.requestedTimeToleranceBefore=CMTime(seconds:0.1,preferredTimescale:600)
        generator.requestedTimeToleranceAfter=CMTime(seconds:0.1,preferredTimescale:600)
        // The intro's last seconds, then the play's banner; a clip without an intro shows the banner.
        let readAt=play.map { [$0.lowerBound-2.4,$0.lowerBound-1.2,$0.lowerBound+2] } ?? [1.5,3.5]
        for time in readAt.map({ min(max($0,0.2),duration-0.2) }) {
            guard let image=try? await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image else { continue }
            if let hero=HeroName.from(lines:text(in:image)) { facts.hero=hero;break }
        }
        generator.maximumSize=stripFrameSize
        let span=play ?? 0...duration
        var strip:CGImage?
        let width=Int(stripFrameSize.width),height=Int(stripFrameSize.height)
        if let context=CGContext(data:nil,width:width*stripFrames,height:height,bitsPerComponent:8,bytesPerRow:0,
                                 space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.interpolationQuality = .high
            for index in 0..<stripFrames {
                let time=span.lowerBound+(Double(index)+0.5)/Double(stripFrames)*(span.upperBound-span.lowerBound)
                guard let image=try? await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image else { continue }
                context.draw(image,in:fill(image,into:CGRect(x:index*width,y:0,width:width,height:height)))
            }
            strip=context.makeImage()
        }
        return (facts,strip)
    }

    /// IMAGE's rectangle filling FRAME, centred, as a 16:9 tile shows any clip.
    static func fill(_ image:CGImage,into frame:CGRect)->CGRect {
        let scale=max(frame.width/CGFloat(image.width),frame.height/CGFloat(image.height))
        let size=CGSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
        return CGRect(x:frame.midX-size.width/2,y:frame.midY-size.height/2,width:size.width,height:size.height)
    }

    /// Every frame's brightness, from a sparse grid of the luma plane.
    static func brightness(asset:AVAsset,track:AVAssetTrack) throws -> [FrameBrightness] {
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        output.alwaysCopiesSampleData=false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        var frames:[FrameBrightness]=[]
        while let sample=output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading();throw CancellationError() }
            guard let pixels=CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixels,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels,.readOnly) }
            guard let base=CVPixelBufferGetBaseAddressOfPlane(pixels,0)?.assumingMemoryBound(to:UInt8.self) else { continue }
            let width=CVPixelBufferGetWidthOfPlane(pixels,0),height=CVPixelBufferGetHeightOfPlane(pixels,0)
            let row=CVPixelBufferGetBytesPerRowOfPlane(pixels,0)
            let step=max(4,min(width,height)/60)
            var sum=0,count=0,lit=0
            for y in stride(from:0,to:height,by:step) {
                for x in stride(from:0,to:width,by:step) {
                    let value=Int(base[y*row+x])
                    sum+=value;count+=1
                    if value > 40 { lit+=1 }
                }
            }
            guard count > 0 else { continue }
            frames.append(FrameBrightness(time:CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                                          mean:Double(sum)/Double(count)/255,lit:Double(lit)/Double(count)))
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return frames
    }

    /// The lines of text macOS reads in IMAGE.
    static func text(in image:CGImage)->[String] {
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection=false
        try? VNImageRequestHandler(cgImage:image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}

/// Recall's previews of the clips, in its caches folder (Uninstall and the Homebrew zap remove it):
/// what each clip is (facts.json) and two pictures, its preview and its strip of frames. Each clip
/// is known by its identity (path, size, date), so a clip Overwatch rewrites, or one the mark goes
/// into, is read again.
@MainActor final class HighlightPreviewStore {
    let folder:URL
    private(set) var facts:[String:HighlightFacts]=[:]
    init(folder:URL) {
        self.folder=folder
        if let data=try? Data(contentsOf:folder.appendingPathComponent("facts.json")),
           let saved=try? JSONDecoder().decode([String:HighlightFacts].self,from:data) { facts=saved }
    }
    static var standard:URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.overwatch2mac.launcher",isDirectory:true)
            .appendingPathComponent("HighlightPreviews",isDirectory:true)
    }
    static func key(_ clip:HighlightClip)->String {
        SHA256.hash(data:Data(clip.identity.utf8)).prefix(10).map { String(format:"%02x",$0) }.joined()
    }
    func facts(for clip:HighlightClip)->HighlightFacts? { facts[Self.key(clip)] }
    func set(_ value:HighlightFacts,for clip:HighlightClip) {
        facts[Self.key(clip)]=value
        save()
    }
    func pictureURL(_ clip:HighlightClip,_ kind:String)->URL { folder.appendingPathComponent("\(Self.key(clip))-\(kind).jpg") }
    func picture(_ clip:HighlightClip,_ kind:String)->NSImage? {
        let url=pictureURL(clip,kind)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        return NSImage(contentsOf:url)
    }
    func store(_ image:CGImage,for clip:HighlightClip,_ kind:String) {
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let rep=NSBitmapImageRep(cgImage:image)
        try? rep.representation(using:.jpeg,properties:[.compressionFactor:0.8])?.write(to:pictureURL(clip,kind),options:.atomic)
    }
    /// Forgets clips no longer in the folder, and their pictures.
    func keep(_ clips:[HighlightClip]) {
        let keys=Set(clips.map(Self.key))
        let gone=facts.keys.filter { !keys.contains($0) }
        if !gone.isEmpty { for key in gone { facts[key]=nil };save() }
        for name in (try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? [] where name.hasSuffix(".jpg") {
            if let key=name.split(separator:"-").first,!keys.contains(String(key)) {
                try? FileManager.default.removeItem(at:folder.appendingPathComponent(name))
            }
        }
    }
    private func save() {
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try? JSONEncoder().encode(facts).write(to:folder.appendingPathComponent("facts.json"),options:.atomic)
    }
}
