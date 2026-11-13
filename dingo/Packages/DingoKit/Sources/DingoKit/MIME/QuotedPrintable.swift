import Foundation

/// Quoted-printable (RFC 2045): text bodies stay readable on the wire while any byte can pass.
public enum QuotedPrintable {
    /// Encodes text as UTF-8 with CRLF line breaks, breaking lines softly so none exceeds 76 characters.
    public static func encode(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let bytes = Array(line.utf8)
            var output = ""
            var length = 0
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let piece: String
                // Trailing whitespace would be stripped in transit, so the last space or tab is encoded.
                if (byte == 0x20 || byte == 0x09) && !isLast {
                    piece = String(UnicodeScalar(byte))
                } else if (33...126).contains(byte) && byte != UInt8(ascii: "=") {
                    piece = String(UnicodeScalar(byte))
                } else {
                    piece = hex(byte)
                }
                if length + piece.count > 75 {
                    output += "=\r\n"
                    length = 0
                }
                output += piece
                length += piece.count
            }
            return output
        }.joined(separator: "\r\n")
    }

    /// Decodes quoted-printable, joining soft line breaks. Malformed escapes pass through literally.
    public static func decode(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var output = Data(capacity: bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                index += 1
                continue
            }
            if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                index += 3
            } else if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
            } else if index + 2 < bytes.count,
                      let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(value)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return "=" + String(digits[Int(byte >> 4)]) + String(digits[Int(byte & 0x0F)])
    }
}
