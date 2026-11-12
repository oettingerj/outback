import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

/// ⌘K: a floating bar under the headers that jumps to a bucket, finds mail (the local index
/// first, then Gmail's search streamed in below it), and runs any menu command. Built once and
/// kept hidden, so opening it costs one order-front.
@MainActor
final class CommandBar: NSObject, NSWindowDelegate {
    private let panel: CommandPanel
    private let model = CommandBarModel()
    private weak var parent: NSWindow?
    static let width: CGFloat = 640

    override init() {
        panel = CommandPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        let hosting = NSHostingView(rootView: CommandBarView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        model.close = { [weak self] in self?.hide() }
    }

    func toggle(over window: NSWindow, model windowModel: MailWindowModel) {
        if panel.isVisible { return hide() }
        parent = window
        model.window = windowModel
        model.reset()
        let frame = window.frame
        panel.setFrame(NSRect(x: frame.midX - Self.width / 2, y: frame.maxY - Theme.stripHeight - 12 - 420, width: Self.width, height: 420), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    func hide() {
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

private final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (delegate as? CommandBar)?.hide() }
}

@MainActor
@Observable
final class CommandBarModel {
    var query = "" { didSet { if query != oldValue { refresh() } } }
    var selection = 0
    var focusRequest = 0
    private(set) var sections: [CommandSection] = []
    private(set) var searchingGmail = false
    @ObservationIgnored weak var window: MailWindowModel?
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func reset() {
        query = ""
        selection = 0
        refresh()
    }

    var rows: [CommandRow] { sections.flatMap(\.rows) }

    private func refresh() {
        searchTask?.cancel()
        selection = 0
        let text = query.trimmingCharacters(in: .whitespaces)
        let filter = PageFilter(query: text)
        let destinations = (Destination.rail + Mailbox.allCases.map { .mailbox($0) })
            .filter { !filter.isActive || filter.matches($0.title) }
            .map { CommandRow.go($0) }
        let commands = filter.isActive ? MenuShortcuts.commands().filter { filter.matches($0.title) }.prefix(6).map { CommandRow.command($0) } : []
        var sections = [CommandSection(title: "Go To", rows: destinations)]
        if !commands.isEmpty { sections.append(CommandSection(title: "Commands", rows: Array(commands))) }
        self.sections = sections.filter { !$0.rows.isEmpty }
        guard text.count >= 2 else { return }
        let accounts = window?.accountFilter
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let local = (try? await AppServices.shared.store.search(text, accountIDs: accounts, limit: 30)) ?? []
            guard !Task.isCancelled else { return }
            insert(CommandSection(title: "Mail", rows: local.map { .message($0) } + [.searchGmail(text)]), before: "Commands")
        }
    }

    /// Streams Gmail's own results in under the local ones without moving the highlighted row.
    func searchGmail(_ text: String) {
        searchingGmail = true
        let accounts = window?.accountFilter
        searchTask = Task {
            let found = await AppServices.shared.searchGmail(text, accountIDs: accounts)
            searchingGmail = false
            guard !Task.isCancelled else { return }
            let known = Set(rows.compactMap { if case .message(let m) = $0 { m.id } else { nil } })
            let fresh = found.filter { !known.contains($0.id) }
            sections.removeAll { $0.title == "In Gmail" }
            insert(CommandSection(title: "In Gmail", rows: fresh.isEmpty ? [.note("Nothing more in Gmail.")] : fresh.map { .message($0) }), before: "Commands")
        }
    }

    private func insert(_ section: CommandSection, before title: String) {
        let selected = rows[safe: selection]
        sections.removeAll { $0.title == section.title }
        if let index = sections.firstIndex(where: { $0.title == title }) { sections.insert(section, at: index) } else { sections.append(section) }
        if let selected, let index = rows.firstIndex(of: selected) { selection = index }
    }

    func activate(_ row: CommandRow) {
        switch row {
        case .go(let destination):
            window?.go(to: destination)
            close()
        case .message(let message):
            window?.reveal(message)
            close()
        case .searchGmail(let text):
            searchGmail(text)
        case .command(let command):
            close()
            MenuCommands.perform(command.id)
        case .note:
            break
        }
    }
}

struct CommandSection: Equatable {
    let title: String
    let rows: [CommandRow]
}

enum CommandRow: Hashable {
    case go(Destination)
    case message(MailMessage)
    case searchGmail(String)
    case command(MenuShortcuts.Command)
    case note(String)

    static func == (lhs: CommandRow, rhs: CommandRow) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    var key: String {
        switch self {
        case .go(let d): "go:\(d.id)"
        case .message(let m): "m:\(m.accountID)/\(m.id)"
        case .searchGmail(let t): "gmail:\(t)"
        case .command(let c): "cmd:\(c.id)"
        case .note(let t): "note:\(t)"
        }
    }
}

/// Runs a menu command by its `MenuShortcuts` id, through the menu item itself so tags and
/// validation apply.
@MainActor
enum MenuCommands {
    static func perform(_ id: String) {
        guard let main = NSApp.mainMenu else { return }
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if let submenu = item.submenu, let found = find(submenu) { return found }
                if MenuShortcuts.id(for: item) == id { return (menu, index) }
            }
            return nil
        }
        if let (menu, index) = find(main) {
            menu.update()
            menu.performActionForItem(at: index)
        }
    }
}

private struct CommandBarView: View {
    @Bindable var model: CommandBarModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(pageTertiary)
                TextField("Go to a bucket, search mail, or run a command", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                    .tint(pageAccent)
                    .onKeyPress(.downArrow) { model.selection = min(model.selection + 1, max(model.rows.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { model.selection = max(model.selection - 1, 0); return .handled }
                    .onKeyPress(.return) {
                        if let row = model.rows[safe: model.selection] { model.activate(row) }
                        return .handled
                    }
                    .onKeyPress(.escape) { model.close(); return .handled }
                    .accessibilityLabel("Command bar")
                if model.searchingGmail { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).frame(height: 52)
            SettingsRule()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        let rows = model.rows
                        ForEach(model.sections, id: \.title) { section in
                            ListSectionHeader(title: section.title)
                            ForEach(section.rows, id: \.self) { row in
                                let index = rows.firstIndex(of: row) ?? 0
                                CommandRowView(row: row, isSelected: index == model.selection)
                                    .id(row)
                                    .onTapGesture { model.selection = index; model.activate(row) }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.selection) { _, index in
                    if let row = model.rows[safe: index] { proxy.scrollTo(row) }
                }
            }
        }
        .frame(width: CommandBar.width, height: 420)
        .dropdownSurface()
        .onChange(of: model.focusRequest) { focused = true }
        .onAppear { focused = true }
    }
}

private struct CommandRowView: View {
    let row: CommandRow
    let isSelected: Bool

    var body: some View {
        switch row {
        case .go(let destination):
            ListRow(title: destination.title, figure: shortcut(destination), isSelected: isSelected, showsDot: false)
        case .message(let message):
            ListRow(isUnread: message.isUnread, title: message.subject.nonEmpty ?? "(no subject)",
                    subtitle: "\(message.from.displayName) · \(message.bucket.title)",
                    figure: MailDate.short(message.internalDate), isSelected: isSelected)
        case .searchGmail(let text):
            ListRow(title: "Search Gmail for “\(text)”", figure: "↩", isSelected: isSelected, showsDot: false)
        case .command(let command):
            ListRow(title: command.title, subtitle: command.menu, figure: command.shortcut.display, isSelected: isSelected, showsDot: false)
        case .note(let text):
            Text(text).font(.system(size: 12)).foregroundStyle(pageTertiary).padding(.horizontal, 18).frame(height: 32)
        }
    }

    private func shortcut(_ destination: Destination) -> String {
        let all = Destination.rail + Mailbox.allCases.map { .mailbox($0) }
        return all.firstIndex(of: destination).map { "⌘\($0 + 1)" } ?? ""
    }
}
