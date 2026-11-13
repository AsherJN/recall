// Checks an MPEG-4 file the way a Mac player would open it: AVFoundation must
// see one H.264 and one AAC track, decode every frame and every sample, find
// the test pattern's frame numbers in order and the two tones at 440 and 880 Hz
// starting with the picture.
//
//   swift verify_mp4.swift <file.mp4> <width> <height> <fps> <seconds> [--pattern] [--channels N]
//
// Prints one JSON object; exits 1 when a check fails.

import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 6, let width = Int(args[2]), let height = Int(args[3]), let fps = Double(args[4]),
      let seconds = Double(args[5]) else {
    FileHandle.standardError.write("usage: verify_mp4.swift <file> <width> <height> <fps> <seconds> [--pattern]\n".data(using: .utf8)!)
    exit(2)
}
let checkPattern = args.contains("--pattern")
let expectedChannels: Int = {
    if let index = args.firstIndex(of: "--channels"), index + 1 < args.count, let value = Int(args[index + 1]) { return value }
    return 2
}()
let url = URL(fileURLWithPath: args[1])
var failures: [String] = []
var report: [String: Any] = [:]

func fail(_ message: String) { failures.append(message) }

// Top-level boxes, to check the index ("moov") comes before the media ("mdat").
func topLevelBoxes(_ url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
    var boxes: [String] = []
    var offset = 0
    while offset + 8 <= data.count {
        var size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? "????"
        if size == 1, offset + 16 <= data.count {
            size = 0
            for i in 8..<16 { size = size << 8 | Int(data[offset + i]) }
        } else if size == 0 { size = data.count - offset }
        boxes.append(type)
        if size < 8 { break }
        offset += size
    }
    return boxes
}

let boxes = topLevelBoxes(url)
report["boxes"] = boxes
if let moov = boxes.firstIndex(of: "moov"), let mdat = boxes.firstIndex(of: "mdat") {
    if moov > mdat { fail("moov after mdat (not optimized for streaming)") }
} else { fail("missing moov or mdat") }

let asset = AVURLAsset(url: url)
let semaphore = DispatchSemaphore(value: 0)
var videoTracks: [AVAssetTrack] = []
var audioTracks: [AVAssetTrack] = []
var duration = CMTime.zero
Task {
    do {
        videoTracks = try await asset.loadTracks(withMediaType: .video)
        audioTracks = try await asset.loadTracks(withMediaType: .audio)
        duration = try await asset.load(.duration)
    } catch { fail("load: \(error)") }
    semaphore.signal()
}
semaphore.wait()

report["duration"] = duration.seconds
if abs(duration.seconds - seconds) > 0.1 { fail("duration \(duration.seconds) s, expected \(seconds)") }
guard videoTracks.count == 1, audioTracks.count == 1 else {
    fail("tracks: \(videoTracks.count) video, \(audioTracks.count) audio")
    print(String(data: try! JSONSerialization.data(withJSONObject: ["failures": failures, "report": report]), encoding: .utf8)!)
    exit(1)
}

func fourcc(_ code: FourCharCode) -> String {
    let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "?"
}

func descriptions(_ track: AVAssetTrack) -> [CMFormatDescription] {
    var result: [CMFormatDescription] = []
    let done = DispatchSemaphore(value: 0)
    Task {
        result = (try? await track.load(.formatDescriptions)) ?? []
        done.signal()
    }
    done.wait()
    return result
}

let video = videoTracks[0], audio = audioTracks[0]
if let format = descriptions(video).first {
    let codec = fourcc(CMFormatDescriptionGetMediaSubType(format))
    let dims = CMVideoFormatDescriptionGetDimensions(format)
    report["video_codec"] = codec
    report["video_size"] = "\(dims.width)x\(dims.height)"
    if codec != "avc1" { fail("video codec \(codec)") }
    if Int(dims.width) != width || Int(dims.height) != height { fail("video size \(dims.width)x\(dims.height)") }
} else { fail("no video format") }
if let format = descriptions(audio).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
    let codec = fourcc(asbd.mFormatID)
    report["audio_codec"] = codec
    report["audio_rate"] = asbd.mSampleRate
    report["audio_channels"] = asbd.mChannelsPerFrame
    if codec != "aac " { fail("audio codec \(codec)") }
    if Int(asbd.mChannelsPerFrame) != expectedChannels { fail("audio channels \(asbd.mChannelsPerFrame)") }
} else { fail("no audio format") }

// Decode every video frame.
do {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    var frames = 0, outOfOrder = 0, wrongNumber = 0, wrongBars = 0
    var firstTime = -1.0, lastNumber = -1
    while let sample = output.copyNextSampleBuffer() {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if firstTime < 0 { firstTime = time }
        if checkPattern {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            var number = 0
            for bit in 0..<16 {
                let p = base + 8 * stride + (bit * 16 + 8) * 4
                if Int(p[1]) > 128 { number |= 1 << bit }
            }
            let expected = Int((time * fps).rounded())
            if number != expected & 0xffff { wrongNumber += 1 }
            if number <= lastNumber { outOfOrder += 1 }
            lastNumber = number
            // Bar under the middle of the frame.
            let x = width / 2 + 3, y = height / 2
            let shifted = (x + width - (expected * 8) % width) % width
            let bar = shifted * 8 / width
            let colors: [[Int]] = [[235, 235, 235], [235, 235, 16], [16, 235, 235], [16, 235, 16],
                                   [235, 16, 235], [235, 16, 16], [16, 16, 235], [16, 16, 16]]
            // Decoded to full-range RGB, so map the video-range values.
            let want = colors[bar].map { Double($0 - 16) * 255.0 / 219.0 }
            let p = base + y * stride + x * 4
            let got = [Double(p[2]), Double(p[1]), Double(p[0])]
            if zip(want, got).contains(where: { abs($0 - $1) > 40 }) { wrongBars += 1 }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        frames += 1
    }
    if reader.status != .completed { fail("video decode: \(String(describing: reader.error))") }
    report["video_frames"] = frames
    report["video_first_time"] = firstTime
    let expectedFrames = Int(fps * seconds)
    if abs(frames - expectedFrames) > 1 { fail("video frames \(frames), expected \(expectedFrames)") }
    if abs(firstTime) > 0.001 { fail("video starts at \(firstTime)") }
    if checkPattern {
        report["frames_wrong_number"] = wrongNumber
        report["frames_out_of_order"] = outOfOrder
        report["frames_wrong_bars"] = wrongBars
        if wrongNumber > 0 { fail("\(wrongNumber) frames show the wrong frame number") }
        if outOfOrder > 0 { fail("\(outOfOrder) frames out of order") }
        if wrongBars > frames / 20 { fail("\(wrongBars) frames show the wrong bar colour") }
    }
} catch { fail("video reader: \(error)") }

// Decode all audio to 32-bit float and find the tones.
do {
    let reader = try AVAssetReader(asset: asset)
    var settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
    if expectedChannels == 6 {
        // Ask for L R C LFE Ls Rs: the decoder maps by the file's channel labels, so this checks them too.
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        settings[AVNumberOfChannelsKey] = 6
    }
    let output = AVAssetReaderTrackOutput(track: audio, outputSettings: settings)
    reader.add(output)
    reader.startReading()
    var samples: [Float] = []
    var rate = 0.0, firstTime = -1.0, channels = 2
    while let sample = output.copyNextSampleBuffer() {
        if firstTime < 0 { firstTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
        if rate == 0, let format = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            rate = asbd.mSampleRate
            channels = Int(asbd.mChannelsPerFrame)
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / 4)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        samples.append(contentsOf: chunk)
    }
    if reader.status != .completed { fail("audio decode: \(String(describing: reader.error))") }
    let frames = samples.count / channels
    report["audio_seconds"] = rate > 0 ? Double(frames) / rate : 0
    report["audio_first_time"] = firstTime
    if rate > 0, abs(Double(frames) / rate - seconds) > 0.05 { fail("audio lasts \(Double(frames) / rate) s") }
    if abs(firstTime) > 0.001 { fail("audio starts at \(firstTime)") }
    // Frequency from zero crossings over the middle second of each channel.
    func frequency(channel: Int) -> Double {
        let start = Int(rate * 0.5), end = min(frames, start + Int(rate))
        var crossings = 0
        for i in (start + 1)..<end where (samples[channels * (i - 1) + channel] < 0) != (samples[channels * i + channel] < 0) { crossings += 1 }
        return Double(crossings) / 2.0 / (Double(end - start) / rate)
    }
    let left = frequency(channel: 0), right = frequency(channel: 1)
    report["left_hz"] = left
    report["right_hz"] = right
    if abs(left - 440) > 5 { fail("left channel at \(left) Hz") }
    if abs(right - 880) > 5 { fail("right channel at \(right) Hz") }
    // The tone starts at time zero: the first loud sample is within 5 ms of the start.
    if let first = (0..<frames).first(where: { abs(samples[channels * $0]) > 0.05 }) {
        report["audio_onset_ms"] = Double(first) / rate * 1000
        if Double(first) / rate > 0.005 { fail("tone starts \(Double(first) / rate * 1000) ms late (priming not trimmed?)") }
    } else { fail("audio is silent") }
} catch { fail("audio reader: \(error)") }

report["failures"] = failures
print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
exit(failures.isEmpty ? 0 : 1)
