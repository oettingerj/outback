import Foundation

/// Decides which bucket a message belongs in. Pure and synchronous, so sync can classify a batch
/// without touching the database: rules and label names are loaded beforehand.
///
/// Precedence, first match wins:
/// 1. Mail the user sent and drafts stay in the inbox.
/// 2. The user's sender rules.
/// 3. A `Dingo/*` label already on the message, because a move made on another device wins.
/// 4. Definite signals, in bucket order: a calendar part, or an invite subject from a calendar
///    sender; schema.org receipt markup, or a known receipt sender; GitHub headers, developer
///    tools, security alerts; a newsletter platform.
/// 5. Personal mail (Gmail's CATEGORY_PERSONAL) from a person, with no list headers, stays in the inbox.
/// 6. Likely signals, in bucket order: receipt wording from automated or billing senders;
///    automated mail without an unsubscribe link; mail with one.
/// 7. Everything else is the inbox.
///
/// Label IDs are per account, so build one classifier per account's batch.
public struct Classifier: Sendable {
    public struct Classification: Sendable, Equatable {
        public var bucket: Bucket
        /// Which rule decided, for debugging and tests.
        public var reason: String
    }

    public let rules: SenderRuleLookup
    /// Label ID to name for the account being classified, to recognize `Dingo/*` labels.
    public let labelNames: [String: String]

    public init(rules: SenderRuleLookup, labelNames: [String: String] = [:]) {
        self.rules = rules
        self.labelNames = labelNames
    }

    public func classify(_ message: ParsedMessage) -> Bucket {
        classification(message).bucket
    }

    public func classification(_ message: ParsedMessage) -> Classification {
        let traits = Traits(message)
        if traits.labels.contains("SENT") || traits.labels.contains("DRAFT") {
            return Classification(bucket: .inbox, reason: "sent or draft")
        }
        if let from = message.from, let rule = rules.rule(for: from, accountID: message.accountID) {
            return Classification(bucket: rule.bucket, reason: "sender rule \(rule.matcher)")
        }
        if let bucket = message.labelIDs.lazy.compactMap({ labelNames[$0].flatMap(Bucket.init(labelName:)) }).first {
            return Classification(bucket: bucket, reason: "Dingo label")
        }
        if let rule = Self.definite.first(where: { $0.matches(traits) }) {
            return Classification(bucket: rule.bucket, reason: rule.reason)
        }
        if traits.labels.contains("CATEGORY_PERSONAL"), !traits.isAutomatedSender, !traits.hasListHeaders {
            return Classification(bucket: .inbox, reason: "personal mail from a person")
        }
        if let rule = Self.likely.first(where: { $0.matches(traits) }) {
            return Classification(bucket: rule.bucket, reason: rule.reason)
        }
        return Classification(bucket: .inbox, reason: "default")
    }

    // MARK: - Rules

    struct Rule: Sendable {
        var bucket: Bucket
        var reason: String
        var matches: @Sendable (Traits) -> Bool
    }

    static let definite: [Rule] = [
        Rule(bucket: .calendar, reason: "calendar part") { $0.calendarMethod != nil },
        // Google sends invites From the organizer, so the Sender header is what marks them before the body is fetched.
        Rule(bucket: .calendar, reason: "invite subject from calendar sender") { t in
            t.isCalendarSender && t.subjectMatches(Lexicon.inviteSubjects)
        },
        Rule(bucket: .receipts, reason: "schema.org receipt markup") { ReceiptParser.isReceiptType($0.schemaTypes) },
        Rule(bucket: .receipts, reason: "known receipt sender") { t in SenderPattern.receipts.contains { $0.matches(t) } },
        Rule(bucket: .notifications, reason: "GitHub headers") { $0.headers.contains("X-GitHub-Reason") },
        Rule(bucket: .notifications, reason: "developer tool list") { t in
            Lexicon.devToolDomains.contains { t.listID.contains($0) || t.domainMatches($0) }
        },
        Rule(bucket: .notifications, reason: "security alert") { t in
            (t.isAutomatedSender || !t.labels.contains("CATEGORY_PERSONAL")) && t.subjectMatches(Lexicon.securitySubjects)
        },
        Rule(bucket: .newsletters, reason: "newsletter platform") { t in
            Lexicon.newsletterPlatforms.contains { t.domainMatches($0) || t.listID.contains($0) || t.listUnsubscribe.contains($0) }
        },
    ]

    static let likely: [Rule] = [
        Rule(bucket: .receipts, reason: "receipt wording") { t in
            t.subjectMatches(Lexicon.receiptSubjects) && !t.subjectMatches(Lexicon.marketingSubjects)
                && (t.isAutomatedSender || t.isReceiptLocalPart || t.labels.contains("CATEGORY_UPDATES"))
        },
        Rule(bucket: .receipts, reason: "billing sender") { t in
            t.isReceiptLocalPart && !t.subjectMatches(Lexicon.marketingSubjects)
        },
        Rule(bucket: .notifications, reason: "Auto-Submitted") { t in
            t.autoSubmitted.map { $0 != "no" } ?? false
        },
        Rule(bucket: .notifications, reason: "automated sender without unsubscribe") { t in
            t.isAutomatedSender && !t.hasListUnsubscribe
        },
        Rule(bucket: .notifications, reason: "updates without unsubscribe") { t in
            t.labels.contains("CATEGORY_UPDATES") && !t.hasListUnsubscribe
        },
        Rule(bucket: .newsletters, reason: "List-Unsubscribe") { $0.hasListUnsubscribe },
        Rule(bucket: .newsletters, reason: "bulk list") { t in
            !t.listID.isEmpty && (t.precedence == "bulk" || t.precedence == "list")
        },
    ]

    // MARK: - Traits

    /// What the rules look at, computed once per message and lowercased.
    struct Traits {
        var headers: ParsedMessage.Headers
        var labels: Set<String>
        var email: String
        var localPart: String
        var domain: String
        var senderEmail: String
        var subject: String
        var listID: String
        var listUnsubscribe: String
        var hasListUnsubscribe: Bool
        var precedence: String
        var autoSubmitted: String?
        var calendarMethod: CalendarMethod?
        var schemaTypes: Set<String>

        init(_ message: ParsedMessage) {
            headers = message.headers
            labels = Set(message.labelIDs)
            let from = message.from
            email = from?.email.lowercased() ?? ""
            domain = from?.domain ?? ""
            let local = email.split(separator: "@").first.map(String.init) ?? ""
            localPart = local.split(separator: "+").first.map(String.init) ?? local
            senderEmail = message.headers.addresses("Sender").first?.email.lowercased() ?? ""
            subject = message.subject.lowercased()
            listID = message.headers["List-Id"]?.lowercased() ?? ""
            listUnsubscribe = message.headers["List-Unsubscribe"]?.lowercased() ?? ""
            hasListUnsubscribe = !listUnsubscribe.isEmpty
            precedence = message.headers["Precedence"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            autoSubmitted = message.headers["Auto-Submitted"]?.trimmingCharacters(in: .whitespaces).lowercased()
            if let calendar = message.body?.calendar, let invite = ICalendarParser.parse(calendar), !invite.events.isEmpty {
                calendarMethod = invite.method
            }
            schemaTypes = message.body?.html.map(ReceiptParser.schemaTypes(inHTML:)) ?? []
        }

        /// The domain or any subdomain of it.
        func domainMatches(_ candidate: String) -> Bool {
            domain == candidate || domain.hasSuffix("." + candidate)
        }

        func subjectMatches(_ patterns: [String]) -> Bool {
            patterns.contains { subject.range(of: $0, options: .regularExpression) != nil }
        }

        var isAutomatedSender: Bool {
            Lexicon.automatedFragments.contains { localPart.contains($0) } || Lexicon.automatedLocalParts.contains(localPart)
        }

        var isReceiptLocalPart: Bool { Lexicon.receiptLocalParts.contains(localPart) }

        var isCalendarSender: Bool {
            Lexicon.calendarSenders.contains(email) || Lexicon.calendarSenders.contains(senderEmail)
        }

        var hasListHeaders: Bool {
            !listID.isEmpty || hasListUnsubscribe || ["bulk", "list", "junk"].contains(precedence)
                || (autoSubmitted.map { $0 != "no" } ?? false)
        }
    }

    /// A sender known to send receipts: a local part (prefix) at a domain, optionally only for
    /// subjects that say so, because the same address also sends account notices.
    struct SenderPattern: Sendable {
        var localPrefixes: [String]
        var domains: [String]
        var subjects: [String] = []

        func matches(_ t: Traits) -> Bool {
            guard domains.contains(where: t.domainMatches), localPrefixes.isEmpty || localPrefixes.contains(where: t.email.hasPrefix) else {
                return false
            }
            return subjects.isEmpty || t.subjectMatches(subjects)
        }

        static let amazon = ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.fr", "amazon.es", "amazon.it",
                             "amazon.co.jp", "amazon.com.au", "amazon.in", "amazon.com.mx"]

        static let receipts: [SenderPattern] = [
            SenderPattern(localPrefixes: ["auto-confirm@", "shipment-tracking@", "order-update@", "digital-no-reply@",
                                          "return@", "returns@", "payments-messages@", "conf-noreply@"], domains: amazon),
            SenderPattern(localPrefixes: ["invoice+statements", "receipts+", "invoice+", "failed-payments+"], domains: ["stripe.com"]),
            SenderPattern(localPrefixes: ["no_reply@", "no-reply@", "noreply@"], domains: ["email.apple.com", "apple.com"],
                          subjects: [#"\b(receipt|invoice|your order)\b"#]),
            SenderPattern(localPrefixes: [], domains: ["uber.com"], subjects: [#"\b(receipt|trip|order)\b"#]),
            SenderPattern(localPrefixes: [], domains: ["lyftmail.com", "lyft.com"], subjects: [#"\b(receipt|ride)\b"#]),
            SenderPattern(localPrefixes: ["service@", "paypal@"], domains: ["paypal.com"],
                          subjects: [#"\b(receipt|you sent|payment (to|received)|you paid|refund)\b"#]),
            SenderPattern(localPrefixes: [], domains: ["venmo.com"], subjects: [#"\b(paid|payment|charged)\b"#]),
            SenderPattern(localPrefixes: [], domains: ["messaging.squareup.com"]),
            SenderPattern(localPrefixes: [], domains: ["doordash.com", "grubhub.com", "instacart.com"],
                          subjects: [#"\b(receipt|order (confirmation|confirmed)|your order)\b"#]),
        ]
    }

    /// The word lists the rules draw on. Subject entries are regular expressions over the lowercased subject.
    enum Lexicon {
        static let automatedFragments = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply"]
        static let automatedLocalParts: Set<String> = ["notifications", "notification", "notify", "alerts", "alert", "mailer-daemon",
                                                        "postmaster", "automated", "bot", "robot", "security", "account-security"]
        static let receiptLocalParts: Set<String> = ["receipts", "receipt", "billing", "invoice", "invoices", "orders",
                                                      "order-confirmation", "payments", "purchases"]
        static let calendarSenders: Set<String> = ["calendar-notification@google.com", "calendar-noreply@google.com"]

        static let devToolDomains = ["github.com", "gitlab.com", "linear.app", "atlassian.net", "jira.com", "sentry.io", "vercel.com",
                                     "bitbucket.org", "circleci.com", "netlify.com"]
        static let newsletterPlatforms = ["substack.com", "beehiiv.com", "buttondown.email", "buttondown.com", "ghost.io",
                                          "list-manage.com", "mcsv.net", "mcdlv.net", "mailchimpapp.net", "convertkit-mail.com",
                                          "convertkit-mail2.com", "ck.page", "getrevue.co", "medium.com"]

        static let inviteSubjects = [#"^(updated )?invitation:"#, #"^cancel+ed event:"#, #"^(accepted|declined|tentatively accepted):"#,
                                     #"^updated event:"#, #"^invitation from google calendar"#]
        static let receiptSubjects = [#"\breceipt\b"#, #"\binvoice\b"#, #"\byour( \S+)? order\b"#, #"\border (confirmation|confirmed|#|no\.?|number)"#,
                                      #"\b(has|have) shipped\b"#, #"\bshipped:"#, #"\b(was|has been) delivered\b"#, #"^delivered:"#,
                                      #"\bout for delivery\b"#, #"\bpayment (received|confirmation|successful)\b"#, #"\brefund"#,
                                      #"\byour payment\b"#, #"\b(thanks|thank you) for your (order|purchase)\b"#, #"\bpurchase confirmation\b"#]
        static let marketingSubjects = [#"\border now\b"#, #"\bpre-?order"#, #"\d+% off\b"#, #"\bsale\b"#, #"\bshop now\b"#, #"\bdeals?\b"#,
                                        #"\blimited time\b"#, #"\blast chance\b"#, #"\bcoupon\b"#, #"\bpromo\b"#, #"\bfree shipping on\b"#]
        static let securitySubjects = [#"\bsecurity (alert|notice|notification)\b"#, #"\bnew (sign-?in|login)\b"#, #"\bsign-?in attempt\b"#,
                                       #"\bpassword (reset|change)"#, #"\breset your password\b"#, #"\bverification code\b"#,
                                       #"\b(verify|confirm) your (email|account)\b"#, #"\bone-time (code|passcode)\b"#, #"\blog-?in code\b"#,
                                       #"\b(2-step|two-factor|2fa)\b"#]
    }
}
