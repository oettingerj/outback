import Foundation

public enum GmailError: Error, Equatable, Sendable {
    /// The start history ID is older than Gmail keeps (about a week). Resync from a full listing.
    case historyExpired
    /// Gmail rejected the token even after a refresh.
    case unauthorized
    case notFound
    /// A label with that name exists already.
    case alreadyExists
    /// Still rate limited after backing off, or told to wait longer than is worth holding a request open.
    case rateLimited
    case http(status: Int, message: String?)
    case invalidResponse(String)
}

/// One Gmail account's REST client. The access token comes from `AccessTokenSource` per request
/// and goes only to gmail.googleapis.com. A 401 refreshes the token and retries once; 429s, 5xx
/// errors, and Gmail's per-user rate-limit 403s back off exponentially with jitter, honoring
/// Retry-After, a bounded number of times.
public actor GmailClient {
    public enum Format: String, Sendable { case full, metadata, minimal }

    /// The headers requested for `metadata` fetches: what the list, threading, and the bucket classifier read.
    public static let metadataHeaders = [
        "From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To", "References",
        "List-Unsubscribe", "List-Unsubscribe-Post", "List-Id", "Precedence", "Auto-Submitted", "Reply-To",
        "Content-Type", "X-GitHub-Reason", "X-GitHub-Sender",
    ]

    /// Gmail allows 100 calls per batch but recommends 50: larger batches trip per-user rate limits.
    static let batchLimit = 50
    /// `messages.batchModify` takes at most 1,000 IDs.
    static let modifyLimit = 1000

    struct RetryPolicy: Sendable {
        var maxRetries = 5
        var baseDelay: Duration = .seconds(1)
        var maxDelay: Duration = .seconds(32)
        /// A longer Retry-After throws `rateLimited` instead of holding the request open.
        var maxRetryAfter: Duration = .seconds(60)
    }

    public nonisolated let account: String
    private let tokens: AccessTokenSource
    private let session: URLSession
    private let retry: RetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void

    private static let host = "https://gmail.googleapis.com"

    public init(account: String, tokens: AccessTokenSource, session: URLSession = .shared) {
        self.init(account: account, tokens: tokens, session: session, retry: RetryPolicy()) { try await Task.sleep(for: $0) }
    }

    init(account: String, tokens: AccessTokenSource, session: URLSession, retry: RetryPolicy,
         sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.account = account
        self.tokens = tokens
        self.session = session
        self.retry = retry
        self.sleep = sleep
    }

    // MARK: Account and labels

    public func profile() async throws -> GmailAPI.Profile {
        try await json(request("GET", "profile"))
    }

    public func listLabels() async throws -> [GmailAPI.Label] {
        let response: GmailAPI.ListLabelsResponse = try await json(request("GET", "labels"))
        return response.labels ?? []
    }

    /// Creates a label shown in the label list and on messages, as Dingo's bucket labels are.
    public func createLabel(name: String) async throws -> GmailAPI.Label {
        try await json(request("POST", "labels", body: [
            "name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show",
        ]))
    }

    // MARK: Messages

    /// One page of message IDs. `query` is Gmail search syntax; `labelIDs` must all match.
    public func listMessages(query: String? = nil, labelIDs: [String] = [], pageToken: String? = nil,
                             maxResults: Int? = nil) async throws -> GmailAPI.ListMessagesResponse {
        var items: [URLQueryItem] = []
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        items += labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        if let maxResults { items.append(URLQueryItem(name: "maxResults", value: String(maxResults))) }
        return try await json(request("GET", "messages", query: items))
    }

    public func message(id: String, format: Format = .full) async throws -> GmailAPI.Message {
        try await json(request("GET", "messages/\(Self.escape(id))", query: Self.formatQuery(format)))
    }

    /// Many messages through the batch endpoint, 50 per request. Parts that hit a rate limit or a
    /// server error are retried with backoff. Messages deleted since they were listed (404) are left
    /// out, so the result can be shorter than `ids`; it keeps their order otherwise.
    public func messages(ids: [String], format: Format = .full) async throws -> [GmailAPI.Message] {
        var found: [String: GmailAPI.Message] = [:]
        let decoder = JSONDecoder()
        for start in stride(from: 0, to: ids.count, by: Self.batchLimit) {
            var pending = Array(Set(ids[start..<min(start + Self.batchLimit, ids.count)]))
            var attempt = 0
            while !pending.isEmpty {
                let paths = pending.map { "/gmail/v1/users/me/messages/\(Self.escape($0))?\(Self.queryString(Self.formatQuery(format)))" }
                let responses = try await batch(paths)
                var failed: [String] = []
                var lastFailure: (status: Int, body: Data) = (0, Data())
                for (index, id) in pending.enumerated() {
                    guard let response = responses[index] else {
                        failed.append(id)
                        continue
                    }
                    switch response.status {
                    case 200..<300:
                        do { found[id] = try decoder.decode(GmailAPI.Message.self, from: response.body) }
                        catch { throw GmailError.invalidResponse("Message \(id): \(error)") }
                    case 404:
                        continue
                    case let status where Self.isRetryable(status, body: response.body):
                        failed.append(id)
                        lastFailure = response
                    default:
                        throw Self.error(status: response.status, body: response.body)
                    }
                }
                guard !failed.isEmpty else { break }
                guard attempt < retry.maxRetries else { throw Self.error(status: lastFailure.status, body: lastFailure.body) }
                try await sleep(backoff(attempt))
                attempt += 1
                pending = failed
            }
        }
        return ids.compactMap { found[$0] }
    }

    public func thread(id: String, format: Format = .full) async throws -> GmailAPI.Thread {
        try await json(request("GET", "threads/\(Self.escape(id))", query: Self.formatQuery(format)))
    }

    /// Changes since `startHistoryID`. Throws `historyExpired` when Gmail no longer has that point.
    public func history(startHistoryID: UInt64, pageToken: String? = nil) async throws -> GmailAPI.ListHistoryResponse {
        var items = [URLQueryItem(name: "startHistoryId", value: String(startHistoryID)), URLQueryItem(name: "maxResults", value: "500")]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        do {
            return try await json(request("GET", "history", query: items))
        } catch GmailError.notFound {
            throw GmailError.historyExpired
        }
    }

    // MARK: Labels on messages and threads

    /// Adds and removes labels on many messages, 1,000 per request.
    public func batchModify(ids: [String], add: [String] = [], remove: [String] = []) async throws {
        for start in stride(from: 0, to: ids.count, by: Self.modifyLimit) {
            let chunk = Array(ids[start..<min(start + Self.modifyLimit, ids.count)])
            _ = try await perform(request("POST", "messages/batchModify", body: [
                "ids": chunk, "addLabelIds": add, "removeLabelIds": remove,
            ]))
        }
    }

    public func modifyThread(id: String, add: [String] = [], remove: [String] = []) async throws {
        _ = try await perform(request("POST", "threads/\(Self.escape(id))/modify", body: ["addLabelIds": add, "removeLabelIds": remove]))
    }

    public func trashMessage(id: String) async throws {
        _ = try await perform(request("POST", "messages/\(Self.escape(id))/trash"))
    }

    public func untrashMessage(id: String) async throws {
        _ = try await perform(request("POST", "messages/\(Self.escape(id))/untrash"))
    }

    public func trashThread(id: String) async throws {
        _ = try await perform(request("POST", "threads/\(Self.escape(id))/trash"))
    }

    public func untrashThread(id: String) async throws {
        _ = try await perform(request("POST", "threads/\(Self.escape(id))/untrash"))
    }

    // MARK: Sending and drafts

    /// Sends an RFC 5322 message (`MessageBuilder.build()`). `threadID` files it in an existing
    /// conversation; the message's In-Reply-To, References, and subject must match it too.
    /// Goes through the upload endpoint, which takes messages up to Gmail's 35 MB limit.
    public func send(raw: Data, threadID: String? = nil) async throws -> GmailAPI.Message {
        try await json(upload("POST", "messages/send", metadata: threadID.map { ["threadId": $0] } ?? [:], raw: raw))
    }

    public func createDraft(raw: Data, threadID: String? = nil) async throws -> GmailAPI.Draft {
        try await json(upload("POST", "drafts", metadata: ["message": threadID.map { ["threadId": $0] } ?? [:]], raw: raw))
    }

    public func updateDraft(id: String, raw: Data, threadID: String? = nil) async throws -> GmailAPI.Draft {
        try await json(upload("PUT", "drafts/\(Self.escape(id))",
                              metadata: ["id": id, "message": threadID.map { ["threadId": $0] } ?? [:]], raw: raw))
    }

    public func deleteDraft(id: String) async throws {
        _ = try await perform(request("DELETE", "drafts/\(Self.escape(id))"))
    }

    public func sendDraft(id: String) async throws -> GmailAPI.Message {
        try await json(request("POST", "drafts/send", body: ["id": id]))
    }

    /// An attachment's bytes, by the `attachmentID` in the message's part.
    public func attachment(messageID: String, attachmentID: String) async throws -> Data {
        let body: GmailAPI.MessagePartBody = try await json(
            request("GET", "messages/\(Self.escape(messageID))/attachments/\(Self.escape(attachmentID))"))
        guard let data = body.decodedData else { throw GmailError.invalidResponse("Attachment has no data") }
        return data
    }

    // MARK: Requests

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        var url = "\(Self.host)/gmail/v1/users/me/\(path)"
        if !query.isEmpty { url += "?" + Self.queryString(query) }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// A multipart upload: JSON metadata, then the raw message as message/rfc822.
    private func upload(_ method: String, _ path: String, metadata: [String: Any], raw: Data) throws -> URLRequest {
        let boundary = "dingo-upload-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += try JSONSerialization.data(withJSONObject: metadata)
        body += Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8)
        body += raw
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: URL(string: "\(Self.host)/upload/gmail/v1/users/me/\(path)?uploadType=multipart")!)
        request.httpMethod = method
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func json<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await perform(request)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GmailError.invalidResponse("\(T.self): \(error)") }
    }

    /// Sends with the current token, refreshing once on a 401 and backing off on retryable failures.
    private func perform(_ base: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var token = try await tokens.token()
        var refreshed = false
        var attempt = 0
        while true {
            var request = base
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GmailError.invalidResponse("Not an HTTP response") }
            let status = http.statusCode
            if (200..<300).contains(status) { return (data, http) }
            if status == 401 {
                guard !refreshed else { throw GmailError.unauthorized }
                token = try await tokens.token(replacing: token)
                refreshed = true
                continue
            }
            guard Self.isRetryable(status, body: data), attempt < retry.maxRetries else {
                throw Self.error(status: status, body: data)
            }
            let delay: Duration
            if let header = http.value(forHTTPHeaderField: "Retry-After"), let wait = Self.retryAfter(header) {
                guard wait <= retry.maxRetryAfter else { throw GmailError.rateLimited }
                delay = wait
            } else {
                delay = backoff(attempt)
            }
            try await sleep(delay)
            attempt += 1
        }
    }

    /// Full exponential backoff with jitter: 1, 2, 4… seconds capped at 32, each scaled by 0.5–1.
    private func backoff(_ attempt: Int) -> Duration {
        let exponential = retry.baseDelay * (1 << min(attempt, 20))
        return min(exponential, retry.maxDelay) * Double.random(in: 0.5...1)
    }

    static func isRetryable(_ status: Int, body: Data) -> Bool {
        switch status {
        case 429, 500, 502, 503, 504: true
        case 403: ["rateLimitExceeded", "userRateLimitExceeded"].contains(APIErrorBody.parse(body)?.reason)
        default: false
        }
    }

    static func error(status: Int, body: Data) -> GmailError {
        switch status {
        case 401: .unauthorized
        case 404: .notFound
        case 409: .alreadyExists
        case 429: .rateLimited
        case 403 where isRetryable(status, body: body): .rateLimited
        default: .http(status: status, message: APIErrorBody.parse(body)?.message)
        }
    }

    /// Retry-After as seconds or an HTTP date.
    static func retryAfter(_ header: String) -> Duration? {
        let value = header.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(value) { return .seconds(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, date.timeIntervalSinceNow))
    }

    private struct APIErrorBody: Decodable {
        struct Detail: Decodable {
            var code: Int?
            var message: String?
            var errors: [Item]?
        }
        struct Item: Decodable { var reason: String? }
        var error: Detail

        static func parse(_ data: Data) -> (message: String?, reason: String?)? {
            guard let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) else { return nil }
            return (body.error.message, body.error.errors?.first?.reason)
        }
    }

    private static func formatQuery(_ format: Format) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata { items += metadataHeaders.map { URLQueryItem(name: "metadataHeaders", value: $0) } }
        return items
    }

    /// Percent-encodes query items strictly; URLComponents leaves "+" alone, which Google reads as a space.
    static func queryString(_ items: [URLQueryItem]) -> String {
        items.map { "\(escape($0.name))=\(escape($0.value ?? ""))" }.joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    // MARK: Batch

    /// Runs GET requests through the batch endpoint and returns each part's status and body by index.
    private func batch(_ paths: [String]) async throws -> [Int: (status: Int, body: Data)] {
        let boundary = "dingo-batch-\(UUID().uuidString)"
        var body = ""
        for (index, path) in paths.enumerated() {
            body += "--\(boundary)\r\nContent-Type: application/http\r\nContent-ID: <item\(index)>\r\n\r\nGET \(path) HTTP/1.1\r\n\r\n"
        }
        body += "--\(boundary)--\r\n"
        var request = URLRequest(url: URL(string: "\(Self.host)/batch/gmail/v1")!)
        request.httpMethod = "POST"
        request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await perform(request)
        guard let responseBoundary = MIMEHeaderValue(response.value(forHTTPHeaderField: "Content-Type") ?? "")["boundary"] else {
            throw GmailError.invalidResponse("Batch response has no boundary")
        }
        return Self.parseBatch(data, boundary: responseBoundary)
    }

    /// Splits a multipart/mixed batch response into its embedded HTTP responses. Each part's
    /// Content-ID ("<response-item3>") names the request it answers; parts without one count in order.
    static func parseBatch(_ data: Data, boundary: String) -> [Int: (status: Int, body: Data)] {
        let text = String(decoding: data, as: UTF8.self)
        var result: [Int: (status: Int, body: Data)] = [:]
        for (position, chunk) in text.components(separatedBy: "--\(boundary)").dropFirst().enumerated() {
            if chunk.hasPrefix("--") { break }
            guard let (outerHeaders, inner) = splitHead(chunk), let (innerHead, innerBody) = splitHead(inner) else { continue }
            let statusLine = innerHead.components(separatedBy: "\n").first ?? ""
            guard let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { continue }
            let contentID = outerHeaders.components(separatedBy: "\n")
                .first { $0.lowercased().hasPrefix("content-id:") }
                .flatMap { line in Int(line.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }.reversed().map(String.init).joined()) }
            let body = innerBody.trimmingCharacters(in: .whitespacesAndNewlines)
            result[contentID ?? position] = (status, Data(body.utf8))
        }
        return result
    }

    /// Splits at the first blank line into headers and the rest, tolerating bare LF line endings.
    private static func splitHead(_ text: String) -> (String, String)? {
        let trimmed = text.drop { $0.isNewline || $0 == " " }
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = trimmed.range(of: separator) {
                return (String(trimmed[..<range.lowerBound]), String(trimmed[range.upperBound...]))
            }
        }
        return nil
    }
}
