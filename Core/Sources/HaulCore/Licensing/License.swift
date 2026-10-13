import CryptoKit
import Foundation

/// A Pro licence for the direct edition: who bought it and when, signed by Zewify's licence key.
///
/// A licence travels as `HAUL1-<payload>.<signature>`, both base64url, where the payload is the JSON of `License`
/// and the signature is Ed25519 over the payload's bytes. The app checks it offline against the public key it
/// ships with; nothing calls home.
public struct License: Codable, Hashable, Sendable {
    /// The order or licence id from the shop, so a support request can be traced.
    public var id: String
    /// Who it was issued to, as the shop reported them.
    public var licensee: String
    public var issued: Date
    public var product: String

    public static let product = "haul-pro"
    static let prefix = "HAUL1-"

    public init(id: String, licensee: String, issued: Date = Date(), product: String = License.product) {
        self.id = id
        self.licensee = licensee
        self.issued = issued
        self.product = product
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Signs the licence into a key a customer can paste.
    public func key(signedWith privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payload = try Self.encoder.encode(self)
        let signature = try privateKey.signature(for: payload)
        return Self.prefix + Base64URL.encode(payload) + "." + Base64URL.encode(signature)
    }

    public enum VerificationError: Error, Equatable {
        case malformed, badSignature, wrongProduct
    }

    /// Reads and checks a pasted key. Whitespace and line breaks from email clients are ignored.
    public static func verify(_ key: String, publicKey: Curve25519.Signing.PublicKey = LicenseKeys.production) throws(VerificationError) -> License {
        let compact = key.filter { !$0.isWhitespace }
        guard compact.hasPrefix(prefix) else { throw .malformed }
        let parts = compact.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Base64URL.decode(String(parts[0])), let signature = Base64URL.decode(String(parts[1])) else {
            throw .malformed
        }
        guard publicKey.isValidSignature(signature, for: payload) else { throw .badSignature }
        guard let license = try? decoder.decode(License.self, from: payload) else { throw .malformed }
        guard license.product == product else { throw .wrongProduct }
        return license
    }
}

public enum LicenseKeys {
    /// The public half of the licence signing key. The private half lives outside the repo, with the owner
    /// (see CLAUDE.md); `licensetool keygen` made both. Replaced with the production key at launch.
    public static let production = try! Curve25519.Signing.PublicKey(rawRepresentation: Base64URL.decode(productionBase64URL)!)
    static let productionBase64URL = "uymOCLmtRdoEs55EDNtuTflJ6z_mImtZKNXS1AWTAMo"
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
