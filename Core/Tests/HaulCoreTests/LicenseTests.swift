import CryptoKit
import Foundation
import Testing
@testable import HaulCore

struct LicenseTests {
    let key = Curve25519.Signing.PrivateKey()

    @Test func roundTrip() throws {
        let license = License(id: "order-1", licensee: "A Customer")
        let token = try license.key(signedWith: key)
        #expect(token.hasPrefix("HAUL1-"))
        let verified = try License.verify(token, publicKey: key.publicKey)
        #expect(verified.id == "order-1")
        #expect(verified.licensee == "A Customer")
        #expect(verified.product == "haul-pro")
    }

    @Test func whitespaceFromEmailIsIgnored() throws {
        let token = try License(id: "x", licensee: "y").key(signedWith: key)
        let wrapped = token.prefix(20) + "\n " + token.dropFirst(20)
        #expect(try License.verify(String(wrapped), publicKey: key.publicKey).id == "x")
    }

    @Test func forgedSignatureIsRejected() throws {
        let token = try License(id: "x", licensee: "y").key(signedWith: key)
        let other = Curve25519.Signing.PrivateKey()
        #expect(throws: License.VerificationError.badSignature) {
            try License.verify(token, publicKey: other.publicKey)
        }
    }

    @Test func wrongProductIsRejected() throws {
        let token = try License(id: "x", licensee: "y", product: "voxmorph-pro").key(signedWith: key)
        #expect(throws: License.VerificationError.wrongProduct) {
            try License.verify(token, publicKey: key.publicKey)
        }
    }

    @Test func garbageIsMalformed() {
        #expect(throws: License.VerificationError.malformed) {
            try License.verify("HAUL1-notbase64.@@", publicKey: key.publicKey)
        }
        #expect(throws: License.VerificationError.malformed) {
            try License.verify("VOX1-abc.def", publicKey: key.publicKey)
        }
    }
}

struct ProductionKeyTests {
    @Test func productionKeyLoadsAndRejectsStrangers() throws {
        let token = try License(id: "x", licensee: "y").key(signedWith: Curve25519.Signing.PrivateKey())
        #expect(throws: License.VerificationError.badSignature) { try License.verify(token) }
    }
}
