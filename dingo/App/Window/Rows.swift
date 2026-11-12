import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

// One row anatomy for every middle column and log: 12pt gutters inside a 6pt inset, an 8pt unread
// column, 13pt title, 12pt secondary line, and figures in 0xProto on the trailing edge.
// Single-line rows are 36pt; two-line rows 54pt; three-line message rows 72pt.

let pagePrimary = Color(nsColor: Theme.textPrimary)
let pageSecondary = Color(nsColor: Theme.textSecondary)
let pageTertiary = Color(nsColor: Theme.textTertiary)
let pageAccent = Color(nsColor: Theme.accent)
let pageAccentText = Color(nsColor: Theme.accentText)

/// The 7pt ochre dot that marks unread mail; an empty column keeps titles aligned when read.
struct UnreadDot: View {
    let isUnread: Bool
    var body: some View {
        Circle().fill(isUnread ? pageAccent : .clear).frame(width: 7, height: 7)
            .frame(width: 8)
            .accessibilityHidden(true)
    }
}

/// A list row: unread dot, title and optional subtitle, trailing figure. Selection is hover fill
/// and primary text; the focused list adds the accent ring.
struct ListRow<Trailing: View>: View {
    var isUnread = false
    let title: String
    var subtitle: String?
    var detail: String?
    var isSelected = false
    var isFocused = false
    var titleWeight: Font.Weight?
    var showsDot = true
    /// Canceled things keep their row with the title struck through.
    var isStruck = false
    /// Repository names and figures set in 0xProto.
    var titleIsMono = false
    /// Two lines where the title is the content (issue titles under a publication).
    var titleLines = 1
    var subtitleIsMono = false
    @ViewBuilder var trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .firstTextBaseline, spacing: 8) {
            if showsDot { UnreadDot(isUnread: isUnread).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 } }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(MonoRuns.styled(title, size: 13, mono: titleIsMono))
                        .font(titleIsMono ? .mono(size: 12, weight: isUnread ? .semibold : .regular)
                              : .system(size: 13, weight: titleWeight ?? (isUnread ? .semibold : .regular)))
                        .foregroundStyle(isStruck ? pageTertiary : pagePrimary)
                        .strikethrough(isStruck, color: pageTertiary)
                        .lineLimit(titleLines)
                        .fixedSize(horizontal: false, vertical: titleLines > 1)
                    Spacer(minLength: 8)
                    trailing
                }
                if let subtitle {
                    Text(subtitle).font(subtitleIsMono ? .mono(size: 11) : .system(size: 12))
                        .foregroundStyle(isUnread ? pagePrimary : pageSecondary).lineLimit(1)
                }
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(pageTertiary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: titleLines > 1 ? 54 : nil)
        .frame(height: titleLines > 1 ? nil : detail != nil ? 72 : subtitle == nil ? 36 : 54)
        .padding(.vertical, titleLines > 1 ? 8 : 0)
        .background {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Color(nsColor: isSelected ? RowFill.selected : isHovered ? RowFill.hover : .clear))
        }
        .overlay {
            if isSelected && isFocused {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(pageAccent, lineWidth: 1.5)
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Theme.reduceMotion ? nil : .easeOut(duration: Theme.hoverDuration)) { isHovered = hovering } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

extension ListRow where Trailing == FigureText {
    init(isUnread: Bool = false, title: String, subtitle: String? = nil, detail: String? = nil, figure: String?,
         isSelected: Bool = false, isFocused: Bool = false, titleWeight: Font.Weight? = nil, showsDot: Bool = true) {
        self.init(isUnread: isUnread, title: title, subtitle: subtitle, detail: detail, isSelected: isSelected,
                  isFocused: isFocused, titleWeight: titleWeight, showsDot: showsDot, isStruck: false) { FigureText(text: figure ?? "") }
    }
}

/// Sets commit hashes, PR and issue numbers, and `owner/repo` names inside prose in 0xProto,
/// so engineering identifiers read the same in every list.
enum MonoRuns {
    private static let pattern = try! NSRegularExpression(pattern: #"\b[0-9a-f]{7,40}\b|#\d+|\b[\w.-]+/[\w.-]+\b"#)

    static func styled(_ text: String, size: CGFloat, mono: Bool) -> AttributedString {
        var result = AttributedString(text)
        guard !mono else { return result }
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let marked = Range(range, in: result) else { continue }
            let token = text[range]
            // Hex runs only count when they carry a digit, so "decade" stays prose.
            if !token.contains("/"), !token.hasPrefix("#"), !token.contains(where: \.isNumber) { continue }
            if token.contains("/"), token.contains(where: { $0 == "." && token.hasPrefix("http") }) { continue }
            result[marked].font = .mono(size: size - 1)
        }
        return result
    }
}

/// A state in words: the state color on the dot, the word itself in secondary text, so it
/// stays readable on every row fill. Pass, pending, and fail never carry text on their own.
struct StateWord: View {
    let text: String
    let color: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(pageSecondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Times, counts, and amounts: 0xProto 11pt, tabular, tertiary.
struct FigureText: View {
    let text: String
    var color = pageTertiary
    var body: some View {
        Text(text).font(.mono(size: 11)).monospacedDigit().foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

/// A group heading inside a list: 11pt semibold secondary, more room above than below.
struct ListSectionHeader: View {
    let title: String
    var figure: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(pageSecondary).lineLimit(1)
            Spacer()
            if let figure { FigureText(text: figure) }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What an empty list says: what will appear here and why, in one or two lines.
struct EmptyListNote: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(pageSecondary)
            Text(detail).font(.system(size: 12)).foregroundStyle(pageTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 260).padding(.top, 56).frame(maxWidth: .infinity)
    }
}

enum MailDate {
    /// Today: 14:05. This week: Tue. This year: 12 Mar. Else: 12 Mar 2024.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "Tuesday 12 March, 14:05" for message headers.
    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
    }
}

enum Money {
    static func format(_ amount: Decimal?, currency: String?) -> String {
        guard let amount else { return "—" }
        return amount.formatted(.currency(code: currency ?? "USD").presentation(.narrow))
    }
}
