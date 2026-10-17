/// The sites a grab was checked on end to end, and what Haul cannot save, for the Help popover.
/// Each was checked by its saved file's tracks and a frame against the page (docs/launch-checklist.md).
/// zewify.com/haul prints the same list from the zewify repo's `src/haul/data.ts`, so the two change together.
enum TestedSites {
    struct Site: Identifiable {
        let name: String
        let what: String
        var id: String { name }
    }

    static let testedOn = "17 October 2026"

    static let works: [Site] = [
        Site(name: "Facebook", what: "Videos and reels"),
        Site(name: "Instagram", what: "Reels"),
        Site(name: "TikTok", what: "Videos"),
        Site(name: "X", what: "Videos in posts"),
        Site(name: "Reddit", what: "Videos in posts"),
        Site(name: "Bilibili", what: "Videos"),
        Site(name: "Twitch", what: "Clips"),
        Site(name: "Vimeo", what: "Videos that are not protected"),
        Site(name: "TED", what: "Talks"),
        Site(name: "Internet Archive", what: "Videos"),
    ]

    static let doesNotWork: [Site] = [
        Site(name: "YouTube", what: "Not supported"),
        Site(name: "Netflix, Disney+, Prime Video", what: "Protected (DRM); so are some Vimeo videos"),
        Site(name: "Live streams", what: "No end to save to; Twitch and Rumble live, for example"),
    ]
}
