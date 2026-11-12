import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

/// The middle column: one list whose meaning changes with the bucket. Threads in the Inbox and
/// mailboxes, issues under their publications in Newsletters, sources in Notifications, months
/// in Receipts, days in Invites. Every list uses the same row.
struct MiddleColumn: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        Group {
            switch model.destination {
            case .bucket(.inbox), .mailbox: ThreadList(model: model)
            case .bucket(.newsletters): IssueList(model: model)
            case .bucket(.notifications): SourceList(model: model)
            case .bucket(.receipts): MonthList(model: model)
            case .bucket(.calendar): AgendaList(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: Theme.chromeSurface))
        .simultaneousGesture(TapGesture().onEnded { model.focus = .middle })
    }
}

/// A scrolling list that keeps `selection` in view as j/k move it.
struct SelectableList<Content: View, ID: Hashable>: View {
    let selection: ID?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) { content }
                    .padding(.vertical, 6)
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(Theme.reduceMotion ? nil : .easeOut(duration: Theme.panelDuration)) { proxy.scrollTo(id) }
            }
        }
    }
}

// MARK: Inbox and mailboxes

private struct ThreadList: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        if model.threads.isEmpty {
            EmptyListNote(title: emptyTitle, detail: emptyDetail)
        } else {
            SelectableList(selection: model.selectedThread) {
                ForEach(model.threads) { thread in
                    let key = ThreadKey(thread)
                    ListRow(isUnread: thread.hasUnread, title: senders(thread), subtitle: thread.latest.subject.isEmpty ? "(no subject)" : thread.latest.subject,
                            detail: thread.latest.snippet, isSelected: model.selectedThread == key, isFocused: model.focus == .middle) {
                        HStack(spacing: 6) {
                            if thread.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(pageTertiary) }
                            if thread.isStarred { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(nsColor: Theme.pending)) }
                            FigureText(text: MailDate.short(thread.latest.internalDate))
                        }
                    }
                    .id(key)
                    .onTapGesture { model.selectedThread = key }
                    .contextMenu { MessageContextMenu(messages: [thread.latest], wholeThread: true) }
                    .draggable(MessageDrag(accountID: thread.accountID, messageID: thread.latest.id, threadID: thread.threadID))
                }
            }
        }
    }

    /// "Ada, Grace (3)": first names of who wrote, the count when the thread has replies.
    private func senders(_ thread: ThreadSummary) -> String {
        let names = thread.participants.map { address in
            AppServices.shared.isMine(address.email) ? "Me" : (address.name?.split(separator: " ").first.map(String.init) ?? address.email)
        }
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let list = unique.suffix(3).joined(separator: ", ")
        return thread.messageCount > 1 ? "\(list) (\(thread.messageCount))" : list
    }

    private var emptyTitle: String {
        switch model.destination {
        case .mailbox(let mailbox): "No \(mailbox.title.lowercased()) mail"
        default: "Inbox zero"
        }
    }

    private var emptyDetail: String {
        switch model.destination {
        case .mailbox(.starred): "Star a conversation with ⇧⌘L to keep it here."
        case .mailbox(.sent): "Mail you send appears here."
        case .mailbox(.drafts): "Drafts save to Gmail as you write."
        default: "Mail from people lands here. Newsletters, notifications, receipts, and invites go to their own buckets."
        }
    }
}

// MARK: Newsletters

private struct IssueList: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        VStack(spacing: 0) {
            SegmentedChoice(selection: $model.newsletterGrouping, options: [(.latest, "Latest"), (.publication, "By Publication")])
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            if model.issues.isEmpty {
                EmptyListNote(title: "Nothing to read yet", detail: "Newsletters you subscribe to collect here, with their publication on every issue.")
            } else {
                SelectableList(selection: model.selectedIssue) {
                    switch model.newsletterGrouping {
                    case .latest:
                        ForEach(model.issues, id: \.id) { issue in row(issue, showsPublication: true) }
                    case .publication:
                        ForEach(model.publications, id: \.id) { publication in
                            ListSectionHeader(title: publication.name, figure: publication.unreadCount > 0 ? "\(publication.unreadCount) new" : nil)
                            ForEach(model.issues.filter { $0.fromEmail == publication.id }, id: \.id) { issue in row(issue, showsPublication: false) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ issue: MailMessage, showsPublication: Bool) -> some View {
        let key = MessageKey(issue)
        return ListRow(isUnread: issue.isUnread, title: showsPublication ? issue.from.displayName : issue.subject,
                       subtitle: showsPublication ? issue.subject : nil, figure: MailDate.short(issue.internalDate),
                       isSelected: model.selectedIssue == key, isFocused: model.focus == .middle,
                       titleWeight: showsPublication ? .medium : nil)
            .id(key)
            .onTapGesture { model.selectedIssue = key }
            .contextMenu { MessageContextMenu(messages: [issue], wholeThread: false) }
            .draggable(MessageDrag(accountID: issue.accountID, messageID: issue.id, threadID: issue.threadID))
    }
}

// MARK: Notifications

private struct SourceList: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        if model.sources.isEmpty {
            EmptyListNote(title: "All quiet", detail: "GitHub, CI, and service mail collects here, grouped by repository or sender.")
        } else {
            let total = model.sources.reduce(0) { $0 + $1.unreadCount }
            SelectableList(selection: model.selectedSource) {
                ListRow(isUnread: total > 0, title: "All Sources", figure: total > 0 ? "\(total)" : nil,
                        isSelected: model.selectedSource == nil, isFocused: model.focus == .middle, titleWeight: .medium)
                    .onTapGesture { model.selectedSource = nil; model.focus = .middle }
                ForEach(groups, id: \.title) { group in
                    ListSectionHeader(title: group.title)
                    ForEach(group.sources, id: \.id) { source in
                        ListRow(isUnread: source.unreadCount > 0, title: source.title,
                                figure: source.unreadCount > 0 ? "\(source.unreadCount)" : "\(source.count)",
                                isSelected: model.selectedSource == source.id, isFocused: model.focus == .middle)
                            .id(source.id as String?)
                            .onTapGesture { model.selectedSource = source.id; model.focus = .middle }
                    }
                }
            }
        }
    }

    private var groups: [(title: String, sources: [NotificationSource])] {
        let github = model.sources.filter { $0.kind == .github }
        let other = model.sources.filter { $0.kind != .github }
        return [("GitHub", github), ("Services", other)].filter { !$0.1.isEmpty }
    }
}

// MARK: Receipts

private struct MonthList: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        if model.months.isEmpty {
            EmptyListNote(title: "No receipts yet", detail: "Orders, invoices, and payment confirmations collect here by month.")
        } else {
            SelectableList(selection: model.selectedMonth) {
                ForEach(yearGroups, id: \.year) { group in
                    ListSectionHeader(title: group.year)
                    ForEach(group.months, id: \.month) { month in
                        ListRow(title: month.month.formatted(.dateTime.month(.wide)), subtitle: "\(month.count) receipt\(month.count == 1 ? "" : "s")",
                                isSelected: model.selectedMonth == month.month, isFocused: model.focus == .middle, showsDot: false) {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(month.totals.sorted { $0.key < $1.key }, id: \.key) { currency, total in
                                    FigureText(text: Money.format(total, currency: currency), color: pagePrimary)
                                }
                            }
                        }
                        .id(month.month as Date?)
                        .onTapGesture { model.selectedMonth = month.month; model.focus = .middle }
                    }
                }
            }
        }
    }

    private var yearGroups: [(year: String, months: [ReceiptMonth])] {
        var groups: [(year: String, months: [ReceiptMonth])] = []
        for month in model.months {
            let year = month.month.formatted(.dateTime.year())
            if groups.last?.year == year { groups[groups.count - 1].months.append(month) } else { groups.append((year, [month])) }
        }
        return groups
    }
}

// MARK: Invites

private struct AgendaList: View {
    @Bindable var model: MailWindowModel

    var body: some View {
        if model.events.isEmpty {
            EmptyListNote(title: "No invitations", detail: "Calendar invitations collect here, ready to accept or decline.")
        } else {
            SelectableList(selection: model.selectedEvent) {
                ForEach(days(InviteAgenda.upcoming(in: model.events)), id: \.title) { day in
                    ListSectionHeader(title: day.title)
                    ForEach(day.events, id: \.message.id) { row($0) }
                }
                let past = InviteAgenda.past(in: model.events)
                if !past.isEmpty {
                    ListSectionHeader(title: "Past")
                    ForEach(past.prefix(50), id: \.message.id) { row($0) }
                }
            }
        }
    }

    private func row(_ item: EventRow) -> some View {
        let key = MessageKey(item.message)
        let event = item.event
        return ListRow(isUnread: event.myResponse == nil && !event.isCanceled && event.method == .request,
                       title: event.summary ?? item.message.subject,
                       subtitle: EventFormat.when(event, compact: true),
                       isSelected: model.selectedEvent == key, isFocused: model.focus == .middle, isStruck: event.isCanceled) {
            ResponseMark(event: event)
        }
        .id(key)
        .onTapGesture { model.selectedEvent = key }
    }

    private func days(_ events: [EventRow]) -> [(title: String, events: [EventRow])] {
        var groups: [(title: String, events: [EventRow])] = []
        let calendar = Calendar.current
        for item in events {
            let start = item.event.start ?? Date()
            let title = calendar.isDateInToday(start) ? "Today" : calendar.isDateInTomorrow(start) ? "Tomorrow"
                : start.formatted(.dateTime.weekday(.wide).day().month(.wide))
            if groups.last?.title == title { groups[groups.count - 1].events.append(item) } else { groups.append((title, [item])) }
        }
        return groups
    }
}

/// The user's answer in state colors: pass for yes, pending for maybe, fail for no, nothing while open.
struct ResponseMark: View {
    let event: CalendarEvent
    var body: some View {
        switch (event.isCanceled, event.myResponse) {
        case (true, _): FigureText(text: "Canceled", color: Color(nsColor: Theme.fail))
        case (_, .accepted?): FigureText(text: "Going", color: Color(nsColor: Theme.pass))
        case (_, .tentative?): FigureText(text: "Maybe", color: Color(nsColor: Theme.pending))
        case (_, .declined?): FigureText(text: "Declined", color: pageTertiary)
        default: EmptyView()
        }
    }
}

enum EventFormat {
    /// "14:00–14:30" today-style, or "Tue 12 Mar, 14:00–14:30"; all-day says so.
    static func when(_ event: CalendarEvent, compact: Bool) -> String {
        guard let start = event.start else { return "No time given" }
        if event.isAllDay {
            return compact ? "All day" : "\(start.formatted(.dateTime.weekday(.wide).day().month(.wide))), all day"
        }
        let time = start.formatted(date: .omitted, time: .shortened)
        let endTime = event.end.map { "–" + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        if compact { return time + endTime }
        return "\(start.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(time)\(endTime)"
    }
}

/// Two or three choices in a field well; the chosen one sits on hover fill in primary text.
/// Neutral on purpose: the accent marks focus and the primary action, not a view mode.
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == value ? pagePrimary : pageSecondary)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: selection == value ? Theme.hoverFill : .clear)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Color(nsColor: Theme.fieldFill)))
    }
}
