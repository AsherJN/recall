import AppKit
import AVFoundation
import CoreImage

// Overwatch's saved highlights in Recall (Highlights.swift; REC-53, REC-96, REC-97): the Mac's name
// on the mark, the clips the Highlights window lists, and the mark put into a saved MP4 in place,
// changing only the corner above the HUD. Run by tests/run_highlights.py with CFFIXED_USER_HOME set to a
// scratch home, so Movies › Overwatch is a scratch folder.
// Main.swift (left out: it starts the app) declares this; SetupView's Force Quit names it.
@MainActor final class AppDelegate:NSObject { @objc func forceQuit() {} }

@main struct HighlightsTests {
    @MainActor static func main() async throws {
        // The app bundles the lockup; this test binary has no bundle, so it reads the repository's.
        let lockup=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("app/Resources/WordmarkDark.png")
        HighlightMark.logo=NSImage(contentsOf:lockup)?.cgImage(forProposedRect:nil,context:nil,hints:nil)
        precondition(HighlightMark.logo != nil,"no lockup at \(lockup.path)")
        names()
        try await library()
        try await markedInPlace()
        heroes()
        parts()
        plans()
        try await analysedAndCut()
        try await discordCopy()
        print("HighlightsTests: OK")
    }

    static func names() {
        precondition(MacName.family(fromProductName:"MacBook Air (13-inch, M2, 2022)") == "MacBook Air")
        precondition(MacName.family(fromProductName:"MacBook Pro (14-inch, Nov 2023)") == "MacBook Pro")
        precondition(MacName.family(fromProductName:"Mac mini (2024)") == "Mac mini")
        precondition(MacName.family(fromProductName:"MacBook Neo") == "MacBook Neo")
        precondition(MacName.family(fromProductName:"") == nil)
        precondition(MacName.family(fromModel:"MacBookAir10,1") == "MacBook Air")
        precondition(MacName.family(fromModel:"Macmini9,1") == "Mac mini")
        precondition(MacName.family(fromModel:"Mac14,2") == nil)
        precondition(MacName.chip(fromBrand:"Apple M2") == "M2")
        precondition(MacName.chip(fromBrand:"Apple M4 Pro") == "M4 Pro")
        precondition(MacName.chip(fromBrand:"Apple A18 Pro") == "A18 Pro")
        precondition(MacName.chip(fromBrand:"Intel(R) Core(TM) i7") == "")
        precondition(MacName.compose(family:"MacBook Air",chip:"M2") == "MacBook Air M2")
        precondition(MacName.compose(family:nil,chip:"M3") == "Mac M3")
        precondition(MacName.compose(family:"iMac",chip:"") == "iMac")
        // This Mac: a family and a chip, both from the system.
        precondition(!MacName.current.isEmpty && MacName.current.contains(" ") || MacName.current == "Mac","\(MacName.current)")
        precondition(HighlightMark.text.contains(MacName.current) && HighlightMark.text.contains(Brand.name))
    }

    /// Movies › Overwatch under the scratch home: finished video files, newest first; nothing else.
    @MainActor static func library() async throws {
        let folder=HighlightFolder.url
        precondition(folder.path.hasPrefix(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "/nonexistent"),
                     "Movies › Overwatch must be the scratch home's: \(folder.path)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let older=folder.appendingPathComponent("Genji.mp4"),newer=folder.appendingPathComponent("Tracer.webm")
        try Data("old".utf8).write(to:older);try Data("new".utf8).write(to:newer)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-600)],ofItemAtPath:older.path)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-60)],ofItemAtPath:newer.path)
        try Data().write(to:folder.appendingPathComponent("Writing.mp4"))      // still empty: Overwatch is writing it
        let stale=folder.appendingPathComponent("Stale.mp4"),unfinished=folder.appendingPathComponent("Unfinished.mp4")
        try Data().write(to:stale);try Data().write(to:unfinished)              // empty, and no longer being written
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-700)],ofItemAtPath:stale.path)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-120)],ofItemAtPath:unfinished.path)
        try Data("growing".utf8).write(to:folder.appendingPathComponent("Growing.webm"))  // a WebM Overwatch is still writing
        try Data("x".utf8).write(to:folder.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to:folder.appendingPathComponent(".hidden.mp4"))
        let library=HighlightLibrary()
        library.reload()
        precondition(library.clips.map(\.url.lastPathComponent) == ["Tracer.webm","Genji.mp4"],"\(library.clips.map(\.url.lastPathComponent))")
        // Saves: under way while empty and young (or just written), failed when old, or a minute old
        // with neither Battle.net nor Overwatch running.
        let pending={ Dictionary(uniqueKeysWithValues:library.pending.map { ($0.url.lastPathComponent,$0.failed) }) }
        precondition(pending() == ["Writing.mp4":false,"Growing.webm":false,"Unfinished.mp4":false,"Stale.mp4":true],"\(pending())")
        library.gameMayBeSaving=false
        library.reload()
        precondition(pending() == ["Writing.mp4":false,"Growing.webm":false,"Unfinished.mp4":true,"Stale.mp4":true],"\(pending())")
        precondition(!library.clips[0].playable && library.clips[1].playable)
        // A clip Overwatch rewrites is a new clip to the marker.
        let clip=library.clips[1]
        precondition(HighlightClip(url:clip.url,date:clip.date,bytes:clip.bytes+1).identity != clip.identity)
        // A share hands over the file itself.
        let shared=await library.shareable(library.clips[0])
        precondition(shared == library.clips[0].url)
        for name in ["Genji.mp4","Tracer.webm","Writing.mp4","Stale.mp4","Unfinished.mp4","Growing.webm","notes.txt",".hidden.mp4"] {
            try? FileManager.default.removeItem(at:folder.appendingPathComponent(name))
        }
    }

    /// A three-second 1280 × 720 clip of mid-grey frames, saved as Overwatch's would be.
    static func writeClip(to url:URL) async throws {
        try? FileManager.default.removeItem(at:url)
        let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:1280,AVVideoHeightKey:720])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1280,
            kCVPixelBufferHeightKey as String:720])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime:.zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(5)) }
            var pixels:CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&pixels)
            CVPixelBufferLockBaseAddress(pixels!,[])
            memset(CVPixelBufferGetBaseAddress(pixels!),128,CVPixelBufferGetDataSize(pixels!))
            CVPixelBufferUnlockBaseAddress(pixels!,[])
            precondition(adaptor.append(pixels!,withPresentationTime:CMTime(value:CMTimeValue(frame),timescale:30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed,"\(String(describing:writer.error))")
    }

    /// The colour at a point of the clip's frame SECONDS in (top-left origin).
    static func pixel(_ url:URL,x:Int,y:Int,at seconds:Double=2) async throws -> (Int,Int,Int) {
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image=try await generator.image(at:CMTime(seconds:seconds,preferredTimescale:600)).image
        let rep=NSBitmapImageRep(cgImage:image)
        let color=rep.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!
        return (Int(color.redComponent*255),Int(color.greenComponent*255),Int(color.blueComponent*255))
    }

    static func data(_ url:URL)->Data { (try? Data(contentsOf:url)) ?? Data() }
    static func waitUntil(_ what:String,seconds:Double=90,_ done:() -> Bool) async throws {
        let deadline=Date().addingTimeInterval(seconds)
        while !done() {
            precondition(Date() < deadline,"timed out waiting: \(what)")
            try await Task.sleep(for:.milliseconds(200))
        }
    }

    /// The mark goes into the saved MP4 itself: same name, length, size and date, Recall's lockup
    /// above the HUD in the bottom right once it has washed in, the rest of the picture as before,
    /// no other file left. Only finished MP4s, each once; off means off.
    @MainActor static func markedInPlace() async throws {
        let manager=FileManager.default,folder=HighlightFolder.url
        try manager.createDirectory(at:folder,withIntermediateDirectories:true)
        let plain=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("recall-grey-\(getpid()).mp4")
        try await writeClip(to:plain)
        defer { try? manager.removeItem(at:plain) }
        let saved=folder.appendingPathComponent("Grey.mp4"),writing=folder.appendingPathComponent("Writing.mp4")
        let webm=folder.appendingPathComponent("Old.webm")
        for url in [saved,writing] { try? manager.removeItem(at:url);try manager.copyItem(at:plain,to:url) }
        try Data("webm".utf8).write(to:webm)
        let date=Date(timeIntervalSince1970:(Date().timeIntervalSince1970-600).rounded())
        try manager.setAttributes([.modificationDate:date],ofItemAtPath:saved.path)
        try manager.setAttributes([.modificationDate:date],ofItemAtPath:webm.path)
        // Touched in the future: still being written as far as the marker can tell.
        try manager.setAttributes([.modificationDate:Date().addingTimeInterval(60)],ofItemAtPath:writing.path)
        // 1.6.4 RC1 kept marked copies in the caches; they go.
        let old=HighlightLibrary.oldCopies.appendingPathComponent("8cbd7e3810905c7c")
        try manager.createDirectory(at:old,withIntermediateDirectories:true)
        try Data("x".utf8).write(to:old.appendingPathComponent("clip.mp4"))

        let library=HighlightLibrary()
        library.markSaved(true,every:.milliseconds(200))
        try await waitUntil("Grey.mp4 marked") { HighlightMark.isMarked(saved) }
        library.markSaved(false)
        precondition(!manager.fileExists(atPath:HighlightLibrary.oldCopies.path),"RC1 copies kept")
        precondition(!HighlightMark.isMarked(writing) && data(writing) == data(plain),"a clip still being written was touched")
        precondition(data(webm) == Data("webm".utf8) && !HighlightMark.isMarked(webm),"WebM was touched")
        let names=try manager.contentsOfDirectory(atPath:folder.path).sorted()
        precondition(names == ["Grey.mp4","Old.webm","Writing.mp4"],"extra files: \(names)")
        let values=try saved.resourceValues(forKeys:[.contentModificationDateKey])
        precondition(abs(values.contentModificationDate!.timeIntervalSince(date)) < 1,"date not kept: \(values)")
        let tagged=await HighlightMark.carriesTag(saved)
        precondition(tagged,"no tag in the MP4")

        let asset=AVURLAsset(url:saved)
        let duration=try await asset.load(.duration).seconds
        precondition(abs(duration-3) < 0.1,"duration \(duration)")
        let size=try await asset.loadTracks(withMediaType:.video).first!.load(.naturalSize)
        precondition(size == CGSize(width:1280,height:720),"\(size)")
        // The lockup's orange square, near its top edge (the rewind arrows sit lower), above the HUD.
        let logo=HighlightMark.layout(size:CGSize(width:1280,height:720),text:HighlightMark.text).logo
        precondition(logo.minX > 640 && logo.minY > 360 && logo.maxY < 600,"lockup at \(logo)")
        let square=(x:Int(logo.minX+logo.height*0.5),y:Int(logo.minY+logo.height*0.12))
        let orange=try await pixel(saved,x:square.x,y:square.y)
        precondition(orange.0 > 190 && orange.0-orange.2 > 100,"lockup square \(orange) at \(square)")
        // Before the wash-in (0.3 s) that corner is still the clip's own.
        let early=try await pixel(saved,x:square.x,y:square.y,at:0.1),before=try await pixel(plain,x:square.x,y:square.y,at:0.1)
        precondition(abs(early.0-before.0) < 12 && abs(early.2-before.2) < 12,"mark before its start \(early) vs \(before)")
        // The top corners and the middle stay as they were (within compression).
        for (x,y) in [(19,30),(1260,30),(640,360)] {
            let after=try await pixel(saved,x:x,y:y),unmarked=try await pixel(plain,x:x,y:y)
            precondition(abs(after.0-unmarked.0) < 12 && abs(after.1-unmarked.1) < 12,"(\(x),\(y)) \(after) vs \(unmarked)")
        }

        // Marked once: with the quick check gone, the tag in the MP4 still stops a second pass.
        let marked=data(saved)
        removexattr(saved.path,HighlightMark.attribute,XATTR_NOFOLLOW)
        library.markSaved(true,every:.milliseconds(200))
        try await waitUntil("Grey.mp4 recognised") { HighlightMark.isMarked(saved) }
        library.markSaved(false)
        precondition(data(saved) == marked,"a marked clip was marked again")

        // Off: a clip saved now stays as Overwatch wrote it.
        let later=folder.appendingPathComponent("Later.mp4")
        try manager.copyItem(at:plain,to:later)
        try manager.setAttributes([.modificationDate:date],ofItemAtPath:later.path)
        library.reload()
        try await Task.sleep(for:.seconds(1))
        precondition(!HighlightMark.isMarked(later) && data(later) == data(plain),"marked with the mark off")
        for url in [saved,writing,webm,later] { try? manager.removeItem(at:url) }
    }

    /// The hero from the text read off a frame: the intro's line, or the banner with its "BY" line.
    static func heroes() {
        let intro=["HIGHLIGHT","VERYBIGBOI","Mercy's Angel","AS SOLDIER: 76","Recall","Played on MacBook Pro M1 Pro using Recall"]
        precondition(HeroName.from(lines:intro) == "Soldier: 76")
        precondition(HeroName.from(lines:["HIGHLIGHT EMRE","BY VERYBIGBOI","250|250"]) == "Emre")
        precondition(HeroName.from(lines:["AS D.VA"]) == "D.Va")
        precondition(HeroName.from(lines:["AS LUCIO"]) == "Lúcio")
        precondition(HeroName.from(lines:["AS  WRECKING   BALL"]) == "Wrecking Ball")
        precondition(HeroName.from(lines:["as junker queen"]) == "Junker Queen")
        // The intro's "HIGHLIGHT" and the player's name read as one line are not a hero.
        precondition(HeroName.from(lines:["HIGHLIGHT VERYBIGBOI","Mercy's Angel"]) == nil)
        precondition(HeroName.from(lines:["HIGHLIGHT VERYBIGBOI","BY VERYBIGBOI"]) == nil)
        precondition(HeroName.from(lines:["AS RECALL MARK"]) == nil)
        precondition(HeroName.from(lines:["AS 76"]) == nil)
        precondition(HeroName.from(lines:["AS THIS IS FAR TOO LONG TO BE A HERO"]) == nil)
        precondition(HeroName.from(lines:[]) == nil)
    }

    /// The play between the intro's white flash and the black end card, from brightness alone.
    static func parts() {
        func frames(_ spans:[(until:Double,mean:Double,lit:Double)],fps:Double=10)->[FrameBrightness] {
            var result:[FrameBrightness]=[],time=0.0
            for span in spans { while time < span.until { result.append(FrameBrightness(time:time,mean:span.mean,lit:span.lit));time+=1/fps } }
            return result
        }
        let overwatch=frames([(5,0.3,0.9),(5.3,0.97,1),(5.5,0.7,1),(19.2,0.42,0.88),(26.2,0.06,0.05),(26.4,0.22,1),(26.8,0,0)])
        let play=HighlightParts.find(overwatch,duration:26.8)
        precondition(play != nil && abs(play!.lowerBound-5.5) < 0.11 && abs(play!.upperBound-19.2) < 0.11,"\(String(describing:play))")
        // A night map stays well above the end card's dark.
        let night=frames([(4,0.3,0.9),(4.2,0.95,0.99),(18,0.16,0.55),(26,0.05,0.04)])
        precondition(HighlightParts.find(night,duration:26)?.lowerBound ?? 0 >= 4.2)
        // No flash (a clip already cut), no end card, or too short an end card: no play.
        precondition(HighlightParts.find(frames([(14,0.4,0.9)]),duration:14) == nil)
        precondition(HighlightParts.find(frames([(5,0.3,0.9),(5.2,0.97,1),(20,0.4,0.9)]),duration:20) == nil)
        precondition(HighlightParts.find(frames([(5,0.3,0.9),(5.2,0.97,1),(18.5,0.4,0.9),(20,0.05,0.05)]),duration:20) == nil)
        let facts=HighlightFacts(hero:nil,playStart:5.5,playEnd:19.2,duration:26.8)
        precondition(facts.cuttable && facts.play == 5.5...19.2)
        precondition(!HighlightFacts(hero:nil,playStart:0.5,playEnd:13,duration:13.8).cuttable)
    }

    /// The Discord copy's picture: as big as the bit budget keeps clean, never bigger than the clip.
    static func plans() {
        let whole=HighlightEncoder.plan(limit:HighlightEncoder.discordLimit,seconds:26.8,source:CGSize(width:1920,height:1080),fps:60)
        precondition(whole.height == 720 && whole.width == 1280,"\(whole)")
        let play=HighlightEncoder.plan(limit:HighlightEncoder.discordLimit,seconds:13.8,source:CGSize(width:1920,height:1080),fps:60)
        precondition(play.height == 1080,"\(play)")
        let small=HighlightEncoder.plan(limit:HighlightEncoder.discordLimit,seconds:13.8,source:CGSize(width:1280,height:720),fps:60)
        precondition(small.height == 720,"\(small)")
        let long=HighlightEncoder.plan(limit:HighlightEncoder.discordLimit,seconds:120,source:CGSize(width:1920,height:1080),fps:60)
        precondition(long.height == 360 && long.videoBitRate >= 400_000,"\(long)")
        let wide=HighlightEncoder.plan(limit:HighlightEncoder.discordLimit,seconds:26.8,source:CGSize(width:2560,height:1080),fps:60)
        precondition(wide.height == 540 && wide.width == 1280,"\(wide)")  // ultrawide: more pixels a line
        // Each aims under the limit for its own length.
        for (plan,seconds) in [(whole,26.8),(play,13.8),(small,13.8),(long,120),(wide,26.8)] {
            precondition((plan.videoBitRate+plan.audioBitRate)*seconds/8 <= Double(HighlightEncoder.discordLimit)*0.9,"\(plan)")
        }
    }

    /// A highlight shaped like Overwatch's: an intro naming the hero (5 s), a white flash, the play
    /// with its banner, then a black end card to the end. 960 × 540 at 30 fps.
    static func writeHighlight(to url:URL,seconds:Double=24,noise:Bool=false) async throws {
        try? FileManager.default.removeItem(at:url)
        let width=960,height=540
        let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:noise ? 12_000_000 : 3_000_000]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,
            kCVPixelBufferHeightKey as String:height])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime:.zero)
        func draw(_ lines:[String],in context:CGContext,size:CGFloat,y:CGFloat) {
            let previous=NSGraphicsContext.current
            NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
            var top=y
            for line in lines {
                NSAttributedString(string:line,attributes:[.font:NSFont.systemFont(ofSize:size,weight:.heavy),.foregroundColor:NSColor.white])
                    .draw(at:CGPoint(x:60,y:top))
                top-=size*1.5
            }
            NSGraphicsContext.current=previous
        }
        var random=SystemRandomNumberGenerator()
        for frame in 0..<Int(seconds*30) {
            let time=Double(frame)/30
            while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(5)) }
            var pixels:CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&pixels)
            CVPixelBufferLockBaseAddress(pixels!,[])
            let context=CGContext(data:CVPixelBufferGetBaseAddress(pixels!),width:width,height:height,bitsPerComponent:8,
                                  bytesPerRow:CVPixelBufferGetBytesPerRow(pixels!),space:CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
            let end=seconds-7
            if time < 5 {
                context.setFillColor(NSColor(white:0.32,alpha:1).cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
                draw(["HIGHLIGHT","TESTER","AS SOLDIER: 76"],in:context,size:40,y:360)
            } else if time < 5.3 {
                context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
            } else if time < end {
                context.setFillColor(NSColor(white:0.45,alpha:1).cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
                context.setFillColor(NSColor(white:0.65,alpha:1).cgColor)
                context.fill(CGRect(x:Int(time*80)%width,y:120,width:160,height:200))
                if noise {
                    for _ in 0..<1500 {
                        context.setFillColor(NSColor(white:CGFloat.random(in:0...1,using:&random),alpha:1).cgColor)
                        context.fill(CGRect(x:Int.random(in:0..<width,using:&random),y:Int.random(in:0..<height,using:&random),width:12,height:12))
                    }
                }
                draw(["HIGHLIGHT SOLDIER: 76","BY TESTER"],in:context,size:22,y:490)
            } else {
                context.setFillColor(NSColor.black.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
                context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:450,y:240,width:60,height:60))
            }
            CVPixelBufferUnlockBaseAddress(pixels!,[])
            precondition(adaptor.append(pixels!,withPresentationTime:CMTime(value:CMTimeValue(frame),timescale:30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed,"\(String(describing:writer.error))")
    }

    /// The same file, though one path may go through a symlink (/var is /private/var).
    static func same(_ a:URL,_ b:URL)->Bool { a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }

    static func duration(_ url:URL) async throws -> Double { try await AVURLAsset(url:url).load(.duration).seconds }

    /// The window reads the hero and the play once and keeps them in Recall's caches; "Just the
    /// Play" saves the play as a new clip beside the original, which stays as it was; a cut of a
    /// marked clip carries the mark.
    @MainActor static func analysedAndCut() async throws {
        let manager=FileManager.default,folder=HighlightFolder.url
        try manager.createDirectory(at:folder,withIntermediateDirectories:true)
        let saved=folder.appendingPathComponent("Soldier.mp4")
        try await writeHighlight(to:saved)
        try manager.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-300)],ofItemAtPath:saved.path)
        let original=data(saved)

        let (facts,strip)=try await HighlightAnalyzer.analyze(saved)
        precondition(facts.hero == "Soldier: 76","hero \(String(describing:facts.hero))")
        let play=facts.play
        precondition(play != nil && abs(play!.lowerBound-5.3) < 0.25 && abs(play!.upperBound-17) < 0.25 && facts.cuttable,"\(facts)")
        precondition(strip?.width == Int(HighlightAnalyzer.stripFrameSize.width)*HighlightAnalyzer.stripFrames)

        let library=HighlightLibrary()
        library.reload()
        let clip=library.clips.first { same($0.url,saved) }!
        library.prepare(clip)
        try await waitUntil("facts read") { library.facts[clip.url] != nil && library.thumbnails[clip.url] != nil }
        precondition(library.facts[clip.url] == facts,"\(String(describing:library.facts[clip.url]))")
        precondition(library.previews.facts(for:clip) == facts)
        precondition(manager.fileExists(atPath:library.previews.pictureURL(clip,"strip").path))
        // Kept: a new library knows them without reading the clip again.
        let again=HighlightLibrary()
        again.reload()
        precondition(again.facts[again.clips.first { same($0.url,saved) }!.url] == facts)

        await library.cut(clip,to:play!,suffix:"play")
        let cut=folder.appendingPathComponent("Soldier-play.mp4")
        precondition(manager.fileExists(atPath:cut.path),"no cut")
        let length=try await duration(cut)
        precondition(abs(length-(play!.upperBound-play!.lowerBound)) < 0.2,"cut is \(length) s")
        precondition(data(saved) == original,"the original changed")
        precondition(library.clips.contains { same($0.url,cut) } && !library.pending.contains { same($0.url,cut) },"the cut isn't listed as a clip")
        precondition(!HighlightMark.isMarked(cut))
        // The cut still names its hero, from the banner.
        let (cutFacts,_)=try await HighlightAnalyzer.analyze(cut)
        precondition(cutFacts.hero == "Soldier: 76" && cutFacts.play == nil,"\(cutFacts)")
        // A second cut gets its own name.
        await library.cut(clip,to:6...9,suffix:"play")
        precondition(manager.fileExists(atPath:folder.appendingPathComponent("Soldier-play-2.mp4").path))

        // A marked clip's cut carries the mark (tag and quick check), so it's never marked twice.
        HighlightMark.setMarked(saved)
        await library.cut(library.clips.first { same($0.url,saved) }!,to:6...10,suffix:"trim")
        let marked=folder.appendingPathComponent("Soldier-trim.mp4")
        let tagged=await HighlightMark.carriesTag(marked)
        precondition(HighlightMark.isMarked(marked) && tagged,"the cut of a marked clip isn't marked")

        // Previews of clips that are gone are forgotten.
        try manager.removeItem(at:saved)
        library.reload()
        library.tidy()
        precondition(library.previews.facts(for:clip) == nil && !manager.fileExists(atPath:library.previews.pictureURL(clip,"strip").path))
        for name in ["Soldier-play.mp4","Soldier-play-2.mp4","Soldier-trim.mp4"] { try? manager.removeItem(at:folder.appendingPathComponent(name)) }
    }

    /// Copy for Discord: a clip that fits goes as itself; a larger one as a smaller copy under the
    /// limit (here 4 MB, as the real 19 MB needs a far longer clip), whole and playable.
    @MainActor static func discordCopy() async throws {
        let manager=FileManager.default
        let scratch=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("recall-discord-\(getpid())")
        try manager.createDirectory(at:scratch,withIntermediateDirectories:true)
        defer { try? manager.removeItem(at:scratch) }
        let busy=scratch.appendingPathComponent("busy.mp4")
        try await writeHighlight(to:busy,seconds:20,noise:true)
        let bytes=Int64(try busy.resourceValues(forKeys:[.fileSizeKey]).fileSize!)
        let limit:Int64=4_000_000
        precondition(bytes > limit,"the test clip is only \(bytes) bytes")
        let copy=scratch.appendingPathComponent("copy.mp4")
        try await HighlightEncoder.smallCopy(busy,to:copy,limit:limit)
        let written=Int64(try copy.resourceValues(forKeys:[.fileSizeKey]).fileSize!)
        precondition(written <= limit,"copy is \(written) bytes")
        let copied=try await duration(copy),source=try await duration(busy)
        precondition(abs(copied-source) < 0.2,"copy is \(copied) s of \(source)")
        let fits=scratch.appendingPathComponent("fits.mp4")
        try await HighlightEncoder.smallCopy(busy,to:fits,limit:bytes+1)
        precondition(data(fits) == data(busy),"a clip that fits was changed")
    }
}
