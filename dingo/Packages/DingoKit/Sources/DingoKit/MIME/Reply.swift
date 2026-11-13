import Foundation

/// The parts of a reply or forward that come from the original message: the subject prefix,
/// the threading headers, and who it goes to.
public enum Reply {
    public struct Recipients: Sendable, Equatable {
        public var to: [EmailAddress]
        public var cc: [EmailAddress]
    }

    /// "Re: " added once: a subject that already starts with Re: (or RE:, Re[2]:) is kept as is.
    public static func subject(_ subject: String) -> String {
        hasPrefix(subject, #/^\s*re(?:\[\d+\])?\s*:/#.ignoresCase()) ? subject : "Re: \(subject)"
    }

    /// "Fwd: " added once: Fwd: and Fw: subjects are kept as is.
    public static func forwardSubject(_ subject: String) -> String {
        hasPrefix(subject, #/^\s*fwd?\s*:/#.ignoresCase()) ? subject : "Fwd: \(subject)"
    }

    /// The original's Message-ID, for In-Reply-To.
    public static func inReplyTo(_ message: ParsedMessage) -> String? {
        message.headers["Message-ID"].flatMap { messageIDs($0).first }
    }

    /// The original's References with its Message-ID appended. Long chains keep the first ID, which
    /// names the thread root, and the most recent ones, as RFC 5322 suggests.
    public static func references(_ message: ParsedMessage) -> [String] {
        var chain = messageIDs(message.headers["References"] ?? "")
        if chain.isEmpty, let parent = message.headers["In-Reply-To"].flatMap({ messageIDs($0).first }) { chain = [parent] }
        if let id = inReplyTo(message), !chain.contains(id) { chain.append(id) }
        if chain.count > 20 { chain = [chain[0]] + chain.suffix(19) }
        return chain
    }

    /// Who a reply goes to. A reply goes to Reply-To, else From; replying to your own message goes to
    /// its original recipients instead. Reply-all adds the original To to `to` and keeps the original
    /// Cc as `cc`. Your own addresses (compared case-insensitively) and duplicates are left out.
    public static func recipients(_ message: ParsedMessage, all: Bool, ownAddresses: Set<String>) -> Recipients {
        let own = Set(ownAddresses.map { $0.lowercased() })
        let fromSelf = message.from.map { own.contains($0.email.lowercased()) } ?? false
        let replyTo = message.headers.addresses("Reply-To")
        var to: [EmailAddress]
        var cc: [EmailAddress] = []
        if fromSelf {
            to = message.to
            if all { cc = message.cc }
        } else {
            to = replyTo.isEmpty ? message.from.map { [$0] } ?? [] : replyTo
            if all {
                to += message.to
                cc = message.cc
            }
        }
        var seen = own
        func unique(_ addresses: [EmailAddress]) -> [EmailAddress] {
            addresses.filter { seen.insert($0.email.lowercased()).inserted }
        }
        to = unique(to)
        cc = unique(cc)
        if to.isEmpty {
            to = cc
            cc = []
        }
        return Recipients(to: to, cc: cc)
    }

    static func messageIDs(_ header: String) -> [String] {
        header.matches(of: #/<[^<>\s]+>/#).map { String($0.output) }
    }

    private static func hasPrefix(_ subject: String, _ pattern: Regex<Substring>) -> Bool {
        subject.prefixMatch(of: pattern) != nil
    }
}

extension MessageBuilder {
    /// A reply to `message` with its subject, threading headers, and recipients filled in.
    /// Send it with the message's `threadID` so Gmail files it in the same conversation.
    public static func reply(to message: ParsedMessage, from: EmailAddress, all: Bool = false,
                             ownAddresses: Set<String> = []) -> MessageBuilder {
        let recipients = Reply.recipients(message, all: all, ownAddresses: ownAddresses.union([from.email]))
        var builder = MessageBuilder(from: from, to: recipients.to, cc: recipients.cc, subject: Reply.subject(message.subject))
        builder.inReplyTo = Reply.inReplyTo(message)
        builder.references = Reply.references(message)
        return builder
    }
}
