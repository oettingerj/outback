import Foundation

/// Reads the mailboxes in an RFC 5322 address header (From, To, Cc, Reply-To).
/// Real headers break the grammar often enough that the parser never fails: it keeps every
/// mailbox it can recognize and drops pieces that have no address, such as an empty group.
public enum AddressParser {
    public static func parse(_ header: String) -> [EmailAddress] {
        var parser = Parser(tokens: tokenize(header))
        return parser.addressList()
    }

    /// The name as it may appear in a header phrase: bare when it is only atoms, quoted when it holds
    /// characters that would otherwise split or end it. Non-ASCII text is left as is.
    static func quoteIfNeeded(_ name: String) -> String {
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        let needsQuotes = name.unicodeScalars.contains { specials.contains($0) }
            || name.hasPrefix(" ") || name.hasSuffix(" ") || name.contains("  ")
        guard needsQuotes else { return name }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: Tokens

    struct Token {
        enum Kind { case atom, quoted, literal, special, comment }
        var kind: Kind
        var text: String
        /// Whitespace or a comment came before this token, which separates words in a name.
        var spaced: Bool

        func isSpecial(_ character: Character) -> Bool { kind == .special && text == String(character) }

        /// The token as it is written in an address: quoted strings keep their quotes.
        var addressText: String {
            guard kind == .quoted else { return text }
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }

    private static let specials: Set<Character> = ["<", ">", ",", ":", ";", "@"]

    static func tokenize(_ header: String) -> [Token] {
        let characters = Array(header)
        var tokens: [Token] = []
        var spaced = false
        var index = 0

        /// Reads a quoted string or comment body, honoring backslash escapes. Comments nest.
        func delimited(open: Character, close: Character, nests: Bool) -> String {
            var text = ""
            var depth = 1
            index += 1
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\\", index < characters.count {
                    text.append(characters[index])
                    index += 1
                } else if character == close {
                    depth -= 1
                    if depth == 0 { break }
                    text.append(character)
                } else if nests, character == open {
                    depth += 1
                    text.append(character)
                } else {
                    text.append(character)
                }
            }
            return text
        }

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                spaced = true
                index += 1
                continue
            }
            switch character {
            case "\"":
                tokens.append(Token(kind: .quoted, text: delimited(open: "\"", close: "\"", nests: false), spaced: spaced))
            case "(":
                tokens.append(Token(kind: .comment, text: delimited(open: "(", close: ")", nests: true), spaced: spaced))
                spaced = true
                continue
            case "[":
                let start = index
                while index < characters.count, characters[index] != "]" { index += 1 }
                index = min(index + 1, characters.count)
                tokens.append(Token(kind: .literal, text: String(characters[start..<index]), spaced: spaced))
            case _ where specials.contains(character):
                tokens.append(Token(kind: .special, text: String(character), spaced: spaced))
                index += 1
            default:
                let start = index
                while index < characters.count {
                    let next = characters[index]
                    if next.isWhitespace || specials.contains(next) || next == "\"" || next == "(" || next == "[" { break }
                    index += 1
                }
                tokens.append(Token(kind: .atom, text: String(characters[start..<index]), spaced: spaced))
            }
            spaced = false
        }
        return tokens
    }

    // MARK: Grammar

    private struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func addressList() -> [EmailAddress] {
            var result: [EmailAddress] = []
            while index < tokens.count {
                if tokens[index].isSpecial(",") || tokens[index].isSpecial(";") || tokens[index].isSpecial(">") {
                    index += 1
                    continue
                }
                let start = index
                result += address(inGroup: false)
                if index == start { index += 1 }
            }
            return result
        }

        /// One mailbox, or every mailbox of a group ("Team: a@x, b@x;"). Leaves the separator unread.
        mutating func address(inGroup: Bool) -> [EmailAddress] {
            var phrase: [Token] = []
            while index < tokens.count {
                let token = tokens[index]
                if token.isSpecial("<") {
                    index += 1
                    let email = angleAddress()
                    let trailing = skipToSeparator()
                    guard !email.isEmpty else { return [] }
                    let name = Self.displayName(phrase) ?? Self.commentName(phrase + trailing)
                    return [EmailAddress(name: name, email: email)]
                }
                if token.isSpecial(":"), !inGroup {
                    index += 1
                    var members: [EmailAddress] = []
                    while index < tokens.count {
                        if tokens[index].isSpecial(";") { index += 1; break }
                        if tokens[index].isSpecial(",") { index += 1; continue }
                        let start = index
                        members += address(inGroup: true)
                        if index == start { index += 1 }
                    }
                    return members
                }
                if token.isSpecial(",") || token.isSpecial(";") { break }
                phrase.append(token)
                index += 1
            }
            return Self.mailbox(addrSpec: phrase)
        }

        /// The address inside angle brackets, without an obsolete source route ("<@relay:ada@x>").
        mutating func angleAddress() -> String {
            var parts: [Token] = []
            while index < tokens.count {
                let token = tokens[index]
                index += 1
                if token.isSpecial(">") { break }
                if token.isSpecial(":") { parts.removeAll(); continue }
                if token.kind == .comment || token.isSpecial(",") { continue }
                parts.append(token)
            }
            return parts.map(\.addressText).joined().trimmingCharacters(in: .whitespaces)
        }

        /// Skips anything between a closing bracket and the next separator, returning it for comments.
        mutating func skipToSeparator() -> [Token] {
            var skipped: [Token] = []
            while index < tokens.count, !tokens[index].isSpecial(","), !tokens[index].isSpecial(";") {
                skipped.append(tokens[index])
                index += 1
            }
            return skipped
        }

        /// A bare "ada@example.com", possibly with a comment name. When a sender left out the angle
        /// brackets ("Ada Lovelace ada@example.com"), the words before the address become the name.
        static func mailbox(addrSpec phrase: [Token]) -> [EmailAddress] {
            let words = phrase.filter { $0.kind != .comment }
            guard let at = words.lastIndex(where: { $0.isSpecial("@") }), at > 0, at + 1 < words.count else { return [] }
            var start = at - 1
            while start > 0, !words[start].spaced, !words[start - 1].isSpecial("@") { start -= 1 }
            var end = at + 1
            while end + 1 < words.count, !words[end + 1].spaced { end += 1 }
            let email = words[start...end].map(\.addressText).joined()
            let name = displayName(Array(words[..<start])) ?? commentName(phrase)
            return [EmailAddress(name: name, email: email)]
        }

        static func displayName(_ phrase: [Token]) -> String? {
            var name = ""
            for token in phrase where token.kind != .comment {
                if !name.isEmpty, token.spaced { name += " " }
                name += token.text
            }
            return clean(name)
        }

        static func commentName(_ tokens: [Token]) -> String? {
            tokens.first { $0.kind == .comment }.flatMap { clean($0.text) }
        }

        /// Decodes RFC 2047 words and drops the single quotes some clients wrap names in.
        static func clean(_ name: String) -> String? {
            var name = EncodedWord.decode(name).trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") {
                name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return name.isEmpty ? nil : name
        }
    }
}

extension EmailAddress {
    /// "Ada Lovelace <ada@example.com>" for display and storage, quoting the name only when needed.
    /// Non-ASCII stays readable; `MessageBuilder` encodes it for sending.
    public var formatted: String {
        guard let name else { return email }
        return "\(AddressParser.quoteIfNeeded(name)) <\(email)>"
    }

    /// The mailbox as it goes into an outgoing header: non-ASCII names as RFC 2047 words.
    var headerValue: String {
        guard let name else { return email }
        let phrase = EncodedWord.needsEncoding(name) ? EncodedWord.encode(name) : AddressParser.quoteIfNeeded(name)
        return "\(phrase) <\(email)>"
    }
}
