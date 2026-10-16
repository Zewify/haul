import Foundation
import Testing
@testable import HaulCore

struct DASHManifestTests {
    let base = URL(string: "https://cdn.example/videos/bbb/manifest.mpd")!

    func plan(_ xml: String) throws -> StreamPlan { try DASHManifest.plan(Data(xml.utf8), base: base) }

    /// The shape of the dash.js reference stream: numbered templates per representation, picture and sound apart.
    @Test func numberedTemplatePicksTheTallestH264AndTheRichestAudio() throws {
        let p = try plan("""
        <?xml version="1.0"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT0H0M10.0S">
          <Period>
            <AdaptationSet mimeType="video/mp4" contentType="video">
              <SegmentTemplate media="$RepresentationID$/seg_$Number%05d$.m4v" initialization="$RepresentationID$/init.mp4" duration="4" startNumber="1"/>
              <Representation id="v720" codecs="avc1.640028" width="1280" height="720" bandwidth="3000000"/>
              <Representation id="v1080" codecs="avc1.640032" width="1920" height="1080" bandwidth="6000000"/>
              <Representation id="v2160hevc" codecs="hvc1.2.4.L153" width="3840" height="2160" bandwidth="16000000"/>
              <Representation id="vp9" codecs="vp09.00.40.08" width="3840" height="2160" bandwidth="12000000"/>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="en">
              <SegmentTemplate media="$RepresentationID$/seg_$Number$.m4a" initialization="$RepresentationID$/init.mp4" duration="4"/>
              <Representation id="a64" codecs="mp4a.40.2" bandwidth="64000"/>
              <Representation id="a128" codecs="mp4a.40.2" bandwidth="128000"/>
            </AdaptationSet>
            <AdaptationSet mimeType="text/vtt"><Representation id="subs" bandwidth="1"><BaseURL>en.vtt</BaseURL></Representation></AdaptationSet>
          </Period>
        </MPD>
        """)
        #expect(p.video.map?.uri.absoluteString == "https://cdn.example/videos/bbb/v1080/init.mp4")
        // 10 s in 4 s segments is three segments, the last one short.
        #expect(p.video.segments.map(\.uri.lastPathComponent) == ["seg_00001.m4v", "seg_00002.m4v", "seg_00003.m4v"])
        #expect(p.video.segments[0].uri.absoluteString == "https://cdn.example/videos/bbb/v1080/seg_00001.m4v")
        let audio = try #require(p.audio)
        #expect(audio.segments.first?.uri.absoluteString == "https://cdn.example/videos/bbb/a128/seg_1.m4a")
        #expect(p.video.fileExtension == "mp4")
    }

    @Test func timelineWithRepeatsNamesSegmentsByTime() throws {
        let p = try plan("""
        <MPD type="static" mediaPresentationDuration="PT12S"><Period>
          <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.4d401f">
            <SegmentTemplate timescale="1000" media="v/$Bandwidth$/$Time$.m4s" initialization="v/$Bandwidth$/init.m4s">
              <SegmentTimeline><S t="0" d="4000" r="1"/><S d="3000"/><S d="1000" r="-1"/></SegmentTimeline>
            </SegmentTemplate>
            <Representation id="1" bandwidth="500000" height="480"/>
          </AdaptationSet>
        </Period></MPD>
        """)
        #expect(p.video.segments.map(\.uri.lastPathComponent) == ["0.m4s", "4000.m4s", "8000.m4s", "11000.m4s"])
        #expect(p.video.segments.allSatisfy { $0.uri.path.contains("/v/500000/") })
        #expect(p.audio == nil)
    }

    @Test func segmentListWithRangesInOneFile() throws {
        let p = try plan("""
        <MPD type="static" mediaPresentationDuration="PT8S"><Period><AdaptationSet mimeType="video/mp4">
          <Representation id="v" codecs="avc1.42c01e" height="360" bandwidth="1">
            <BaseURL>https://media.example/v.mp4</BaseURL>
            <SegmentList timescale="1" duration="4">
              <Initialization range="0-799"/>
              <SegmentURL mediaRange="800-4999"/><SegmentURL mediaRange="5000-9999"/>
            </SegmentList>
          </Representation>
        </AdaptationSet></Period></MPD>
        """)
        #expect(p.video.map == StreamSegment(uri: URL(string: "https://media.example/v.mp4")!, range: 0...799))
        #expect(p.video.segments.map(\.range) == [800...4999, 5000...9999])
        #expect(p.video.wholeFile == nil)
    }

    /// Facebook's manifests, and many others: each representation is one whole file, nested BaseURLs resolved in turn.
    @Test func segmentBaseIsAWholeFileResolvedThroughEveryBaseURL() throws {
        let p = try plan("""
        <MPD type="static" mediaPresentationDuration="PT30S"><BaseURL>https://cdn.example/a/b/</BaseURL><Period>
          <AdaptationSet mimeType="video/mp4"><BaseURL>video/</BaseURL>
            <Representation id="v" codecs="avc1.64001f" height="720" bandwidth="2"><BaseURL>720.mp4?sig=x&amp;e=1</BaseURL><SegmentBase indexRange="800-1500"/></Representation>
          </AdaptationSet>
          <AdaptationSet mimeType="audio/mp4">
            <Representation id="a" codecs="mp4a.40.5" bandwidth="1"><BaseURL>../audio.m4a</BaseURL></Representation>
          </AdaptationSet>
        </Period></MPD>
        """)
        #expect(p.video.wholeFile?.absoluteString == "https://cdn.example/a/b/video/720.mp4?sig=x&e=1")
        #expect(p.audio?.wholeFile?.absoluteString == "https://cdn.example/a/audio.m4a")
    }

    /// Vimeo's manifests carry CENC protection on the video: nothing a download can play.
    @Test func protectedVideoIsDRM() {
        #expect(throws: DASHManifest.ParseError.drm) {
            try plan("""
            <MPD xmlns:cenc="urn:mpeg:cenc:2013" type="static" mediaPresentationDuration="PT1M"><Period>
              <AdaptationSet bitstreamSwitching="true"><ContentComponent contentType="video"/>
                <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="00"/>
                <Representation id="v" mimeType="video/mp4" codecs="avc1.64001f" height="720" bandwidth="1"><BaseURL>v.mp4</BaseURL></Representation>
              </AdaptationSet>
            </Period></MPD>
            """)
        }
    }

    @Test func liveStreamsAreRefused() {
        #expect(throws: DASHManifest.ParseError.live) { try plan(#"<MPD type="dynamic"><Period/></MPD>"#) }
    }

    @Test func onlyVP9IsNothingAMacCanPlay() {
        #expect(throws: DASHManifest.ParseError.noPlayableVideo) {
            try plan(#"<MPD type="static" mediaPresentationDuration="PT5S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="v" codecs="vp09.00.10.08" bandwidth="1"/></AdaptationSet></Period></MPD>"#)
        }
    }

    @Test func notAManifest() {
        #expect(throws: DASHManifest.ParseError.notAManifest) { try plan("<html><body>Sign in</body></html>") }
    }

    /// A pre-roll period before the programme: the longest period is the one worth saving.
    @Test func theLongestPeriodIsTheProgramme() throws {
        let p = try plan("""
        <MPD type="static" mediaPresentationDuration="PT65S">
          <Period id="ad" start="PT0S"><AdaptationSet mimeType="video/mp4"><Representation id="ad" codecs="avc1.4d401f" bandwidth="1"><BaseURL>ad.mp4</BaseURL></Representation></AdaptationSet></Period>
          <Period id="main" start="PT5S"><AdaptationSet mimeType="video/mp4"><Representation id="main" codecs="avc1.4d401f" bandwidth="1"><BaseURL>main.mp4</BaseURL></Representation></AdaptationSet></Period>
        </MPD>
        """)
        #expect(p.video.wholeFile?.lastPathComponent == "main.mp4")
    }

    @Test func durationsAndTemplates() {
        #expect(DASHManifest.duration("PT1H2M3.5S") == 3723.5)
        #expect(DASHManifest.duration("P1DT1S") == 86401)
        #expect(DASHManifest.duration("PT0S") == 0)
        #expect(DASHManifest.duration("5S") == nil)
        #expect(DASHManifest.substitute("$RepresentationID$-$Number%03d$-$$-$Time$", id: "v1", bandwidth: "9", number: 7, time: 40) == "v1-007-$-40")
    }
}
