import Foundation

/// The user's sender rules, loaded once so the classifier can consult them synchronously for every
/// message in a sync batch.
public struct SenderRuleLookup: Sendable {
    private var byMatcher: [String: [SenderRule]]

    public static let empty = SenderRuleLookup([])

    public init(_ rules: [SenderRule]) {
        byMatcher = Dictionary(grouping: rules, by: \.matcher)
    }

    /// The rule that applies to mail from `address` in `accountID`. A rule for the exact address beats
    /// one for its domain, and a domain beats its parent ("@mail.example.com" before "@example.com").
    /// At the same specificity a rule for this account beats one for every account.
    public func rule(for address: EmailAddress, accountID: String) -> SenderRule? {
        for matcher in Self.matchers(for: address) {
            guard let rules = byMatcher[matcher] else { continue }
            if let rule = rules.first(where: { $0.accountID == accountID }) ?? rules.first(where: { $0.accountID == nil }) {
                return rule
            }
        }
        return nil
    }

    /// Matchers from most to least specific: the address, its domain, then each parent domain down
    /// to two labels.
    static func matchers(for address: EmailAddress) -> [String] {
        let email = address.email.lowercased()
        var matchers = [email]
        var labels = address.domain.split(separator: ".")
        while labels.count >= 2 {
            matchers.append("@" + labels.joined(separator: "."))
            labels.removeFirst()
        }
        return matchers
    }
}
