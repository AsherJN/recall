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
        try Data().write(to:folder.appendingPathComponent("Writing.mp4"))      // still empty: Overwatch is writing it
        try Data("x".utf8).write(to:folder.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to:folder.appendingPathComponent(".hidden.mp4"))
        let library=HighlightLibrary()
        library.reload()
        precondition(library.clips.map(\.url.lastPathComponent) == ["Tracer.webm","Genji.mp4"],"\(library.clips.map(\.url.lastPathComponent))")
        precondition(!library.clips[0].playable && library.clips[1].playable)
        // A clip Overwatch rewrites is a new clip to the marker.
        let clip=library.clips[1]
        precondition(HighlightClip(url:clip.url,date:clip.date,bytes:clip.bytes+1).identity != clip.identity)
        // A share hands over the file itself.
        let shared=await library.shareable(library.clips[0])
        precondition(shared == library.clips[0].url)
        for name in ["Genji.mp4","Tracer.webm","Writing.mp4","notes.txt",".hidden.mp4"] {
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
}
