/// How a download is cut into connections, and how idle connections take over the tail of a busy one.
public enum SegmentPlanner {
    /// Below this a download is one segment; a segment is never shorter than the floor.
    public static let splitThreshold: Int64 = 1 << 20
    public static let segmentFloor: Int64 = 512 << 10
    /// A segment with more than this left can donate its second half to an idle connection.
    public static let rebalanceThreshold: Int64 = 2 << 20

    /// Equal segments covering `0...size-1`, as many as the connection limit and the floor allow.
    public static func plan(size: Int64, connections: Int) -> [Segment] {
        guard size > 0 else { return [Segment(start: 0, end: max(0, size - 1))] }
        let byFloor = max(1, size / segmentFloor)
        let count = size < splitThreshold ? 1 : Int(min(Int64(max(1, connections)), byFloor))
        let base = size / Int64(count)
        let extra = size % Int64(count)   // the first `extra` segments take one more byte
        var segments: [Segment] = []
        var start: Int64 = 0
        for index in 0..<count {
            let length = base + (Int64(index) < extra ? 1 : 0)
            segments.append(Segment(start: start, end: start + length - 1))
            start += length
        }
        return segments
    }

    public struct Split: Hashable, Sendable {
        /// Index of the segment giving up its tail.
        public var donor: Int
        /// The donor's new last byte.
        public var donorEnd: Int64
        public var newSegment: Segment
    }

    /// Splits the unwritten tail of the segment with the most left, when that is worth a connection.
    public static func rebalance(_ segments: [Segment]) -> Split? {
        guard let donor = segments.indices.max(by: { segments[$0].remaining < segments[$1].remaining }),
              segments[donor].remaining > rebalanceThreshold else { return nil }
        let segment = segments[donor]
        let half = segment.remaining / 2
        let newStart = segment.position + half
        return Split(donor: donor, donorEnd: newStart - 1, newSegment: Segment(start: newStart, end: segment.end))
    }
}
