import AVFoundation
import Foundation

/// What a media file holds, for labelling rows and for deciding whether a join worked.
public struct MediaInfo: Sendable, Hashable {
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var duration: Double
    public var width: Int
    public var height: Int

    /// nil when the file cannot be read as media at all.
    public static func inspect(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), let duration = try? await asset.load(.duration), !tracks.isEmpty else { return nil }
        var info = MediaInfo(hasVideo: false, hasAudio: false, duration: CMTimeGetSeconds(duration), width: 0, height: 0)
        for track in tracks {
            if track.mediaType == .video {
                info.hasVideo = true
                if let size = try? await track.load(.naturalSize) { info.width = Int(size.width); info.height = Int(size.height) }
            } else if track.mediaType == .audio {
                info.hasAudio = true
            }
        }
        return info
    }
}

/// Joins a video-only file and an audio-only file into one MP4 by copying their tracks, never re-encoding:
/// what a site that streams DASH separately needs on the way to a file that plays with sound.
public enum Muxer {
    public static func join(video videoURL: URL, audio audioURL: URL, into output: URL) async throws -> MediaInfo {
        let video = AVURLAsset(url: videoURL), audio = AVURLAsset(url: audioURL)
        guard let videoTrack = try? await video.loadTracks(withMediaType: .video).first else {
            throw DownloadFailure("The video part could not be read.")
        }
        guard let audioTrack = try? await audio.loadTracks(withMediaType: .audio).first else {
            throw DownloadFailure("The audio part could not be read.")
        }
        let composition = AVMutableComposition()
        do {
            let videoDuration = try await video.load(.duration), audioDuration = try await audio.load(.duration)
            guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw DownloadFailure("Could not set up the join.")
            }
            try v.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
            try a.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero)
            v.preferredTransform = try await videoTrack.load(.preferredTransform)
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure("Could not join the parts: \(error.localizedDescription)")
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadFailure("This Mac cannot join these parts.")
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await export.export(to: output, as: .mp4)
        } catch {
            throw DownloadFailure("Joining failed: \(error.localizedDescription)")
        }
        guard let info = await MediaInfo.inspect(output), info.hasVideo, info.hasAudio else {
            throw DownloadFailure("The joined file is missing a track.")
        }
        return info
    }
}
