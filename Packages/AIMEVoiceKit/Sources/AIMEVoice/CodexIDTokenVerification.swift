import Foundation
import Security

// ID-token signature and claim checks against the issuer's published JWKS.
extension CodexSubscriptionClient {
    /// Load the signing keys when none are cached or the cache is over an hour old. A refresh calls this
    /// before it spends the one-time refresh token, so a key-set outage cannot lose the rotated token.
    func refreshSigningKeysIfStale() async throws {
        if let fetched = jwksFetchedAt, fetched.timeIntervalSinceNow >= -3600, !jwks.isEmpty { return }
        try await fetchSigningKeys()
    }

    private func fetchSigningKeys() async throws {
        let response = try await json(URLRequest(url: Self.jwksURL))
        guard let keys = response["keys"] as? [[String: Any]] else { throw Failure.invalidIdentity }
        jwks = keys.map { key in
            Dictionary(uniqueKeysWithValues: key.compactMap { pair -> (String, String)? in
                guard let value = pair.value as? String else { return nil }
                return (pair.key, value)
            })
        }
        jwksFetchedAt = Date()
    }

    func verifiedSubject(_ token: String, audience: String, nonce: String?) async throws -> String {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = Self.decodeBase64URL(String(segments[0])),
              let payloadData = Self.decodeBase64URL(String(segments[1])),
              let signature = Self.decodeBase64URL(String(segments[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String else { throw Failure.invalidIdentity }
        if jwksFetchedAt == nil || jwksFetchedAt!.timeIntervalSinceNow < -3600 || !jwks.contains(where: { $0["kid"] == kid }) {
            try await fetchSigningKeys()
        }
        guard let key = jwks.first(where: { $0["kid"] == kid && $0["kty"] == "RSA" && ($0["alg"] == nil || $0["alg"] == "RS256") }),
              key["use"] == nil || key["use"] == "sig",
              let modulus = key["n"].flatMap(Self.decodeBase64URL), let exponent = key["e"].flatMap(Self.decodeBase64URL) else {
            throw Failure.invalidIdentity
        }
        let encoded = Self.der(0x30, Self.derInteger(modulus) + Self.derInteger(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(encoded as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(segments[0]).\(segments[1])".utf8) as CFData, signature as CFData, nil) else {
            throw Failure.invalidIdentity
        }
        // Parse identity only after signature validation. Never expose email or tokens.
        guard let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              claims["iss"] as? String == Self.issuer,
              let expiry = claims["exp"] as? Double, expiry.isFinite, expiry > Date().timeIntervalSince1970 - 30,
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw Failure.invalidIdentity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(audience) else { throw Failure.invalidIdentity }
        if let authorized = claims["azp"] as? String, authorized != audience { throw Failure.invalidIdentity }
        if audiences.count > 1, claims["azp"] as? String != audience { throw Failure.invalidIdentity }
        if let nonce, claims["nonce"] as? String != nonce { throw Failure.invalidIdentity }
        if let notBefore = claims["nbf"] as? Double, notBefore > Date().timeIntervalSince1970 + 30 { throw Failure.invalidIdentity }
        return subject
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ text: String) -> Data? {
        var encoded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }
    static func derInteger(_ bytes: Data) -> Data {
        var value = bytes
        while value.count > 1, value.first == 0 { value.removeFirst() }
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return der(0x02, value)
    }
    static func der(_ tag: UInt8, _ value: Data) -> Data {
        var result = Data([tag])
        if value.count < 128 { result.append(UInt8(value.count)) }
        else {
            var size = value.count
            var bytes: [UInt8] = []
            while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }
            result.append(0x80 | UInt8(bytes.count)); result.append(contentsOf: bytes)
        }
        result.append(value)
        return result
    }
}
