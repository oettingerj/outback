import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

/// Settings, in Koala's page idiom: one scrolling column of sections on chrome surface, a search
/// field that filters every row, hairlines between rows.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { return window.makeKeyAndOrderFront(nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.contentView = NSHostingView(rootView: SettingsPage())
        window.setFrameAutosaveName("DingoSettings")
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// Settings that live in user defaults.
@MainActor
enum Preferences {
    /// Mark a message read when it has been open this long; 0 marks on open, nil never.
    static var markReadDelay: Double? {
        get { UserDefaults.standard.object(forKey: "MarkReadDelay") == nil ? 0 : (UserDefaults.standard.double(forKey: "MarkReadDelay") < 0 ? nil : UserDefaults.standard.double(forKey: "MarkReadDelay")) }
        set { UserDefaults.standard.set(newValue ?? -1, forKey: "MarkReadDelay") }
    }

    /// How far back the first sync of an account reaches, in days.
    static var syncWindowDays: Int {
        get { UserDefaults.standard.object(forKey: "SyncWindowDays") as? Int ?? 90 }
        set { UserDefaults.standard.set(newValue, forKey: "SyncWindowDays") }
    }

    /// Whether sorting takes bucketed threads out of Gmail's Inbox (the label is added either way).
    static var archivesSortedMail: Bool {
        get { UserDefaults.standard.object(forKey: "ArchivesSortedMail") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ArchivesSortedMail") }
    }

    /// Load remote images in every message, not only from trusted senders.
    static var loadsRemoteImages: Bool {
        get { UserDefaults.standard.bool(forKey: "LoadsRemoteImages") }
        set { UserDefaults.standard.set(newValue, forKey: "LoadsRemoteImages") }
    }

    /// Notify for new mail in the Inbox. Buckets never notify.
    static var notifiesNewMail: Bool {
        get { UserDefaults.standard.object(forKey: "NotifiesNewMail") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "NotifiesNewMail") }
    }
}

private struct SettingsPage: View {
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var rules: [SenderRule] = []
    @State private var trusted = RemoteContent.trusted
    @State private var shortcuts = MenuShortcuts.commands()
    @State private var recording = ShortcutRecording()
    @State private var markRead = Preferences.markReadDelay != nil
    @State private var archives = Preferences.archivesSortedMail
    @State private var notifies = Preferences.notifiesNewMail
    @State private var loadsRemote = Preferences.loadsRemoteImages
    @State private var syncDays = Preferences.syncWindowDays
    @State private var accountError: String?

    private var filter: PageFilter { PageFilter(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            PageColumn(width: 640) {
                Text("Settings").font(.system(size: 20, weight: .semibold)).foregroundStyle(settingsPrimary)
                    .accessibilityAddTraits(.isHeader).padding(.bottom, 14)
                PageSearchField(prompt: "Search settings", text: $query, focused: $searchFocused)
            }
            .padding(.top, 36).padding(.bottom, 12)
            SettingsRule()
            ScrollView {
                PageColumn(width: 640) {
                    section("Accounts", "Each Gmail account’s mail joins the same Inbox and buckets.") {
                        ForEach(AppServices.shared.accounts) { account in
                            row(account.email, account.lastSyncAt.map { "Last synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet") {
                                Button("Remove…") { remove(account) }
                            }
                        }
                        row("Add Account", "Sign in with Google in your browser.") {
                            Button("Add Account…") {
                                Task {
                                    do { try await AppServices.shared.addAccount() } catch { accountError = AppServices.describe(error) }
                                }
                            }
                            .buttonStyle(SettingsPrimaryButtonStyle())
                        }
                        if let accountError { Text(accountError).font(.system(size: 11)).foregroundStyle(settingsFail).padding(.vertical, 6) }
                    }
                    section("Buckets", "Dingo sorts mail by its headers and content. Moving mail to another bucket can teach it a sender rule.") {
                        row("Take sorted mail out of Gmail’s Inbox", "Sorted threads keep their Dingo label in Gmail either way.") {
                            Toggle("", isOn: $archives).settingsSwitch().onChange(of: archives) { Preferences.archivesSortedMail = archives }
                        }
                        if rules.isEmpty {
                            row("Sender rules", "None yet. Choose Message › Always Put Mail from Sender In to add one.") { EmptyView() }
                        }
                        ForEach(rules) { rule in
                            row(rule.matcher, "Always \(rule.bucket.title)\(rule.accountID.map { " · \($0)" } ?? "")") {
                                Button("Delete") { Task { await AppServices.shared.actions.deleteRule(rule); await loadRules() } }
                            }
                        }
                    }
                    section("Reading", "How messages open and what they may load.") {
                        row("Mark messages read when opened", nil) {
                            Toggle("", isOn: $markRead).settingsSwitch().onChange(of: markRead) { Preferences.markReadDelay = markRead ? 0 : nil }
                        }
                        row("Notify for new mail in the Inbox", "Buckets never notify.") {
                            Toggle("", isOn: $notifies).settingsSwitch().onChange(of: notifies) { Preferences.notifiesNewMail = notifies }
                        }
                        row("Keep mail from the last", "How far back a new account’s first sync reaches. Older mail is found through search.") {
                            Picker("", selection: $syncDays) {
                                Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                            }
                            .labelsHidden().fixedSize().onChange(of: syncDays) { Preferences.syncWindowDays = syncDays }
                        }
                        row("Load remote images in all mail", "Senders can see when you open their mail. When off, images load only from senders you trust.") {
                            Toggle("", isOn: $loadsRemote).settingsSwitch().onChange(of: loadsRemote) { Preferences.loadsRemoteImages = loadsRemote }
                        }
                        ForEach(trusted, id: \.self) { sender in
                            row(sender, "Loads remote images") {
                                Button("Stop") { RemoteContent.revoke(sender); trusted = RemoteContent.trusted }
                            }
                        }
                    }
                    section("Keyboard Shortcuts", "Change the shortcut for any menu command. Click a shortcut, then press the new keys. Single keys in lists: J and K move, E archives, R replies, A replies all, F forwards, S stars, U toggles read, M moves to a bucket.") {
                        ForEach(shortcuts) { command in
                            row(command.title, recording.commandID == command.id ? (recording.issue ?? command.menu) : command.menu) {
                                ShortcutKeys(shortcut: command.shortcut, isRecording: recording.commandID == command.id, filter: filter) {
                                    if recording.commandID == command.id { recording.stop() } else {
                                        recording.start(command.id) { shortcut in
                                            MenuShortcuts.set(shortcut, for: command.id)
                                            shortcuts = MenuShortcuts.commands()
                                        }
                                    }
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Restore Defaults") { MenuShortcuts.resetAll(); shortcuts = MenuShortcuts.commands() }
                                .disabled(!shortcuts.contains(where: \.isCustomized))
                        }
                        .padding(.top, 12)
                    }
                    footer
                }
                .padding(.bottom, 40)
            }
        }
        .background(Color(nsColor: Theme.chromeSurface))
        .task { await loadRules() }
        .onDisappear { recording.stop() }
    }

    private func loadRules() async { rules = (try? await AppServices.shared.store.rules()) ?? [] }

    private func remove(_ account: MailAccount) {
        let alert = NSAlert()
        alert.messageText = "Remove \(account.email) from Dingo?"
        alert.informativeText = "Its mail stays in Gmail. Dingo deletes its local copy and signs out."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await AppServices.shared.removeAccount(account.email) }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, _ summary: String, @ViewBuilder content: () -> Content) -> some View {
        let content = content()
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(settingsPrimary).accessibilityAddTraits(.isHeader)
            Text(summary).font(.system(size: 12)).foregroundStyle(settingsTertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3).padding(.bottom, 10)
            content
        }
        .padding(.top, 32)
        .environment(\.pageFilter, filter)
    }

    private func row<Control: View>(_ title: String, _ detail: String?, @ViewBuilder control: () -> Control) -> some View {
        FilteredRow(title: title, detail: detail, control: control())
    }

    private var footer: some View {
        let info = Bundle.main.infoDictionary
        return Text("Dingo \(info?["CFBundleShortVersionString"] as? String ?? "—") (\(info?["CFBundleVersion"] as? String ?? "—"))")
            .font(.mono(size: 11)).foregroundStyle(settingsTertiary).textSelection(.enabled).padding(.top, 40)
    }
}

extension EnvironmentValues {
    @Entry var pageFilter = PageFilter()
}

/// A settings row hidden when the search doesn't match it, matches in semibold.
private struct FilteredRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control
    @Environment(\.pageFilter) private var filter

    var body: some View {
        if filter.matches([title, detail ?? ""].joined(separator: " ")) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(filter.highlight(title, size: 13)).font(.system(size: 13)).foregroundStyle(settingsPrimary)
                    if let detail {
                        Text(filter.highlight(detail, size: 11)).font(.system(size: 11)).foregroundStyle(settingsTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                control.fixedSize()
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .top) { SettingsRule() }
            .accessibilityElement(children: .contain)
        }
    }
}
