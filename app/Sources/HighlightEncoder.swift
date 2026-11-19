import AVFoundation

/// New clips made from a saved highlight: a cut ("Just the Play", Trim) at the clip's own size and
/// quality, and a copy small enough for Discord. H.264 and AAC, as Overwatch saves, so they play
/// everywhere, Discord on Windows included. The original is never changed.
enum HighlightEncoder {
    /// Discord's limit for a free account is 20 MB a file (since August 2026); Recall aims under
    /// 19 MB, so it holds however Discord counts a megabyte.
    static let discordLimit:Int64=19_000_000

    struct Plan:Equatable {
        var width:Int
        var height:Int
        var videoBitRate:Double
        var audioBitRate:Double=128_000
    }

    /// The largest picture (1080, 720, 540 or 360 lines, never more than the clip's) that still
    /// gets enough of the bit budget per pixel to look clean at 60 fps, for a copy of SECONDS that
    /// fits LIMIT. The encoder lands under its target, so 88% of the limit is the target.
    static func plan(limit:Int64,seconds:Double,source:CGSize,fps:Double)->Plan {
        let audio=128_000.0
        let video=max(400_000,Double(limit)*0.88*8/max(seconds,1)-audio)
        let aspect=source.width/max(source.height,1)
        let heights=[1080.0,720,540,360].filter { $0 <= source.height }
        var pick=(width:Int(source.width),height:Int(source.height))
        for height in heights.isEmpty ? [source.height] : heights {
            let width=(height*aspect/2).rounded()*2
            pick=(Int(width),Int(height))
            if video/(width*height*max(fps,30)) >= 0.07 { break }
        }
        return Plan(width:pick.width,height:pick.height,videoBitRate:video,audioBitRate:audio)
    }

    /// The clip's own size and about its own bit rate, for a cut that looks like the original.
    static func samePlan(for track:AVAssetTrack) async throws -> Plan {
        let size=try await track.load(.naturalSize)
        let rate=Double(try await track.load(.estimatedDataRate))
        let fallback=size.width*size.height*60*0.1
        return Plan(width:Int(size.width),height:Int(size.height),videoBitRate:max(2_000_000,rate > 0 ? rate : fallback))
    }

    /// Writes SOURCE's RANGE (all of it when nil) to DESTINATION with PLAN. TAG is the software
    /// entry a marked clip carries (HighlightMark.tag), so a cut of a marked clip isn't marked again.
    /// PROGRESS runs on a background queue, 0–1.
    static func encode(_ source:URL,to destination:URL,range:CMTimeRange?=nil,plan:Plan?=nil,tag:String?=nil,
                       progress:@escaping @Sendable (Double)->Void={ _ in }) async throws {
        let asset=AVURLAsset(url:source)
        guard let video=try await asset.loadTracks(withMediaType:.video).first else { throw CocoaError(.fileReadCorruptFile) }
        let audio=try await asset.loadTracks(withMediaType:.audio).first
        let duration=try await asset.load(.duration)
        let span=range ?? CMTimeRange(start:.zero,duration:duration)
        let plan=try await { if let plan { return plan };return try await samePlan(for:video) }()
        let fps=Double(try await video.load(.nominalFrameRate))
        try? FileManager.default.removeItem(at:destination)

        let reader=try AVAssetReader(asset:asset)
        reader.timeRange=span
        let pictures=AVAssetReaderTrackOutput(track:video,outputSettings:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        pictures.alwaysCopiesSampleData=false
        reader.add(pictures)
        var sound:AVAssetReaderTrackOutput?
        if let audio {
            let output=AVAssetReaderTrackOutput(track:audio,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM])
            reader.add(output)
            sound=output
        }
        let writer=try AVAssetWriter(outputURL:destination,fileType:.mp4)
        writer.shouldOptimizeForNetworkUse=true
        if let tag {
            let item=AVMutableMetadataItem()
            item.identifier = .commonIdentifierSoftware
            item.value=tag as NSString
            writer.metadata=[item]
        }
        var compression:[String:Any]=[AVVideoAverageBitRateKey:plan.videoBitRate,
                                      AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel,
                                      AVVideoMaxKeyFrameIntervalDurationKey:2,AVVideoAllowFrameReorderingKey:true]
        if fps > 0 { compression[AVVideoExpectedSourceFrameRateKey]=fps }
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:[
            AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:plan.width,AVVideoHeightKey:plan.height,
            AVVideoScalingModeKey:AVVideoScalingModeResizeAspect,AVVideoCompressionPropertiesKey:compression])
        videoInput.expectsMediaDataInRealTime=false
        writer.add(videoInput)
        var audioInput:AVAssetWriterInput?
        if sound != nil {
            let input=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48_000,
                                                                          AVNumberOfChannelsKey:2,AVEncoderBitRateKey:plan.audioBitRate])
            input.expectsMediaDataInRealTime=false
            writer.add(input)
            audioInput=input
        }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        guard writer.startWriting() else { reader.cancelReading();throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime:span.start)

        let length=max(span.duration.seconds,0.001),start=span.start.seconds
        await withTaskCancellationHandler {
            await withTaskGroup(of:Void.self) { group in
                for (input,output,reports) in [(videoInput,pictures as AVAssetReaderTrackOutput?,true),(audioInput,sound,false)] {
                    guard let input,let output else { continue }
                    let pump=Pump(reader:reader,output:output,input:input)
                    group.addTask {
                        await withCheckedContinuation { (done:CheckedContinuation<Void,Never>) in
                            let queue=DispatchQueue(label:"org.overwatch2mac.highlight-encoder",qos:.userInitiated)
                            pump.input.requestMediaDataWhenReady(on:queue) {
                                while pump.input.isReadyForMoreMediaData {
                                    guard pump.reader.status == .reading,let sample=pump.output.copyNextSampleBuffer() else {
                                        pump.input.markAsFinished();done.resume();return
                                    }
                                    if reports { progress(min(1,max(0,(CMSampleBufferGetPresentationTimeStamp(sample).seconds-start)/length))) }
                                    if !pump.input.append(sample) { pump.reader.cancelReading();pump.input.markAsFinished();done.resume();return }
                                }
                            }
                        }
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()
        }
        if Task.isCancelled || reader.status != .completed || writer.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at:destination)
            if Task.isCancelled { throw CancellationError() }
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at:destination)
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// One track's reader output and writer input, which AVFoundation drives from its own queue,
    /// one sample at a time.
    private struct Pump:@unchecked Sendable {
        let reader:AVAssetReader
        let output:AVAssetReaderTrackOutput
        let input:AVAssetWriterInput
    }

    /// A copy of SOURCE under LIMIT, at DESTINATION: the file itself when it already fits, else a
    /// smaller encode, tried once more at a lower rate if the encoder overshot.
    static func smallCopy(_ source:URL,to destination:URL,limit:Int64=discordLimit,tag:String?=nil,
                          progress:@escaping @Sendable (Double)->Void={ _ in }) async throws {
        let bytes=(try source.resourceValues(forKeys:[.fileSizeKey]).fileSize).map(Int64.init) ?? .max
        try? FileManager.default.removeItem(at:destination)
        if bytes <= limit { try FileManager.default.copyItem(at:source,to:destination);return }
        let asset=AVURLAsset(url:source)
        guard let video=try await asset.loadTracks(withMediaType:.video).first else { throw CocoaError(.fileReadCorruptFile) }
        let seconds=try await asset.load(.duration).seconds
        let size=try await video.load(.naturalSize),fps=Double(try await video.load(.nominalFrameRate))
        var plan=plan(limit:limit,seconds:seconds,source:size,fps:fps)
        for _ in 0..<2 {
            try await encode(source,to:destination,plan:plan,tag:tag,progress:progress)
            let written=(try destination.resourceValues(forKeys:[.fileSizeKey]).fileSize).map(Int64.init) ?? .max
            if written <= limit { return }
            plan.videoBitRate*=0.75
        }
        try? FileManager.default.removeItem(at:destination)
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
