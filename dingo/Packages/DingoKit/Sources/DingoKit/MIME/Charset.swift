import Foundation

/// Turns the bytes of a MIME part or encoded word into text using the charset the message declares.
/// Mail mislabels its charset often, so decoding falls back instead of failing: every body reads as
/// something, and the worst case is a few wrong accented characters rather than an empty message.
public enum Charset {
    /// The Foundation encoding for an IANA charset name, or nil when Foundation doesn't know it.
    public static func encoding(named name: String) -> String.Encoding? {
        var name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased()
        if let alias = aliases[name] { name = alias }
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    /// Labels read as their supersets, as browsers do: senders write windows-1252 text and call it
    /// ISO-8859-1, and UTF-8 text and call it US-ASCII. The superset decodes the honest case the same.
    private static let aliases = [
        "iso-8859-1": "windows-1252", "iso8859-1": "windows-1252", "latin1": "windows-1252", "l1": "windows-1252",
        "us-ascii": "utf-8", "ascii": "utf-8", "ansi_x3.4-1968": "utf-8", "utf8": "utf-8",
        "gb2312": "gb18030", "gbk": "gb18030", "x-gbk": "gb18030",
        "cp1252": "windows-1252", "cp1251": "windows-1251", "cp1250": "windows-1250",
    ]

    /// Decodes `data` in `charset`, then UTF-8, then windows-1252, then ISO-8859-1, which accepts any bytes.
    public static func decode(_ data: Data, charset: String?) -> String {
        let text = charset.flatMap(encoding(named:)).flatMap { String(data: data, encoding: $0) }
            ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data.map { Character(Unicode.Scalar($0)) })
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}
