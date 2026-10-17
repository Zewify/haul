import Testing
@testable import KomizoCore

struct PlannerTests {
    let mib: Int64 = 1 << 20

    @Test func splitsEvenlyWithoutGapsOrOverlap() {
        let segments = SegmentPlanner.plan(size: 10 * mib, connections: 4)
        #expect(segments.count == 4)
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == 10 * mib - 1)
        for (a, b) in zip(segments, segments.dropFirst()) { #expect(b.start == a.end + 1) }
        #expect(segments.map(\.length).reduce(0, +) == 10 * mib)
        #expect(segments.map(\.length).max()! - segments.map(\.length).min()! <= 1)
    }

    @Test func smallFilesGetOneSegment() {
        #expect(SegmentPlanner.plan(size: 700 * 1024, connections: 4).count == 1)
        #expect(SegmentPlanner.plan(size: 0, connections: 4).count == 1)
        #expect(SegmentPlanner.plan(size: 1, connections: 4) == [Segment(start: 0, end: 0)])
    }

    @Test func segmentFloorLimitsTheCount() {
        #expect(SegmentPlanner.plan(size: 3 * mib, connections: 32).count == 6)
        #expect(SegmentPlanner.plan(size: 100 * mib, connections: 32).count == 32)
    }

    @Test func rebalanceSplitsTheLargestRemaining() {
        let segments = [
            Segment(start: 0, end: 10 * mib - 1, written: 10 * mib),      // done
            Segment(start: 10 * mib, end: 20 * mib - 1, written: 1 * mib), // 9 MiB left
            Segment(start: 20 * mib, end: 30 * mib - 1, written: 7 * mib), // 3 MiB left
        ]
        let split = SegmentPlanner.rebalance(segments)
        #expect(split?.donor == 1)
        let new = split!.newSegment
        // The donor keeps the first half of what it still has to do; the new segment takes the rest.
        #expect(new.start == 10 * mib + 1 * mib + (9 * mib) / 2)
        #expect(new.end == 20 * mib - 1)
        #expect(new.written == 0)
        #expect(split!.donorEnd == new.start - 1)
    }

    @Test func rebalanceDeclinesSmallRemainders() {
        let segments = [Segment(start: 0, end: 3 * mib - 1, written: 2 * mib)]  // 1 MiB left
        #expect(SegmentPlanner.rebalance(segments) == nil)
        #expect(SegmentPlanner.rebalance([]) == nil)
    }
}
