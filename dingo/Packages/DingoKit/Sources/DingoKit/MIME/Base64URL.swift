import Foundation

extension Data {
    /// Decodes base64url (RFC 4648 §5), the alphabet Gmail uses for bodies, with or without padding.
    public init?(base64URLEncoded string: String) {
        var base64 = string.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if base64.count % 4 != 0 { base64 += String(repeating: "=", count: 4 - base64.count % 4) }
        self.init(base64Encoded: base64)
    }

    /// Base64url without padding, as Gmail's `raw` fields and PKCE challenges expect.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
