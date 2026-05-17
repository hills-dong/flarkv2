import Foundation
import CryptoKit

// Usage: swift ascjwt.swift <p8-path> <keyID> <issuerID>
// Prints a short-lived App Store Connect API JWT (ES256) to stdout.
let args = CommandLine.arguments
guard args.count == 4 else { FileHandle.standardError.write(Data("need p8 keyID issuer\n".utf8)); exit(2) }
let pem = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
let keyID = args[2], issuer = args[3]

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
    FileHandle.standardError.write(Data("bad .p8 key\n".utf8)); exit(3)
}
let now = Int(Date().timeIntervalSince1970)
let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
let payload = #"{"iss":"\#(issuer)","iat":\#(now),"exp":\#(now + 900),"aud":"appstoreconnect-v1"}"#
let signingInput = b64url(Data(header.utf8)) + "." + b64url(Data(payload.utf8))
let sig = try! key.signature(for: Data(signingInput.utf8))
print(signingInput + "." + b64url(sig.rawRepresentation))
