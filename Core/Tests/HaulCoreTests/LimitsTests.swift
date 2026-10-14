import Testing
@testable import HaulCore

struct LimitsTests {
    @Test func clampsToTheEngineCeilings() {
        #expect(Limits.clampConnections(0) == 1)
        #expect(Limits.clampConnections(16) == 16)
        #expect(Limits.clampConnections(64) == 32)
        #expect(Limits.clampConcurrent(0) == 1)
        #expect(Limits.clampConcurrent(50) == 8)
    }
}
