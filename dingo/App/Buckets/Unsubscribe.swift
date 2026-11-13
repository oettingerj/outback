import AppKit
import DingoKit

/// Leaving a mailing list the way its List-Unsubscribe header says: RFC 8058 one-click POST
/// when offered, else an unsubscribe email from the account it was sent to, else the web page.
@MainActor
enum Unsubscribe {
    enum Target: Equatable {
        case oneClick(URL)
        case mail(EmailAddress, subject: String)
        case page(URL)
    }

    static func target(for message: MailMessage) -> Target? {
        guard let header = message.listUnsubscribe else { return nil }
        let entries = header.matches(of: #/<([^>]+)>/#).map { String($0.output.1) }
        let https = entries.compactMap(URL.init(string:)).first { $0.scheme?.lowercased() == "https" }
        if let https, message.listUnsubscribePost?.range(of: "One-Click", options: .caseInsensitive) != nil {
            return .oneClick(https)
        }
        if let mailto = entries.compactMap(URL.init(string:)).first(where: { $0.scheme?.lowercased() == "mailto" }),
           let components = URLComponents(url: mailto, resolvingAgainstBaseURL: false), !components.path.isEmpty {
            let subject = components.queryItems?.first { $0.name.lowercased() == "subject" }?.value ?? "unsubscribe"
            return .mail(EmailAddress(email: components.path), subject: subject)
        }
        return https.map(Target.page)
    }

    /// Returns a sentence saying what happened.
    static func perform(_ message: MailMessage) async -> String {
        let name = message.from.name ?? message.fromEmail
        switch target(for: message) {
        case .oneClick(let url):
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            request.timeoutInterval = 20
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) {
                    return "Unsubscribed from \(name)."
                }
                NSWorkspace.shared.open(url)
                return "\(name) didn’t confirm; their unsubscribe page is open in your browser."
            } catch {
                NSWorkspace.shared.open(url)
                return "Couldn’t reach \(name); their unsubscribe page is open in your browser."
            }
        case .mail(let address, let subject):
            do {
                guard let from = AppServices.shared.sender(forAccount: message.accountID) else { return "No account to send from." }
                let builder = MessageBuilder(from: from, to: [address], subject: subject, text: "unsubscribe")
                try await AppServices.shared.actions.send(builder, accountID: message.accountID, threadID: nil, draftID: nil)
                return "Sent an unsubscribe request to \(name)."
            } catch {
                return "Couldn’t send the unsubscribe request: \(AppServices.describe(error))"
            }
        case .page(let url):
            NSWorkspace.shared.open(url)
            return "\(name)’s unsubscribe page is open in your browser."
        case nil:
            return "\(name) doesn’t offer a way to unsubscribe."
        }
    }
}
