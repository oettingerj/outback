import Foundation

/// One mailbox from a From, To, or Cc header: "Ada Lovelace <ada@example.com>".
public struct EmailAddress: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name?.isEmpty == true ? nil : name
        self.email = email
    }

    /// The domain after @, lowercased.
    public var domain: String { email.split(separator: "@").last.map { $0.lowercased() } ?? "" }

    /// The name when there is one, else the address.
    public var displayName: String { name ?? email }
}
