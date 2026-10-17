import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import DownhaulCore

/// AVFoundation encoding and exporting need a media session; a virtualised CI Mac has none and blocks forever,
/// so the tests that need them run only where DOWNHAUL_SKIP_AV is unset.
let avAvailable = ProcessInfo.processInfo.environment["DOWNHAUL_SKIP_AV"] != "1"

/// Makes the kind of files a DASH site serves: a video-only MP4 and an audio-only MP4, one second each.
enum Fixtures {
    static func videoOnly(at url: URL, width: Int = 64, height: Int = 48, seconds: Double = 1) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 10)
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw DownloadFailure("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20 & 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            var waited = 0
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01); waited += 1; if waited > 1000 { throw DownloadFailure("video fixture: the encoder never became ready") } }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 30) == .success else { throw DownloadFailure("video fixture: the encoder never finished") }
        guard writer.status == .completed else { throw writer.error ?? DownloadFailure("video fixture failed") }
    }

    static func audioOnly(at url: URL, seconds: Double = 1) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let framesPerChunk = 4410
        let chunks = Int(seconds * 10)
        for chunk in 0..<chunks {
            var samples = [Int16](repeating: 0, count: framesPerChunk)
            for i in 0..<framesPerChunk { samples[i] = Int16(sin(Double(chunk * framesPerChunk + i) * 2 * .pi * 440 / 44100) * 8000) }
            let data = samples.withUnsafeBytes { Data($0) }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
            _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: data.count) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: framesPerChunk,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(chunk * framesPerChunk), timescale: 44100), packetDescriptions: nil, sampleBufferOut: &sample)
            var waited = 0
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01); waited += 1; if waited > 1000 { throw DownloadFailure("audio fixture: the encoder never became ready") } }
            input.append(sample!)
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 30) == .success else { throw DownloadFailure("audio fixture: the encoder never finished") }
        guard writer.status == .completed else { throw writer.error ?? DownloadFailure("audio fixture failed") }
    }
}

@Suite(.enabled(if: avAvailable, "needs a media session"))
struct MuxerTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("downhaul-mux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func joinsAVideoOnlyAndAnAudioOnlyFileWithoutReencoding() async throws {
        let video = folder.appendingPathComponent("v.mp4"), audio = folder.appendingPathComponent("a.mp4"), out = folder.appendingPathComponent("joined.mp4")
        try Fixtures.videoOnly(at: video)
        try Fixtures.audioOnly(at: audio)
        let info = try await Muxer.join(video: video, audio: audio, into: out)
        #expect(info.hasVideo && info.hasAudio)
        let tracks = try #require(await MediaInfo.inspect(out))
        #expect(tracks.hasVideo && tracks.hasAudio)
        #expect(abs(tracks.duration - 1) < 0.2)
        #expect(tracks.width == 64 && tracks.height == 48)
    }

    @Test func inspectReportsSilentVideo() async throws {
        let video = folder.appendingPathComponent("silent.mp4")
        try Fixtures.videoOnly(at: video)
        let info = try #require(await MediaInfo.inspect(video))
        #expect(info.hasVideo && !info.hasAudio)
        #expect(await MediaInfo.inspect(URL(fileURLWithPath: "/nonexistent.mp4")) == nil)
    }

    @Test func joiningFailsClearlyWhenAnInputIsNotMedia() async throws {
        let video = folder.appendingPathComponent("v.mp4"), junk = folder.appendingPathComponent("junk.mp4")
        try Fixtures.videoOnly(at: video)
        try Data("not a file".utf8).write(to: junk)
        await #expect(throws: DownloadFailure.self) { try await Muxer.join(video: video, audio: junk, into: folder.appendingPathComponent("x.mp4")) }
    }
}
