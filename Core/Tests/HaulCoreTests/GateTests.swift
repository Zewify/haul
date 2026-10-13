import Testing
@testable import HaulCore

struct GateTests {
    @Test func freeClampsConnectionsAndConcurrency() {
        let gate = FeatureGate(edition: .store, isPro: false)
        #expect(gate.maxConnections == 4)
        #expect(gate.maxConcurrent == 2)
        #expect(gate.clampConnections(16) == 4)
        #expect(gate.clampConnections(0) == 1)
        #expect(gate.clampConcurrent(5) == 2)
    }

    @Test func proRaisesLimits() {
        let gate = FeatureGate(edition: .store, isPro: true)
        #expect(gate.maxConnections == 32)
        #expect(gate.maxConcurrent == 8)
        #expect(gate.clampConnections(16) == 16)
        #expect(gate.clampConnections(64) == 32)
    }

    @Test func mediaGrabberNeedsDirectEditionAndPro() {
        #expect(!FeatureGate(edition: .store, isPro: true).allows(.mediaGrabber))
        #expect(!FeatureGate(edition: .direct, isPro: false).allows(.mediaGrabber))
        #expect(FeatureGate(edition: .direct, isPro: true).allows(.mediaGrabber))
    }

    @Test func directEditionOffersMediaEvenBeforePro() {
        #expect(FeatureGate(edition: .direct, isPro: false).offersMedia)
        #expect(!FeatureGate(edition: .store, isPro: true).offersMedia)
    }
}
