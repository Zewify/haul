// Creates the licence signing key pair and issues Haul Pro licences.
//   licensetool keygen <key-file>                      writes the private key (base64url raw) and prints the public key
//   licensetool issue --key <key-file> --id <order> --licensee <name>
import CryptoKit
import Foundation
import HaulCore

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

switch args.first {
case "keygen":
    guard args.count == 2 else { fail("usage: licensetool keygen <key-file>") }
    let key = Curve25519.Signing.PrivateKey()
    let url = URL(fileURLWithPath: args[1])
    try Data(Base64URL.encode(key.rawRepresentation).utf8).write(to: url, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    print("public key (paste into LicenseKeys.productionBase64URL): \(Base64URL.encode(key.publicKey.rawRepresentation))")
case "issue":
    guard let keyPath = option("--key"), let id = option("--id"), let licensee = option("--licensee") else {
        fail("usage: licensetool issue --key <key-file> --id <order> --licensee <name>")
    }
    let raw = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Base64URL.decode(raw) else { fail("bad key file") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    print(try License(id: id, licensee: licensee).key(signedWith: key))
default:
    fail("usage: licensetool keygen <key-file> | issue --key <key-file> --id <order> --licensee <name>")
}
