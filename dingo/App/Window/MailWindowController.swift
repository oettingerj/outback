import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

/// One mail window: the rail, the middle column, and the detail pane, with AppKit headers that
/// carry each column's title and actions.
@MainActor
final class MailWindowController: NSWindowController, NSWindowDelegate {
    let model = MailWindowModel()
    private let root: MailRootView
    private var headerObservation: ObservationLoop?

    init() {
        let rail = RailContainerView(model: model)
        let middle = NSHostingView(rootView: MiddleColumn(model: model))
        middle.sizingOptions = []
        let detail = NSHostingView(rootView: DetailPane(model: model))
        detail.sizingOptions = []
        root = MailRootView(rail: rail, middle: middle, detail: detail)
        let window = MailWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Dingo"
        // An empty compact toolbar gives the titlebar the headers' 40pt and centers the traffic
        // lights in it, natively.
        window.toolbar = NSToolbar(identifier: "DingoTitlebar")
        window.toolbarStyle = .unifiedCompact
        window.isMovable = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 820, height: 480)
        window.contentView = root
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("DingoMailWindow")
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        headerObservation = ObservationLoop { [weak self] in self?.updateHeaders() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Headers

    private func updateHeaders() {
        let destination = model.destination
        let count: String? = switch destination {
        case .bucket(let bucket): (model.unreadCounts[bucket] ?? 0) > 0 ? "\(model.unreadCounts[bucket]!) unread" : nil
        case .mailbox: model.threads.isEmpty ? nil : "\(model.threads.count)"
        }
        root.middleHeader.set(title: destination.title, count: count)
        root.middleHeader.set(buttons: [
            button("magnifyingglass", "Search Mail", #selector(AppDelegate.showCommandBar(_:))),
            button("square.and.pencil", "New Message", #selector(AppDelegate.newMessage(_:))),
        ])
        root.detailHeader.set(title: "")
        var actions: [NSView] = []
        let hasTarget = !model.actionTarget.isEmpty
        switch destination {
        case .bucket(.inbox), .mailbox:
            actions = [
                button("arrowshape.turn.up.left", "Reply", #selector(AppDelegate.reply(_:))),
                button("arrowshape.turn.up.left.2", "Reply All", #selector(AppDelegate.replyAll(_:))),
                button("arrowshape.turn.up.right", "Forward", #selector(AppDelegate.forward(_:))),
                spacer(),
                button("archivebox", "Archive", #selector(AppDelegate.archive(_:))),
                moveButton(),
                button("trash", "Move to Trash", #selector(AppDelegate.trash(_:))),
            ]
        case .bucket(.newsletters):
            actions = [
                button("envelope.badge", "Mark as Unread", #selector(AppDelegate.toggleRead(_:))),
                button("archivebox", "Archive", #selector(AppDelegate.archive(_:))),
                moveButton(),
                button("safari", "Open in Browser", #selector(AppDelegate.openInGmail(_:))),
            ]
        case .bucket(.notifications), .bucket(.receipts), .bucket(.calendar):
            actions = [
                button("archivebox", "Archive", #selector(AppDelegate.archive(_:))),
                moveButton(),
                button("trash", "Move to Trash", #selector(AppDelegate.trash(_:))),
            ]
        }
        for case let control as NSControl in actions { control.isEnabled = hasTarget }
        root.detailHeader.set(buttons: actions)
    }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> IconButton {
        let button = IconButton(symbol: symbol, label: MenuShortcuts.label(label, for: action), action: action)
        button.setAccessibilityLabel(label)
        return button
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: 8).isActive = true
        return view
    }

    /// Move to Bucket: a pull-down of the other buckets.
    private func moveButton() -> IconButton {
        let button = IconButton(symbol: "tray.and.arrow.down", label: "Move to Bucket (M)", action: #selector(showMoveMenu(_:)), target: self)
        button.setAccessibilityLabel("Move to Bucket")
        return button
    }

    @objc func showMoveMenu(_ sender: NSView) {
        let menu = MoveMenu.build(for: model)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: Single-key commands

    /// j/k and arrows move, e archives, r/a/f reply, s stars, u toggles read, m moves, # trashes,
    /// Tab and ←/→ switch columns. Only when no text view has the keyboard.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, !(window.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers else { return false }
        let delegate = NSApp.delegate as? AppDelegate
        switch key {
        case "j", String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): model.move(1)
        case "k", String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): model.move(-1)
        case "\t", String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)):
            guard model.destination.hasDetailList else { return false }
            model.focus = .detail
        case "\u{19}", String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): model.focus = .middle
        case "e", "y": delegate?.archive(nil)
        case "#", "\u{7f}": delegate?.trash(nil)
        case "r": delegate?.reply(nil)
        case "a": delegate?.replyAll(nil)
        case "f": delegate?.forward(nil)
        case "s": delegate?.toggleStar(nil)
        case "u": delegate?.toggleRead(nil)
        case "c": delegate?.newMessage(nil)
        case "m":
            let menu = MoveMenu.build(for: model)
            let anchor = root.detailHeader
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.width - 220, y: 0), in: anchor)
        case "/": delegate?.showCommandBar(nil)
        default: return false
        }
        return true
    }

    func showDestination(_ destination: Destination) { model.go(to: destination) }
}

/// The Move to Bucket menu, for the header button, the M key, the menu bar, and context menus.
@MainActor
enum MoveMenu {
    static func build(for model: MailWindowModel) -> NSMenu {
        build(messages: model.actionTarget, wholeThread: model.actsOnThreads) { model.notice = $0 }
    }

    static func build(messages: [MailMessage], wholeThread: Bool, notice: @escaping (Notice) -> Void = { _ in }) -> NSMenu {
        let menu = NSMenu(title: "Move to Bucket")
        let current = Set(messages.map(\.bucket))
        for (index, bucket) in Bucket.allCases.enumerated() {
            let item = closureMenuItem(bucket.title) {
                Task {
                    await AppServices.shared.actions.move(messages, to: bucket, rememberSender: false)
                    if let first = messages.first, Set(messages.map(\.fromEmail)).count == 1 {
                        notice(.rule(sender: first.from, accountID: first.accountID, bucket: bucket))
                    }
                }
            }
            item.image = NSImage(systemSymbolName: bucket.symbol, accessibilityDescription: nil)
            item.keyEquivalent = "\(index + 1)"
            item.keyEquivalentModifierMask = []
            item.state = current == [bucket] ? .on : .off
            item.isEnabled = !messages.isEmpty && current != [bucket]
            menu.addItem(item)
        }
        _ = wholeThread
        return menu
    }
}

/// The right-click menu on any message row.
struct MessageContextMenu: View {
    let messages: [MailMessage]
    let wholeThread: Bool

    var body: some View {
        let actions = AppServices.shared.actions
        Button("Reply") { if let m = messages.first { Compose.open(.reply(m, all: false)) } }
        Button("Forward") { if let m = messages.first { Compose.open(.forward(m)) } }
        Divider()
        Button(messages.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread") {
            Task { await actions.setUnread(messages, !messages.contains(where: \.isUnread)) }
        }
        Button(messages.contains(where: \.isStarred) ? "Remove Star" : "Star") {
            Task { await actions.setStarred(messages, !messages.contains(where: \.isStarred)) }
        }
        Menu("Move to Bucket") {
            ForEach(Bucket.allCases) { bucket in
                Button(bucket.title) { Task { await actions.move(messages, to: bucket, rememberSender: false) } }
                    .disabled(Set(messages.map(\.bucket)) == [bucket])
            }
        }
        if let first = messages.first {
            Menu("Always Put Mail from \(first.from.name ?? first.fromEmail) In") {
                ForEach(Bucket.allCases) { bucket in
                    Button(bucket.title) { Task { await actions.move(messages, to: bucket, rememberSender: true) } }
                }
            }
        }
        Divider()
        Button("Archive") { Task { await actions.archive(messages, wholeThread: wholeThread) } }
        Button("Move to Trash") { Task { await actions.trash(messages, wholeThread: wholeThread) } }
        Divider()
        Button("Open in Gmail") { if let m = messages.first { AppServices.shared.openInGmail(m) } }
    }
}

/// A message dragged from a list onto a rail bucket.
struct MessageDrag: Codable, Transferable {
    let accountID: String
    let messageID: String
    let threadID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
