import Foundation

/// A structured MIME header such as Content-Type or Content-Disposition, split into its value
/// ("text/plain", lowercased) and parameters (lowercased names, values unquoted and decoded).
/// RFC 2231 parameters (`filename*=UTF-8''Re%C3%A7u.pdf`, continuations `name*0*=`) are joined and
/// decoded, and win over a plain parameter of the same name. RFC 2047 words in plain values,
/// which the RFC forbids and mailers write anyway, are decoded too.
struct MIMEHeaderValue: Sendable, Equatable {
    var value: String
    var parameters: [String: String]

    init(_ header: String) {
        let segments = Self.split(EncodedWord.unfold(header))
        value = segments.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var plain: [String: String] = [:]
        var sections: [String: [(index: Int, extended: Bool, value: String)]] = [:]
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = Self.unquote(segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            guard !key.isEmpty else { continue }
            if let star = key.firstIndex(of: "*") {
                let name = String(key[..<star])
                let rest = key[key.index(after: star)...]
                let extended = key.hasSuffix("*")
                let index = Int(rest.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
                sections[name, default: []].append((index, extended, value))
            } else {
                plain[key] = EncodedWord.decode(value)
            }
        }
        for (name, parts) in sections {
            var bytes = Data()
            var charset: String?
            for part in parts.sorted(by: { $0.index < $1.index }) {
                guard part.extended else {
                    bytes.append(Data(part.value.utf8))
                    continue
                }
                var encoded = Substring(part.value)
                if part.index == 0 {
                    let pieces = part.value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if pieces.count == 3 {
                        charset = pieces[0].isEmpty ? nil : String(pieces[0])
                        encoded = pieces[2]
                    }
                }
                bytes.append(Self.percentDecode(encoded))
            }
            plain[name] = Charset.decode(bytes, charset: charset)
        }
        parameters = plain
    }

    subscript(_ name: String) -> String? { parameters[name.lowercased()] }

    /// One parameter for an outgoing header: quoted when ASCII, RFC 2231 UTF-8 otherwise.
    static func parameter(_ name: String, _ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ (0x20..<0x7F).contains($0.value) }) {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\(name)=\"\(escaped)\""
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)
        let encoded = value.utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
        return "\(name)*=UTF-8''\(encoded)"
    }

    /// Splits on semicolons outside quoted strings.
    private static func split(_ header: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in header {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == ";", !quoted {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)
        return segments
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func percentDecode(_ text: Substring) -> Data {
        let bytes = Array(text.utf8)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(value)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }
}
