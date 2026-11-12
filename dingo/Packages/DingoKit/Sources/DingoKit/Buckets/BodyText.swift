import Foundation

/// Plain text from HTML mail, for search and for the receipt parser's fallback. It keeps words and
/// line breaks between blocks; it does not try to render.
enum BodyText {
    static func plain(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<(script|style|head|title)\b.*?</\1\s*>"#, #"(?s)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<\s*(br|/p|/div|/tr|/li|/h[1-6]|/table)\b[^>]*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<\s*/t[dh]\s*>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"[ \t\x{00A0}\x{200B}\x{200C}\x{034F}]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" *\n[ \n]*"#, with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                       "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "copy": "©", "reg": "®",
                                       "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
                                       "rdquo": "”", "ldquo": "“", "zwnj": "", "zwj": ""]
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = after[..<semi]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[name.lowercased()]
                }
                if let replacement {
                    result += replacement
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }
}
