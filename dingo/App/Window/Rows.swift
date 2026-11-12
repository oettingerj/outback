import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

// One row anatomy for every middle column and log: 12pt gutters inside a 6pt inset, an 8pt unread
// column, 13pt title, 12pt secondary line, and figures in 0xProto on the trailing edge.
// Single-line rows are 36pt; two-line rows 56pt.

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
    @ViewBuilder var trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .firstTextBaseline, spacing: 8) {
            if showsDot { UnreadDot(isUnread: isUnread).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 } }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: titleWeight ?? (isUnread ? .semibold : .regular)))
                        .foregroundStyle(isStruck ? pageTertiary : pagePrimary)
                        .strikethrough(isStruck, color: pageTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    trailing
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(isUnread ? pagePrimary : pageSecondary).lineLimit(1)
                }
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(pageTertiary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: detail != nil ? 72 : subtitle == nil ? 36 : 54)
        .background {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Color(nsColor: isSelected ? Theme.hoverFill : isHovered ? Theme.neutral(2) : .clear))
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
