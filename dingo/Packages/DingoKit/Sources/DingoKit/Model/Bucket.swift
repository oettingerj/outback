import Foundation

/// Where a message lives in Dingo. Everything a person wrote stays in the inbox; the rest is sorted
/// into a bucket with a view made for that kind of mail. Each bucket mirrors to a Gmail label.
public enum Bucket: String, Codable, CaseIterable, Sendable, Identifiable {
    case inbox, newsletters, notifications, receipts, calendar

    public var id: String { rawValue }

    /// The buckets mail is sorted into, in sidebar order. The inbox is not one of them.
    public static let sorted: [Bucket] = [.newsletters, .notifications, .receipts, .calendar]

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .newsletters: "Newsletters"
        case .notifications: "Notifications"
        case .receipts: "Receipts"
        case .calendar: "Invites"
        }
    }

    /// The Gmail label a sorted bucket mirrors to; nil for the inbox, which is Gmail's INBOX.
    public var labelName: String? {
        switch self {
        case .inbox: nil
        case .newsletters: "Dingo/Newsletters"
        case .notifications: "Dingo/Notifications"
        case .receipts: "Dingo/Receipts"
        case .calendar: "Dingo/Invites"
        }
    }

    public init?(labelName: String) {
        guard let bucket = Bucket.sorted.first(where: { $0.labelName == labelName }) else { return nil }
        self = bucket
    }

    /// SF Symbol for the sidebar.
    public var symbol: String {
        switch self {
        case .inbox: "tray"
        case .newsletters: "newspaper"
        case .notifications: "bell"
        case .receipts: "receipt"
        case .calendar: "calendar"
        }
    }
}
