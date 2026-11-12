import AppKit
import DingoKit
import Eucalyptus

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [MailWindowController] = []
    private var dockBadge: ObservationLoop?
    private lazy var commandBar = CommandBar()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        AppServices.shared.start()
        dockBadge = ObservationLoop {
            let count = AppServices.shared.inboxUnread
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        newWindow(nil)
        Perf.record("launch.windowShown", Perf.sinceProcessStart)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { newWindow(nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppServices.shared.syncSoon()
    }

    // MARK: Windows

    private var frontmost: MailWindowController? {
        (NSApp.keyWindow?.windowController as? MailWindowController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? MailWindowController }.first
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = MailWindowController()
        windows.append(controller)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window, queue: .main) { [weak self, weak controller] _ in
            MainActor.assumeIsolated { self?.windows.removeAll { $0 === controller } }
        }
        if windows.count > 1, let previous = windows.dropLast().last?.window {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        controller.showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }

    @objc func showDestination(_ sender: NSMenuItem) {
        let all = Destination.rail + Mailbox.allCases.map { .mailbox($0) }
        guard all.indices.contains(sender.tag) else { return }
        ensureWindow().showDestination(all[sender.tag])
    }

    @objc func showCommandBar(_ sender: Any?) {
        let controller = ensureWindow()
        guard let window = controller.window else { return }
        commandBar.toggle(over: window, model: controller.model)
    }

    /// Search Mail… is the command bar; a separate action so the two menu items keep separate shortcuts.
    @objc func searchMail(_ sender: Any?) { showCommandBar(sender) }

    private func ensureWindow() -> MailWindowController {
        if let frontmost { return frontmost }
        newWindow(nil)
        return windows.last!
    }

    // MARK: Accounts and sync

    @objc func addAccount(_ sender: Any?) {
        Task {
            do { try await AppServices.shared.addAccount() } catch AppServices.SignInError.cancelled {
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t add the account"
                alert.informativeText = AppServices.describe(error)
                alert.runModal()
            }
        }
    }

    @objc func syncNow(_ sender: Any?) { AppServices.shared.syncSoon(force: true) }

    // MARK: Compose

    @objc func newMessage(_ sender: Any?) { Compose.open(.new()) }

    @objc func composeMailto(_ sender: Any?) {
        if let url = sender as? URL { Compose.open(mailto: url) }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string),
              url.scheme?.lowercased() == "mailto" else { return }
        Compose.open(mailto: url)
    }

    private var target: [MailMessage] { frontmost?.model.actionTarget ?? [] }
    private var wholeThread: Bool { frontmost?.model.actsOnThreads ?? false }

    @objc func reply(_ sender: Any?) { if let message = target.first { Compose.open(.reply(message, all: false)) } }
    @objc func replyAll(_ sender: Any?) { if let message = target.first { Compose.open(.reply(message, all: true)) } }
    @objc func forward(_ sender: Any?) { if let message = target.first { Compose.open(.forward(message)) } }

    // MARK: Triage

    @objc func archive(_ sender: Any?) {
        let messages = target, thread = wholeThread
        guard !messages.isEmpty else { return }
        frontmost?.model.move(1)
        Task { await AppServices.shared.actions.archive(messages, wholeThread: thread) }
    }

    @objc func trash(_ sender: Any?) {
        let messages = target, thread = wholeThread
        guard !messages.isEmpty else { return }
        frontmost?.model.move(1)
        Task { await AppServices.shared.actions.trash(messages, wholeThread: thread) }
    }

    @objc func toggleRead(_ sender: Any?) {
        let messages = target
        Task { await AppServices.shared.actions.setUnread(messages, !messages.contains(where: \.isUnread)) }
    }

    @objc func toggleStar(_ sender: Any?) {
        let messages = target
        Task { await AppServices.shared.actions.setStarred(messages, !messages.contains(where: \.isStarred)) }
    }

    @objc func moveToBucket(_ sender: NSMenuItem) {
        guard Bucket.allCases.indices.contains(sender.tag), let model = frontmost?.model else { return }
        let messages = target, bucket = Bucket.allCases[sender.tag]
        Task {
            await AppServices.shared.actions.move(messages, to: bucket, rememberSender: false)
            if let first = messages.first, Set(messages.map(\.fromEmail)).count == 1 {
                model.notice = .rule(sender: first.from, accountID: first.accountID, bucket: bucket)
            }
        }
    }

    @objc func alwaysMoveSender(_ sender: NSMenuItem) {
        guard Bucket.allCases.indices.contains(sender.tag) else { return }
        let messages = target
        Task { await AppServices.shared.actions.move(messages, to: Bucket.allCases[sender.tag], rememberSender: true) }
    }

    @objc func unsubscribe(_ sender: Any?) {
        guard let message = target.first, let model = frontmost?.model else { return }
        Task {
            let result = await Unsubscribe.perform(message)
            model.notice = .undo(result)
        }
    }

    @objc func openInGmail(_ sender: Any?) { if let message = target.first { AppServices.shared.openInGmail(message) } }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let messages = target
        switch item.action {
        case #selector(reply(_:)), #selector(replyAll(_:)), #selector(forward(_:)), #selector(archive(_:)), #selector(trash(_:)),
             #selector(moveToBucket(_:)), #selector(alwaysMoveSender(_:)), #selector(openInGmail(_:)):
            if item.action == #selector(moveToBucket(_:)) {
                item.state = messages.count > 0 && Set(messages.map(\.bucket)) == [Bucket.allCases[item.tag]] ? .on : .off
            }
            return !messages.isEmpty
        case #selector(toggleRead(_:)):
            item.title = messages.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread"
            return !messages.isEmpty
        case #selector(toggleStar(_:)):
            item.title = messages.contains(where: \.isStarred) ? "Remove Star" : "Star"
            return !messages.isEmpty
        case #selector(unsubscribe(_:)):
            return messages.first.map { Unsubscribe.target(for: $0) != nil } ?? false
        case #selector(showDestination(_:)):
            let all = Destination.rail + Mailbox.allCases.map { .mailbox($0) }
            item.state = frontmost?.model.destination == all[safe: item.tag] ? .on : .off
            return true
        default:
            return true
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
