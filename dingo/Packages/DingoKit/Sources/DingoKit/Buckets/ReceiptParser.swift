import Foundation

/// Where a purchase stands, from the receipt's markup or wording.
public enum ReceiptStatus: String, Codable, Sendable, CaseIterable {
    case ordered, shipped, delivered, refunded, paid, unknown
}

/// Pulls merchant, total, order number, and status out of receipt mail. Merchants that mark up
/// their mail for Gmail (schema.org JSON-LD) are read exactly; everything else falls back to
/// patterns over the subject and body text, which find the labeled total rather than the first price.
public enum ReceiptParser {
    public static func parse(_ message: ParsedMessage) -> Receipt {
        parse(accountID: message.accountID, messageID: message.id, date: message.internalDate, subject: message.subject,
              from: message.from, html: message.body?.html, text: message.body?.text)
    }

    public static func parse(accountID: String, messageID: String, date: Date, subject: String, from: EmailAddress?,
                             html: String?, text: String?) -> Receipt {
        var receipt = Receipt(accountID: accountID, messageID: messageID, merchant: nil, amount: nil, currency: nil,
                              orderNumber: nil, status: .unknown, date: date)
        if let html, let object = jsonLDObjects(inHTML: html).first(where: { isReceiptType(types(of: $0)) }) {
            apply(object, to: &receipt)
        }

        let body = text ?? html.map(BodyText.plain(fromHTML:)) ?? ""
        let combined = subject + "\n" + body
        if receipt.amount == nil, let money = total(in: combined) {
            receipt.amount = money.amount
            receipt.currency = money.currency
        }
        if receipt.orderNumber == nil { receipt.orderNumber = orderNumber(in: combined) }
        if receipt.merchant == nil { receipt.merchant = merchant(from: from) }
        if receipt.status == .unknown {
            receipt.status = status(in: subject)
            if receipt.status == .unknown { receipt.status = status(in: String(body.prefix(2_000))) }
        }
        return receipt
    }

    // MARK: - JSON-LD

    /// schema.org types that mean "this is a purchase": orders, invoices, deliveries, and bookings.
    static func isReceiptType(_ types: Set<String>) -> Bool {
        types.contains { $0 == "Order" || $0 == "Invoice" || $0 == "ParcelDelivery" || $0.hasSuffix("Reservation") }
    }

    /// Every JSON object in the HTML's `application/ld+json` scripts, with `@graph` and arrays flattened.
    static func jsonLDObjects(inHTML html: String) -> [[String: Any]] {
        guard html.range(of: "ld+json", options: .caseInsensitive) != nil else { return [] }
        let pattern = #"(?is)<script[^>]*application/ld\+json[^>]*>(.*?)</script\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        var objects: [[String: Any]] = []
        func collect(_ value: Any) {
            if let array = value as? [Any] { array.forEach(collect) }
            else if let object = value as? [String: Any] {
                objects.append(object)
                if let graph = object["@graph"] { collect(graph) }
            }
        }
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let script = ns.substring(with: match.range(at: 1))
            for candidate in [script, BodyText.decodeEntities(script)] {
                if let data = candidate.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) {
                    collect(value)
                    break
                }
            }
        }
        return objects
    }

    /// `@type` without the schema.org prefix: "http://schema.org/Order" and "Order" are the same.
    static func types(of object: [String: Any]) -> Set<String> {
        let raw: [String] = (object["@type"] as? String).map { [$0] } ?? (object["@type"] as? [String]) ?? []
        return Set(raw.map(schemaName))
    }

    static func schemaName(_ value: String) -> String {
        value.split(separator: "/").last.map(String.init) ?? value
    }

    /// The schema.org types in a message: JSON-LD, plus microdata `itemtype`, which older Amazon mail uses.
    static func schemaTypes(inHTML html: String) -> Set<String> {
        var types = Set(jsonLDObjects(inHTML: html).flatMap(types(of:)))
        if html.range(of: "itemtype", options: .caseInsensitive) != nil,
           let regex = try? NSRegularExpression(pattern: #"(?i)itemtype\s*=\s*["']https?://schema\.org/(\w+)"#) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                types.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        return types
    }

    static func apply(_ object: [String: Any], to receipt: inout Receipt) {
        func name(_ value: Any?) -> String? {
            if let string = value as? String { return string.isEmpty ? nil : string }
            if let object = value as? [String: Any] { return object["name"] as? String }
            return nil
        }
        let order = object["partOfOrder"] as? [String: Any] ?? object["referencesOrder"] as? [String: Any]
        let reservationFor = object["reservationFor"] as? [String: Any]
        receipt.merchant = ["seller", "merchant", "provider", "broker"].lazy.compactMap { name(object[$0]) }.first
            ?? order.flatMap { o in ["seller", "merchant"].lazy.compactMap { name(o[$0]) }.first }
            ?? reservationFor.flatMap { name($0["provider"]) ?? name($0["airline"]) }

        let priceSources: [Any?] = [object["totalPaymentDue"], object["totalPrice"], object["price"], object["minimumPaymentDue"],
                                    order?["price"], order?["totalPaymentDue"]]
        for source in priceSources {
            guard let source else { continue }
            if let spec = source as? [String: Any] {
                if let amount = decimal(spec["price"] ?? spec["value"]) {
                    receipt.amount = amount
                    receipt.currency = (spec["priceCurrency"] ?? spec["currency"]) as? String ?? object["priceCurrency"] as? String
                    break
                }
            } else if let amount = decimal(source) {
                receipt.amount = amount
                receipt.currency = object["priceCurrency"] as? String ?? order?["priceCurrency"] as? String
                break
            }
        }
        receipt.currency = receipt.currency?.uppercased()

        receipt.orderNumber = ["orderNumber", "confirmationNumber", "reservationNumber"].lazy
            .compactMap { object[$0].map { "\($0)" } }.first
            ?? order?["orderNumber"].map { "\($0)" }

        let statusValues = ["orderStatus", "deliveryStatus", "paymentStatus", "reservationStatus"]
            .compactMap { (object[$0] as? String).map(schemaName) ?? name(object[$0]).map(schemaName) }
        for value in statusValues {
            let mapped: ReceiptStatus? = switch value {
            case "OrderDelivered": .delivered
            case "OrderInTransit", "OrderPickupAvailable": .shipped
            case "OrderReturned": .refunded
            case "OrderProcessing", "ReservationConfirmed", "ReservationPending": .ordered
            case "PaymentComplete": .paid
            default: nil
            }
            if let mapped {
                receipt.status = mapped
                break
            }
        }
    }

    static func decimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) }
        if let string = value as? String { return parseNumber(string.filter { $0.isNumber || $0 == "." || $0 == "," }) }
        return nil
    }

    // MARK: - Text fallback

    struct Money: Equatable {
        var amount: Decimal
        var currency: String
    }

    static let symbols: [(symbol: String, currency: String)] = [
        ("US$", "USD"), ("AU$", "AUD"), ("A$", "AUD"), ("CA$", "CAD"), ("C$", "CAD"), ("NZ$", "NZD"),
        ("HK$", "HKD"), ("S$", "SGD"), ("R$", "BRL"), ("$", "USD"), ("€", "EUR"), ("£", "GBP"), ("¥", "JPY"), ("₹", "INR"),
    ]
    static let codes = ["USD", "EUR", "GBP", "JPY", "AUD", "CAD", "CHF", "NZD", "SEK", "NOK", "DKK", "INR", "CNY", "HKD", "SGD", "MXN", "BRL"]

    static let moneyRegex: NSRegularExpression = {
        let symbol = symbols.map { NSRegularExpression.escapedPattern(for: $0.symbol) }.joined(separator: "|")
        let code = codes.joined(separator: "|")
        let number = #"\d{1,3}(?:[,.\x{00A0} ]\d{3})*(?:[.,]\d{1,2})?(?!\d)|\d+(?:[.,]\d{1,2})?(?!\d)"#
        let pattern = "(?<sym>\(symbol))\\s?(?<n1>\(number))"
            + "|\\b(?<pre>\(code))\\s?(?<n2>\(number))"
            + "|(?<n3>\(number))\\s?(?:(?<post>\(code))\\b|(?<sym2>€|£))"
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// The amount labeled as the total. Labels sit before the amount on its line ("Order total: $41.07"),
    /// or alone on the line above when a table puts them in their own row. Among equally labeled
    /// amounts the last wins, since totals follow subtotals; with no labels the largest wins.
    static func total(in text: String) -> Money? {
        let ns = text as NSString
        var best: (money: Money, score: Int)?
        for match in moneyRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func group(_ name: String) -> String? {
                let range = match.range(withName: name)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            guard let digits = group("n1") ?? group("n2") ?? group("n3"), let amount = parseNumber(digits) else { continue }
            let currency = group("pre") ?? group("post")
                ?? (group("sym") ?? group("sym2")).flatMap { s in symbols.first { $0.symbol == s }?.currency } ?? "USD"
            let money = Money(amount: amount, currency: currency)
            let score = labelScore(ns.substring(to: match.range.location))
            if let current = best {
                let better = score > current.score
                    || (score == current.score && (score > 0 ? true : amount > current.money.amount))
                if better { best = (money, score) }
            } else {
                best = (money, score)
            }
        }
        guard let best, best.score >= 0 else { return nil }
        return best.money
    }

    static func labelScore(_ before: String) -> Int {
        var lines = before.split(separator: "\n", omittingEmptySubsequences: false)
        var context = String(lines.popLast() ?? "")
        if context.trimmingCharacters(in: .whitespaces).isEmpty || context.trimmingCharacters(in: .whitespaces).count < 3 {
            context = String(lines.popLast() ?? "") + " " + context
        }
        let label = String(context.suffix(48)).lowercased()
        let scored: [(String, Int)] = [
            ("grand total", 5), ("order total", 4), ("total charged", 4), ("amount charged", 4), ("total paid", 4),
            ("amount paid", 4), ("you paid", 4), ("payment amount", 4), ("invoice total", 4), ("total amount", 4),
            ("amount due", 4), ("total due", 4), ("balance due", 4), ("charged to", 4),
            ("subtotal", -1), ("sub-total", -1), ("tax", -1), ("shipping", -1), ("discount", -1), ("save", -1),
            ("tip", -1), ("total", 3),
        ]
        // The label nearest the amount decides, so "Subtotal $10 Tax $1 Total" scores as a total.
        // Labels ending at the same place go to the longer one: "subtotal" over "total".
        var nearest: (position: String.Index, length: Int, score: Int)?
        for (word, score) in scored {
            guard let range = label.range(of: word, options: .backwards) else { continue }
            if let current = nearest,
               range.upperBound < current.position || (range.upperBound == current.position && word.count <= current.length) {
                continue
            }
            nearest = (range.upperBound, word.count, score)
        }
        return nearest?.score ?? 0
    }

    /// "1,234.56", "1.234,56", "12,50", and "1,200" (thousands, as in yen).
    static func parseNumber(_ raw: String) -> Decimal? {
        let digits = raw.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " ", with: "")
        guard !digits.isEmpty else { return nil }
        var normalized = digits
        if let last = digits.lastIndex(where: { $0 == "," || $0 == "." }) {
            let fraction = digits[digits.index(after: last)...]
            let whole = digits[..<last].filter(\.isNumber)
            normalized = fraction.count == 3 ? whole + fraction : whole + "." + fraction
        }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    static let orderRegex = try! NSRegularExpression(pattern:
        #"(?i)\b(?:order|invoice|receipt|confirmation|booking|reference)\s*(?:number|no\.?|num\.?|#|id|code)?\s*[:#]\s*#?\s*([A-Z0-9][A-Z0-9-]{2,})|\b(?:order|invoice|receipt|confirmation|booking)\s*(?:number|no\.?|num\.?|#|id)\s*([A-Z0-9][A-Z0-9-]{2,})"#)

    static func orderNumber(in text: String) -> String? {
        let ns = text as NSString
        for match in orderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for index in 1...2 where match.range(at: index).location != NSNotFound {
                let value = ns.substring(with: match.range(at: index))
                if value.contains(where: \.isNumber) { return value }
            }
        }
        return nil
    }

    /// The From name without the department words senders add ("Uber Receipts", "Amazon.com Orders");
    /// the address's domain when the name is only those words.
    static func merchant(from address: EmailAddress?) -> String? {
        guard let address else { return nil }
        if var name = address.name {
            name = name.replacingOccurrences(of: #"(?i)\s+via\s+.*$"#, with: "", options: .regularExpression)
            name = name.replacingOccurrences(
                of: #"(?i)\b(receipts?|orders?|no-?reply|do-?not-?reply|billing|payments?|invoices?|notifications?|team|support|accounts?)\b"#,
                with: "", options: .regularExpression)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -|:·•,").union(.whitespaces))
            if !name.isEmpty { return name }
        }
        let labels = address.domain.split(separator: ".")
        guard labels.count >= 2 else { return labels.first.map(String.init) }
        var index = labels.count - 2
        if ["co", "com", "org", "net"].contains(labels[index]), index > 0 { index -= 1 }
        return labels[index].prefix(1).uppercased() + labels[index].dropFirst()
    }

    static let statusPatterns: [(ReceiptStatus, String)] = [
        (.refunded, #"\brefund(ed|s)?\b"#),
        (.delivered, #"\bdelivered\b"#),
        (.shipped, #"\b(shipped|on (its|the) way|out for delivery|dispatched|in transit)\b"#),
        (.paid, #"\b(receipt|payment (received|confirmation|successful)|paid|thanks for your payment|charged)\b"#),
        (.ordered, #"\b(order (confirmation|confirmed|placed|received)|your (\S+ )?order|thanks for (your )?(order|purchase)|thank you for (your )?(order|purchase))\b"#),
    ]

    static func status(in text: String) -> ReceiptStatus {
        for (status, pattern) in statusPatterns where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return status
        }
        return .unknown
    }
}
