import Foundation

/// RFC 2047 encoded words: how non-ASCII text travels in headers ("=?UTF-8?B?Q2Fmw6k=?=").
public enum EncodedWord {
    /// Decodes every encoded word in a header value and unfolds it.
    /// Whitespace between two adjacent encoded words is dropped, as the RFC requires, and adjacent
    /// words in the same charset are joined as bytes first, because senders split multi-byte
    /// characters across words. A word that can't be decoded is kept as written.
    public static func decode(_ header: String) -> String {
        let value = unfold(header)
        guard value.contains("=?") else { return value }
        let pattern = #/=\?([^?\s]+)\?([BbQq])\?([^?]*)\?=/#
        var output = ""
        var pending: (charset: String, bytes: Data)?
        var lastWasWord = false
        var cursor = value.startIndex

        func flush() {
            if let run = pending { output += Charset.decode(run.bytes, charset: run.charset) }
            pending = nil
        }

        for match in value.matches(of: pattern) {
            let between = value[cursor..<match.range.lowerBound]
            if !(lastWasWord && between.allSatisfy(\.isWhitespace)) {
                flush()
                output += between
            }
            // RFC 2231 lets a language follow the charset: "UTF-8*en".
            let charset = match.output.1.split(separator: "*").first.map(String.init)?.lowercased() ?? ""
            if let bytes = decodeText(match.output.3, encoding: match.output.2) {
                if pending?.charset == charset {
                    pending?.bytes.append(bytes)
                } else {
                    flush()
                    pending = (charset, bytes)
                }
                lastWasWord = true
            } else {
                flush()
                output += match.output.0
                lastWasWord = false
            }
            cursor = match.range.upperBound
        }
        flush()
        output += value[cursor...]
        return output
    }

    /// Encodes text for a header as UTF-8 B words of at most 75 characters each, separated by spaces
    /// so the header writer can fold between them. ASCII text comes back unchanged.
    public static func encode(_ text: String) -> String {
        guard needsEncoding(text) else { return text }
        // 45 bytes is 60 base64 characters; with "=?UTF-8?B?" and "?=" a word is 72 characters.
        let limit = 45
        var words: [String] = []
        var chunk = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if !chunk.isEmpty, chunk.count + bytes.count > limit {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words.joined(separator: " ")
    }

    /// True when text holds anything a header can't carry as is: non-ASCII, control characters, or
    /// something a reader would mistake for an encoded word.
    public static func needsEncoding(_ text: String) -> Bool {
        text.contains("=?") || text.unicodeScalars.contains { !(0x20..<0x7F).contains($0.value) && $0 != "\t" }
    }

    /// Removes the line breaks of folded headers; the whitespace after each break stays.
    static func unfold(_ header: String) -> String {
        // Checked as bytes: "\r\n" is one Character, so String.contains("\n") misses it.
        guard header.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return header }
        return header.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func decodeText(_ text: Substring, encoding: Substring) -> Data? {
        if encoding.lowercased() == "b" {
            var base64 = String(text)
            if base64.count % 4 != 0 { base64 += String(repeating: "=", count: 4 - base64.count % 4) }
            return Data(base64Encoded: base64)
        }
        var bytes = Data()
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case UInt8(ascii: "_"): bytes.append(0x20)
            case UInt8(ascii: "="):
                guard let high = iterator.next(), let low = iterator.next(),
                      let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(value)
            default: bytes.append(byte)
            }
        }
        return bytes
    }
}
