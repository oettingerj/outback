import AppKit
import DingoKit
import Eucalyptus
import Observation
import UserNotifications

/// App-wide state: the database, the signed-in accounts with their Gmail clients and sync
/// engines, and the helpers views call to load bodies and open things.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    let store: MailStore
    private(set) var accounts: [MailAccount] = []
    private(set) var inboxUnread = 0
    /// A sync error worth surfacing, per account.
    private(set) var syncErrors: [String: String] = [:]
    @ObservationIgnored private(set) lazy var actions = MailActions(services: self)

    @ObservationIgnored private var syncs: [String: MailSync] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observations: [Task<Void, Never>] = []
    @ObservationIgnored private var signInTask: Task<GoogleSignIn, Error>?
    @ObservationIgnored private var lastSync: Date = .distantPast

    enum SignInError: LocalizedError {
        case cancelled, notConfigured
        var errorDescription: String? {
            switch self {
            case .cancelled: "Sign-in was cancelled."
            case .notConfigured: "Dingo has no Google OAuth client. Copy App/Secrets.example.xcconfig to App/Secrets.xcconfig, add a Desktop client ID and secret, and rebuild."
            }
        }
    }

    private init() {
        do {
            store = MailStore(database: try AppDatabase.openDefault())
        } catch {
            // A damaged database shouldn't keep the app from opening; mail re-syncs from Gmail.
            NSLog("Dingo: opening the database failed (\(error)); using memory for this session.")
            store = MailStore(database: try! AppDatabase.inMemory())
        }
    }

    // MARK: Startup

    func start() {
        observations.append(Task { [weak self] in
            guard let self else { return }
            do {
                for try await accounts in store.observeAccounts() {
                    self.accounts = accounts
                }
            } catch {}
        })
        observations.append(Task { [weak self] in
            guard let self else { return }
            do {
                for try await counts in store.observeUnreadCounts(accountIDs: nil) { inboxUnread = counts[.inbox] ?? 0 }
            } catch {}
        })
        #if DEBUG
        SampleMail.seedIfRequested()
        #endif
        Task {
            accounts = (try? await store.accounts()) ?? []
            for account in accounts { makeSync(for: account.email) }
            syncSoon(force: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppServices.shared.syncSoon() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    private var oauth: GoogleOAuth? {
        let info = Bundle.main.infoDictionary
        guard let id = info?["GoogleClientID"] as? String, let secret = info?["GoogleClientSecret"] as? String,
              !id.isEmpty, !secret.isEmpty else { return nil }
        return GoogleOAuth(client: GoogleOAuthClient(id: id, secret: secret)) { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
    }

    @discardableResult
    private func makeSync(for email: String) -> MailSync? {
        if let sync = syncs[email] { return sync }
        #if DEBUG
        if email == SampleMail.account { return nil }
        #endif
        guard let oauth, let refreshToken = GoogleKeychain.refreshToken(for: email) else {
            syncErrors[email] = "Sign in to \(email) again in Settings › Accounts."
            return nil
        }
        let tokens = AccessTokenSource(refreshToken: refreshToken, oauth: oauth)
        let sync = MailSync(account: email, client: GmailClient(account: email, tokens: tokens), store: store,
                            windowDays: Preferences.syncWindowDays, archivesSortedMail: Preferences.archivesSortedMail)
        syncs[email] = sync
        return sync
    }

    func sync(for accountID: String) -> MailSync? { syncs[accountID] ?? makeSync(for: accountID) }

    // MARK: Accounts

    func addAccount() async throws {
        guard let oauth else { throw SignInError.notConfigured }
        signInTask?.cancel()
        let task = Task { try await oauth.signIn() }
        signInTask = task
        let signIn: GoogleSignIn
        do {
            signIn = try await task.value
        } catch is CancellationError {
            throw SignInError.cancelled
        } catch GoogleOAuthError.cancelled {
            throw SignInError.cancelled
        }
        NSApp.activate()
        let email = signIn.emailAddress.lowercased()
        guard GoogleKeychain.save(refreshToken: signIn.refreshToken, for: email) else {
            throw NSError(domain: "Dingo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn’t save the sign-in to the Keychain."])
        }
        try await store.upsert(MailAccount(email: email, sendAs: [EmailAddress(email: email)], position: accounts.count))
        syncs[email] = nil
        syncErrors[email] = nil
        makeSync(for: email)
        accounts = (try? await store.accounts()) ?? accounts
        Task { await runSync(email) }
    }

    func cancelSignIn() { signInTask?.cancel() }

    func removeAccount(_ email: String) async {
        syncs[email] = nil
        GoogleKeychain.delete(account: email)
        try? await store.removeAccount(email)
        accounts = (try? await store.accounts()) ?? []
    }

    // MARK: Sync

    /// Syncs every account unless one ran in the last 20 seconds.
    func syncSoon(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSync) > 20 else { return }
        lastSync = Date()
        for account in accounts { Task { await runSync(account.email) } }
    }

    private func runSync(_ email: String) async {
        #if DEBUG
        if email == SampleMail.account { return }
        #endif
        guard let sync = sync(for: email) else { return }
        await sync.configure(windowDays: Preferences.syncWindowDays, archivesSortedMail: Preferences.archivesSortedMail)
        do {
            let report = try await sync.sync()
            syncErrors[email] = nil
            if !report.wasFullSync { notify(report.newInbox) }
            try? await sync.prefetchBodies()
        } catch GmailError.unauthorized {
            syncErrors[email] = "Gmail stopped accepting Dingo’s sign-in for \(email). Remove the account and add it again."
        } catch GoogleOAuthError.invalidGrant {
            syncErrors[email] = "The sign-in for \(email) expired. Remove the account and add it again."
        } catch {
            syncErrors[email] = "Couldn’t sync \(email): \(Self.describe(error))"
        }
    }

    private func notify(_ messages: [MailMessage]) {
        guard Preferences.notifiesNewMail, !NSApp.isActive else { return }
        for message in messages.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = message.from.displayName
            content.subtitle = message.subject
            content.body = message.snippet
            content.threadIdentifier = message.threadID
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(message.accountID)/\(message.id)", content: content, trigger: nil))
        }
    }

    // MARK: Addresses

    var ownAddresses: Set<String> { Set(accounts.flatMap { account in [account.email] + account.sendAs.map { $0.email.lowercased() } }) }

    func isMine(_ email: String) -> Bool { ownAddresses.contains(email.lowercased()) }

    /// Every address you can send as, primary addresses first.
    var senders: [EmailAddress] {
        accounts.flatMap { account in
            let primary = account.sendAs.first { $0.email.lowercased() == account.email } ?? EmailAddress(name: account.displayName, email: account.email)
            return [primary] + account.sendAs.filter { $0.email.lowercased() != account.email }
        }
    }

    func accountID(owning email: String) -> String? {
        accounts.first { $0.email == email.lowercased() || $0.sendAs.contains { $0.email.lowercased() == email.lowercased() } }?.email
    }

    func sender(forAccount accountID: String) -> EmailAddress? { senders.first { self.accountID(owning: $0.email) == accountID } }

    /// A reply goes out from the address the original was sent to; new mail from the first account.
    func defaultSender(for start: ComposeStart) -> EmailAddress? {
        switch start {
        case .reply(let message, _), .forward(let message):
            let recipients = (message.to + message.cc).map { $0.email.lowercased() }
            return senders.first { recipients.contains($0.email.lowercased()) } ?? sender(forAccount: message.accountID)
        case .new:
            return senders.first
        }
    }

    func contacts(matching prefix: String) async -> [EmailAddress] {
        (try? await store.contacts(matching: prefix)) ?? []
    }

    // MARK: Bodies and attachments

    func body(for message: MailMessage) async throws -> MailBody? {
        if let body = try await store.body(accountID: message.accountID, messageID: message.id) { return body }
        guard let sync = sync(for: message.accountID) else { return nil }
        return try await sync.fetchBody(messageID: message.id)
    }

    func inlinePart(cid: String, in message: MailMessage, body: MailBody) async -> (Data, String)? {
        guard let part = body.inline[cid] ?? body.inline["<\(cid)>"] else { return nil }
        if let data = part.data { return (data, part.mimeType) }
        guard let attachmentID = part.attachmentID, let sync = sync(for: message.accountID),
              let data = try? await sync.client.attachment(messageID: message.id, attachmentID: attachmentID) else { return nil }
        return (data, part.mimeType)
    }

    func attachmentData(_ attachment: MailAttachment) async throws -> Data {
        guard let attachmentID = attachment.attachmentID, let sync = sync(for: attachment.accountID) else {
            throw NSError(domain: "Dingo", code: 2, userInfo: [NSLocalizedDescriptionKey: "This attachment can’t be downloaded."])
        }
        return try await sync.client.attachment(messageID: attachment.messageID, attachmentID: attachmentID)
    }

    /// Downloads to Downloads (sandbox: the downloads entitlement) and opens it.
    func open(_ attachment: MailAttachment) async {
        do {
            let data = try await attachmentData(attachment)
            let folder = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var url = folder.appendingPathComponent(attachment.filename.replacingOccurrences(of: "/", with: "-"))
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path) {
                let base = (attachment.filename as NSString).deletingPathExtension, ext = (attachment.filename as NSString).pathExtension
                url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
                counter += 1
            }
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    /// Hands the invite's .ics to Calendar.
    func openInCalendar(_ message: MailMessage) async {
        guard let ics = try? await body(for: message)?.calendar else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invite-\(message.id).ics")
        try? Data(ics.utf8).write(to: url)
        let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")
        if let calendar {
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: calendar, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openInGmail(_ message: MailMessage) {
        if let url = URL(string: "https://mail.google.com/mail/u/\(message.accountID)/#all/\(message.threadID)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Marks a message read once it has been on screen, as Gmail does.
    func markReadOnOpen(_ message: MailMessage) {
        guard message.isUnread, let delay = Preferences.markReadDelay else { return }
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await actions.setUnread([message], false, undoable: false)
        }
    }

    func searchGmail(_ query: String, accountIDs: Set<String>?) async -> [MailMessage] {
        var results: [MailMessage] = []
        for account in accounts where accountIDs?.contains(account.email) ?? true {
            if let found = try? await sync(for: account.email)?.search(query) { results += found }
        }
        return results.sorted { $0.internalDate > $1.internalDate }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case GoogleOAuthError.denied: "Google sign-in was declined."
        case GoogleOAuthError.timedOut: "Sign-in timed out. Try again."
        case GoogleOAuthError.network, GmailError.rateLimited: "Gmail couldn’t be reached. Check your connection and try again."
        case GoogleOAuthError.misconfigured(let detail): "Google rejected Dingo’s OAuth client: \(detail)"
        case GmailError.http(let status, let message): "Gmail answered \(status)\(message.map { ": \($0)" } ?? "")."
        default: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
