import AppKit
import DingoKit
import Eucalyptus

/// Everything that changes mail. Each action changes the local cache first, so every view
/// updates in the same frame, then tells Gmail; when Gmail refuses, the local change is put
/// back and the window says why. The last triage action can be undone (⌘Z or the notice bar).
@MainActor
final class MailActions {
    private unowned let services: AppServices
    private var store: MailStore { services.store }
    /// Puts the last action back: the reverse label edits, applied the same way.
    private var lastUndo: (() async -> Void)?

    init(services: AppServices) { self.services = services }

    // MARK: Optimistic changes

    /// Runs a local change (which returns what the messages looked like before), pushes the label
    /// difference to Gmail, and on failure restores the snapshot. A described change can be undone.
    @discardableResult
    private func perform(_ describe: String?, _ change: () async throws -> [MessageStateSnapshot]) async -> Bool {
        let snapshots: [MessageStateSnapshot]
        do {
            snapshots = try await change().filter { !$0.labelIDs.isEmpty }
        } catch {
            post(.error("Couldn’t change that mail: \(AppServices.describe(error))"))
            return false
        }
        do {
            try await push(from: snapshots)
            if let describe {
                lastUndo = { [weak self] in await self?.revert(snapshots) }
                registerUndo(describe)
                post(.undo(describe))
            }
            return true
        } catch {
            for snapshot in snapshots { try? await store.restore(snapshot) }
            post(.error("Gmail didn’t accept that change: \(AppServices.describe(error))"))
            return false
        }
    }

    /// Sends Gmail the label edits that turn each snapshot's labels into what the cache holds now.
    private func push(from snapshots: [MessageStateSnapshot]) async throws {
        for snapshot in snapshots { try await push(accountID: snapshot.accountID, before: snapshot.labelIDs) }
    }

    private func push(accountID: String, before labelIDs: [String: [String]]) async throws {
        #if DEBUG
        if accountID == SampleMail.account { return } // synthetic mail lives only in the cache
        #endif
        guard let sync = services.sync(for: accountID) else { throw MailActionError.signedOut(accountID) }
        let current = try await store.messages(accountID: accountID, ids: Array(labelIDs.keys))
        var groups: [String: (add: [String], remove: [String], ids: [String])] = [:]
        for message in current {
            let before = Set(labelIDs[message.id] ?? [])
            let after = Set(message.labelIDs)
            let add = after.subtracting(before).sorted(), remove = before.subtracting(after).sorted()
            guard !add.isEmpty || !remove.isEmpty else { continue }
            groups[add.joined(separator: ",") + "|" + remove.joined(separator: ","), default: (add, remove, [])].ids.append(message.id)
        }
        for group in groups.values {
            for start in stride(from: 0, to: group.ids.count, by: 1000) {
                try await sync.client.batchModify(ids: Array(group.ids[start..<min(start + 1000, group.ids.count)]), add: group.add, remove: group.remove)
            }
        }
    }

    /// Undo: put the snapshots back locally, then push that difference too.
    private func revert(_ snapshots: [MessageStateSnapshot]) async {
        do {
            for snapshot in snapshots {
                let current = try await store.messages(accountID: snapshot.accountID, ids: snapshot.messageIDs)
                try await store.restore(snapshot)
                try await push(accountID: snapshot.accountID, before: Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.labelIDs) }))
            }
        } catch {
            post(.error("Couldn’t undo in Gmail: \(AppServices.describe(error))"))
        }
    }

    /// One store call per account, over threads or single messages.
    private func each(_ messages: [MailMessage], wholeThread: Bool,
                      _ change: (MessageSelection, String) async throws -> MessageStateSnapshot) async throws -> [MessageStateSnapshot] {
        var snapshots: [MessageStateSnapshot] = []
        for (account, group) in Dictionary(grouping: messages, by: \.accountID) {
            if wholeThread {
                for threadID in Set(group.map(\.threadID)) { snapshots.append(try await change(.thread(threadID), account)) }
            } else {
                snapshots.append(try await change(.messages(group.map(\.id)), account))
            }
        }
        return snapshots
    }

    // MARK: Triage

    /// Done with it: out of the Inbox and out of its bucket; it stays in All Mail.
    func archive(_ messages: [MailMessage], wholeThread: Bool) async {
        await perform(count(messages, "Archived", wholeThread: wholeThread)) {
            try await each(messages, wholeThread: wholeThread) { try await store.archive($0, accountID: $1) }
        }
    }

    func trash(_ messages: [MailMessage], wholeThread: Bool) async {
        await perform(count(messages, "Moved to Trash", wholeThread: wholeThread)) {
            try await each(messages, wholeThread: wholeThread) { try await store.trash($0, accountID: $1) }
        }
    }

    /// Reading marks the whole conversation read; unread marks only the given messages.
    func setUnread(_ messages: [MailMessage], _ unread: Bool, undoable: Bool = true) async {
        await perform(undoable ? (unread ? "Marked as unread" : "Marked as read") : nil) {
            try await each(messages, wholeThread: !unread) { try await store.setUnread(unread, $0, accountID: $1) }
        }
    }

    func setStarred(_ messages: [MailMessage], _ starred: Bool) async {
        await perform(starred ? "Starred" : "Removed star") {
            try await each(messages, wholeThread: false) { try await store.setStarred(starred, $0, accountID: $1) }
        }
    }

    /// Moves mail to a bucket here and in Gmail. Inbox conversations move whole. With
    /// `rememberSender`, a sender rule sends their future mail there and their filed mail follows now.
    func move(_ messages: [MailMessage], to bucket: Bucket, rememberSender: Bool) async {
        guard let first = messages.first else { return }
        var others: [MailMessage] = []
        if rememberSender {
            for sender in Set(messages.map(\.fromEmail)) {
                _ = try? await store.setRule(matcher: sender, bucket: bucket, accountID: nil)
                others += ((try? await store.messages(from: sender, accountIDs: nil, limit: 500)) ?? []).filter { $0.bucket != bucket }
            }
        }
        let wholeThread = first.bucket == .inbox
        let who = messages.count == 1 ? (first.subject.nonEmpty.map { "“\($0)”" } ?? "1 message") : "\(messages.count) messages"
        let moved = await perform("Moved \(who) to \(bucket.title)") {
            var snapshots = try await each(messages, wholeThread: wholeThread) { try await store.moveToBucket(bucket, $0, accountID: $1) }
            let done = Set(messages.map { "\($0.accountID)/\($0.id)" })
            let rest = others.filter { !done.contains("\($0.accountID)/\($0.id)") }
            if !rest.isEmpty { snapshots += try await each(rest, wholeThread: false) { try await store.moveToBucket(bucket, $0, accountID: $1) } }
            return snapshots
        }
        if moved { BucketFlight.launch(to: bucket) }
    }

    /// From the notice bar's "Always": a rule for this sender, and their filed mail follows.
    func remember(sender: EmailAddress, accountID: String, bucket: Bucket) async {
        _ = try? await store.setRule(matcher: sender.email.lowercased(), bucket: bucket, accountID: nil)
        let mail = ((try? await store.messages(from: sender.email, accountIDs: nil, limit: 500)) ?? []).filter { $0.bucket != bucket }
        guard !mail.isEmpty else { return }
        await perform("Moved \(mail.count) from \(sender.name ?? sender.email) to \(bucket.title)") {
            try await each(mail, wholeThread: false) { try await store.moveToBucket(bucket, $0, accountID: $1) }
        }
    }

    func deleteRule(_ rule: SenderRule) async {
        if let id = rule.id { try? await store.deleteRule(id: id) }
    }

    /// Puts the action on the key window's undo stack, so ⌘Z and Edit › Undo take it back.
    private func registerUndo(_ name: String) {
        guard let manager = NSApp.keyWindow?.undoManager else { return }
        manager.registerUndo(withTarget: self) { actions in
            MainActor.assumeIsolated { _ = Task { await actions.undo() } }
        }
        manager.setActionName(name.components(separatedBy: " ").first ?? name)
    }

    func undo() async {
        guard let undo = lastUndo else { return }
        lastUndo = nil
        await undo()
    }

    var canUndo: Bool { lastUndo != nil }

    // MARK: Invites

    /// Answers an invitation with an iMIP REPLY to the organizer, from the invited address.
    func respond(to row: EventRow, with status: ParticipationStatus) async {
        let response: IMIPReply.Response = switch status {
        case .accepted: .accepted
        case .tentative: .tentative
        default: .declined
        }
        do {
            guard let ics = try await services.body(for: row.message)?.calendar,
                  let invite = ICalendarParser.parse(ics), let event = invite.primaryEvent,
                  let organizer = event.organizer else {
                throw MailActionError.noInvite
            }
            let mine = services.ownAddresses
            let me = event.attendee(matching: mine).map { EmailAddress(name: $0.name, email: $0.email) }
                ?? services.sender(forAccount: row.message.accountID)
            guard let me else { throw MailActionError.signedOut(row.message.accountID) }
            let verb = switch response {
            case .accepted: "Accepted"
            case .tentative: "Tentatively Accepted"
            case .declined: "Declined"
            }
            var builder = MessageBuilder(from: me, to: [organizer], subject: "\(verb): \(event.summary ?? row.message.subject)",
                                         text: "\(me.displayName) has \(verb.lowercased()) this invitation.")
            builder.calendar = .init(ics: IMIPReply.make(event: event, attendee: me, response: response), method: "REPLY")
            try await send(builder, accountID: row.message.accountID, threadID: nil, draftID: nil)
            try await store.setMyResponse(accountID: row.message.accountID, messageID: row.message.id, response: status)
        } catch {
            post(.error("Couldn’t send your answer: \(AppServices.describe(error))"))
        }
    }

    // MARK: Drafts and sending

    /// Creates or updates the Gmail draft; returns its ID.
    func saveDraft(_ builder: MessageBuilder, accountID: String, threadID: String?, draftID: String?) async throws -> String {
        guard let sync = services.sync(for: accountID) else { throw MailActionError.signedOut(accountID) }
        let raw = builder.build()
        if let draftID {
            do { return try await sync.client.updateDraft(id: draftID, raw: raw, threadID: threadID).id } catch GmailError.notFound {}
        }
        return try await sync.client.createDraft(raw: raw, threadID: threadID).id
    }

    func send(_ builder: MessageBuilder, accountID: String, threadID: String?, draftID: String?) async throws {
        guard let sync = services.sync(for: accountID) else { throw MailActionError.signedOut(accountID) }
        if let draftID {
            _ = try await sync.client.updateDraft(id: draftID, raw: builder.build(), threadID: threadID)
            _ = try await sync.client.sendDraft(id: draftID)
        } else {
            _ = try await sync.client.send(raw: builder.build(), threadID: threadID)
        }
        services.syncSoon(force: true)
    }

    func deleteDraft(_ draftID: String, accountID: String) async {
        try? await services.sync(for: accountID)?.client.deleteDraft(id: draftID)
    }

    // MARK: Notices

    private func post(_ notice: Notice) {
        let windows = NSApp.windows.compactMap { $0.windowController as? MailWindowController }
        let target = (NSApp.keyWindow?.windowController as? MailWindowController) ?? windows.first
        target?.model.notice = notice
    }

    private func count(_ messages: [MailMessage], _ verb: String, wholeThread: Bool) -> String {
        let noun = wholeThread ? "conversation" : "message"
        return messages.count == 1 ? "\(verb) 1 \(noun)" : "\(verb) \(messages.count) \(noun)s"
    }
}

enum MailActionError: LocalizedError {
    case signedOut(String)
    case noInvite

    var errorDescription: String? {
        switch self {
        case .signedOut(let account): "\(account) isn’t signed in."
        case .noInvite: "This message has no invitation Dingo can answer."
        }
    }
}
