import Foundation

/// Turns a Gmail API message into a `ParsedMessage`: headers RFC 2047 decoded, the MIME tree walked
/// for the bodies worth showing, inline images, a calendar invite, and attachments.
public enum GmailMessageDecoder {
    /// A message fetched with `format=metadata` has a payload with headers but neither a body nor
    /// parts (a full payload always has a body, even if only `{"size": 0}` on a multipart node), and
    /// decodes with `body == nil` so callers know to fetch the full message before showing it.
    public static func decode(_ message: GmailAPI.Message, accountID: String) -> ParsedMessage {
        let payload = message.payload
        let headers = ParsedMessage.Headers((payload?.headers ?? []).map { header in
            (name: header.name, value: decodeHeader(name: header.name, value: header.value))
        })
        var body: ParsedMessage.Body?
        var attachments: [ParsedMessage.Attachment] = []
        if let payload, payload.body != nil || payload.parts != nil {
            var walker = Walker()
            walker.walk(payload, depth: 0)
            body = ParsedMessage.Body(html: walker.html?.text, text: walker.text?.text, calendar: walker.calendar, inline: walker.inline)
            attachments = walker.attachments
        }
        return ParsedMessage(accountID: accountID, id: message.id, threadID: message.threadID,
                             historyID: message.historyID ?? 0, labelIDs: message.labelIDs,
                             internalDate: message.internalDate ?? Date(timeIntervalSince1970: 0),
                             snippet: unescapeEntities(message.snippet), headers: headers, body: body, attachments: attachments)
    }

    /// Address headers whose decoded names could contain commas or angle brackets. Those are parsed
    /// before decoding and written back with quoting, so `Headers.addresses` reads them the same way.
    private static let addressHeaders: Set<String> = [
        "from", "to", "cc", "bcc", "reply-to", "sender", "resent-from", "resent-to", "resent-cc", "resent-sender",
    ]

    static func decodeHeader(name: String, value: String) -> String {
        if value.contains("=?"), addressHeaders.contains(name.lowercased()) {
            let addresses = AddressParser.parse(value)
            if !addresses.isEmpty { return addresses.map(\.formatted).joined(separator: ", ") }
        }
        return EncodedWord.decode(value)
    }

    private struct Walker {
        var html: (depth: Int, text: String)?
        var text: (depth: Int, text: String)?
        var calendar: String?
        var inline: [String: ParsedMessage.InlinePart] = [:]
        var attachments: [ParsedMessage.Attachment] = []

        mutating func walk(_ part: GmailAPI.MessagePart, depth: Int) {
            let contentType = MIMEHeaderValue(part.header("Content-Type") ?? part.mimeType)
            let mimeType = part.mimeType.isEmpty ? contentType.value : part.mimeType.lowercased()
            if mimeType.hasPrefix("multipart/") {
                for child in part.parts ?? [] { walk(child, depth: depth + 1) }
                return
            }
            let disposition = part.header("Content-Disposition").map(MIMEHeaderValue.init)
            let isAttachment = disposition?.value == "attachment"
            let filename = Self.filename(part, contentType: contentType, disposition: disposition)
            let contentID = part.header("Content-ID").map(Self.stripAngles).flatMap { $0.isEmpty ? nil : $0 }
            let data = part.body?.decodedData
            let size = part.body?.size ?? data?.count ?? 0

            if mimeType == "text/calendar" || mimeType == "application/ics" {
                if calendar == nil, let data { calendar = Charset.decode(data, charset: contentType["charset"]) }
                if filename != nil || isAttachment {
                    attachments.append(.init(filename: filename ?? "invite.ics", mimeType: mimeType, size: size,
                                             attachmentID: part.body?.attachmentID))
                }
                return
            }
            if let contentID, !isAttachment, !mimeType.hasPrefix("text/") {
                inline[contentID] = .init(mimeType: mimeType, data: data, attachmentID: part.body?.attachmentID)
                return
            }
            if filename != nil || isAttachment {
                attachments.append(.init(filename: filename ?? "attachment", mimeType: mimeType, size: size,
                                         attachmentID: part.body?.attachmentID))
                return
            }
            guard let data, mimeType == "text/html" || mimeType == "text/plain" else { return }
            let decoded = Charset.decode(data, charset: contentType["charset"])
            // The deepest part wins: mailing lists append footers as shallower siblings of the real
            // multipart/alternative, and the first of equally deep parts is the author's.
            if mimeType == "text/html" {
                if html.map({ depth > $0.depth }) ?? true { html = (depth, decoded) }
            } else if text.map({ depth > $0.depth }) ?? true {
                text = (depth, decoded)
            }
        }

        static func filename(_ part: GmailAPI.MessagePart, contentType: MIMEHeaderValue, disposition: MIMEHeaderValue?) -> String? {
            let candidates = [part.filename, disposition?["filename"], contentType["name"]]
            return candidates.lazy.compactMap { $0 }.map(EncodedWord.decode).first { !$0.isEmpty }
        }

        static func stripAngles(_ value: String) -> String {
            value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "<>")))
        }
    }

    /// Gmail escapes HTML in snippets ("Don&#39;t miss"); Dingo shows them as plain text.
    static func unescapeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index)..<semicolon]
            let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
            var scalar: String?
            if let value = named[String(entity)] {
                scalar = value
            } else if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if entity.hasPrefix("#") {
                scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            }
            if let scalar {
                output += scalar
                index = text.index(after: semicolon)
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return output
    }
}
