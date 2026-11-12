import Foundation
import Testing
@testable import DingoKit

/// Answers every request from a test-supplied handler, so the client never reaches the network.
/// The handler is global, so every test that uses it lives in the serialized `GmailClientTests`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: Data(text.utf8))
        }
    }

    struct Recorded: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data
    }

    typealias Handler = @Sendable (Recorded, Int) throws -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var log: [Recorded] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            log = []
        }
    }

    static var requests: [Recorded] { lock.withLock { log } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let recorded = Recorded(url: request.url!, method: request.httpMethod ?? "GET",
                                headers: request.allHTTPHeaderFields ?? [:], body: body)
        let (handler, index) = Self.lock.withLock { () -> (Handler?, Int) in
            Self.log.append(recorded)
            return (Self.handler, Self.log.count - 1)
        }
        do {
            guard let handler else { throw URLError(.notConnectedToInternet) }
            let response = try handler(recorded, index)
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

@Suite(.serialized) struct GmailClientTests {
    let refreshes = Counter()
    let sleeps = Counter()

    func client() -> GmailClient {
        let refreshes = refreshes
        let tokens = AccessTokenSource(refreshToken: "refresh-1", accessToken: GoogleAccessToken(value: "t1", expiresAt: .distantFuture)) { token in
            refreshes.record(token)
            return GoogleAccessToken(value: "t2", expiresAt: .distantFuture)
        }
        let sleeps = sleeps
        return GmailClient(account: "me@example.com", tokens: tokens, session: StubURLProtocol.session(),
                           retry: .init()) { duration in sleeps.record("\(duration.components.seconds)") }
    }

    @Test func listMessages() async throws {
        StubURLProtocol.install { _, _ in
            .json(#"{"messages":[{"id":"a","threadId":"ta"},{"id":"b","threadId":"tb"}],"nextPageToken":"p2","resultSizeEstimate":2}"#)
        }
        let page = try await client().listMessages(query: "from:a+b@x.com is:unread", labelIDs: ["INBOX", "UNREAD"], maxResults: 10)
        #expect(page.messages.map(\.id) == ["a", "b"])
        #expect(page.messages.first?.labelIDs == [])
        #expect(page.nextPageToken == "p2")
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=from%3Aa%2Bb%40x.com%20is%3Aunread&labelIds=INBOX&labelIds=UNREAD&maxResults=10")
        #expect(request.headers["Authorization"] == "Bearer t1")
    }

    @Test func batchRetriesFailedParts() async throws {
        StubURLProtocol.install { request, index in
            let text = String(decoding: request.body, as: UTF8.self)
            #expect(request.url.absoluteString == "https://gmail.googleapis.com/batch/gmail/v1")
            #expect(request.headers["Content-Type"]?.hasPrefix("multipart/mixed; boundary=") == true)
            if index == 0 {
                #expect(text.contains("GET /gmail/v1/users/me/messages/a?format=metadata&metadataHeaders=From&"))
                #expect(text.contains("metadataHeaders=X-GitHub-Reason"))
                let ids = Self.batchIDs(text)
                #expect(Set(ids) == ["a", "b", "c"])
                return Self.batchResponse(ids.enumerated().map { index, id in
                    switch id {
                    case "a": (index, "200 OK", #"{"id":"a","threadId":"ta","historyId":"5","labelIds":["INBOX"]}"#)
                    case "b": (index, "503 Service Unavailable", #"{"error":{"code":503,"message":"Backend Error"}}"#)
                    default: (index, "404 Not Found", #"{"error":{"code":404,"message":"Not Found"}}"#)
                    }
                })
            }
            #expect(Self.batchIDs(text) == ["b"])
            return Self.batchResponse([(0, "200 OK", #"{"id":"b","threadId":"tb","historyId":"6"}"#)])
        }
        let messages = try await client().messages(ids: ["a", "b", "c"], format: .metadata)
        #expect(messages.map(\.id) == ["a", "b"])
        #expect(messages.map(\.historyID) == [5, 6])
        #expect(StubURLProtocol.requests.count == 2)
        #expect(sleeps.all.count == 1)
    }

    @Test func batchParsingHandlesGmailFraming() {
        let body = "--batch_x\r\nContent-Type: application/http\r\nContent-ID: <response-item1>\r\n\r\nHTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\":{}}\r\n"
            + "--batch_x\r\nContent-Type: application/http\r\nContent-ID: <response-item0>\r\n\r\nHTTP/1.1 200 OK\r\nVary: Origin\r\n\r\n{\"id\":\"z\"}\r\n--batch_x--\r\n"
        let parsed = GmailClient.parseBatch(Data(body.utf8), boundary: "batch_x")
        #expect(parsed[0]?.status == 200)
        #expect(parsed[0].map { String(decoding: $0.body, as: UTF8.self) } == #"{"id":"z"}"#)
        #expect(parsed[1]?.status == 404)
    }

    @Test func unauthorizedRefreshesOnceAndRetries() async throws {
        StubURLProtocol.install { request, _ in
            request.headers["Authorization"] == "Bearer t2"
                ? .json(#"{"emailAddress":"me@example.com","messagesTotal":10,"threadsTotal":5,"historyId":"99"}"#)
                : .json(#"{"error":{"code":401,"message":"Invalid Credentials"}}"#, status: 401)
        }
        let profile = try await client().profile()
        #expect(profile.emailAddress == "me@example.com")
        #expect(profile.historyID == 99)
        #expect(refreshes.all == ["refresh-1"])
        #expect(StubURLProtocol.requests.map { $0.headers["Authorization"] } == ["Bearer t1", "Bearer t2"])
    }

    @Test func unauthorizedTwiceThrows() async throws {
        StubURLProtocol.install { _, _ in .json(#"{"error":{"code":401}}"#, status: 401) }
        await #expect(throws: GmailError.unauthorized) { try await client().listLabels() }
        #expect(StubURLProtocol.requests.count == 2)
    }

    @Test func rateLimitHonorsRetryAfter() async throws {
        StubURLProtocol.install { _, index in
            index == 0
                ? .json(#"{"error":{"code":429,"message":"Too many"}}"#, status: 429, headers: ["Retry-After": "7"])
                : .json(#"{"labels":[{"id":"INBOX","name":"INBOX","type":"system"},{"id":"Label_1","name":"Dingo/Receipts","type":"user"}]}"#)
        }
        let labels = try await client().listLabels()
        #expect(labels.map(\.name) == ["INBOX", "Dingo/Receipts"])
        #expect(sleeps.all == ["7"])
    }

    @Test func retryAfterTooLongThrowsRateLimited() async throws {
        StubURLProtocol.install { _, _ in .json("{}", status: 429, headers: ["Retry-After": "3600"]) }
        await #expect(throws: GmailError.rateLimited) { try await client().listLabels() }
        #expect(sleeps.all.isEmpty)
    }

    @Test func serverErrorsBackOffThenGiveUp() async throws {
        StubURLProtocol.install { _, _ in .json(#"{"error":{"code":500,"message":"Backend Error"}}"#, status: 500) }
        await #expect(throws: GmailError.http(status: 500, message: "Backend Error")) { try await client().listLabels() }
        #expect(StubURLProtocol.requests.count == 6)
        let delays = sleeps.all.compactMap(Int.init)
        #expect(delays.count == 5)
        #expect(delays.allSatisfy { $0 <= 32 })
    }

    @Test func historyNotFoundIsExpired() async throws {
        StubURLProtocol.install { _, _ in .json(#"{"error":{"code":404,"message":"Requested entity was not found."}}"#, status: 404) }
        await #expect(throws: GmailError.historyExpired) { try await client().history(startHistoryID: 123) }
        #expect(StubURLProtocol.requests.first?.url.query?.contains("startHistoryId=123") == true)
    }

    @Test func historyDecodes() async throws {
        StubURLProtocol.install { _, _ in
            .json("""
            {"history":[{"id":"124","messages":[{"id":"m","threadId":"t"}],
              "messagesAdded":[{"message":{"id":"m","threadId":"t","labelIds":["INBOX","UNREAD"]}}],
              "labelsRemoved":[{"message":{"id":"m","threadId":"t","labelIds":["INBOX"]},"labelIds":["UNREAD"]}]}],
             "historyId":"130"}
            """)
        }
        let history = try await client().history(startHistoryID: 123)
        #expect(history.historyID == 130)
        #expect(history.history.first?.messagesAdded.first?.message.labelIDs == ["INBOX", "UNREAD"])
        #expect(history.history.first?.labelsRemoved.first?.labelIDs == ["UNREAD"])
        #expect(history.history.first?.messagesDeleted.isEmpty == true)
    }

    @Test func sendUploadsRawMessage() async throws {
        StubURLProtocol.install { _, _ in .json(#"{"id":"sent","threadId":"t1","labelIds":["SENT"]}"#) }
        let raw = Data("From: me@example.com\r\nSubject: hi\r\n\r\nhello\r\n".utf8)
        let sent = try await client().send(raw: raw, threadID: "t1")
        #expect(sent.id == "sent")
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart")
        let boundary = try #require(MIMEHeaderValue(request.headers["Content-Type"] ?? "")["boundary"])
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.hasPrefix("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{\"threadId\":\"t1\"}\r\n"))
        #expect(body.contains("--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\nFrom: me@example.com\r\nSubject: hi\r\n\r\nhello\r\n\r\n--\(boundary)--\r\n"))
    }

    @Test func modifyAndAttachment() async throws {
        StubURLProtocol.install { request, _ in
            if request.url.path.hasSuffix("/attachments/att1") { return .json(#"{"size":5,"data":"aGVsbG8"}"#) }
            if request.url.path.hasSuffix("/labels") { return .json(#"{"error":{"code":409,"message":"Label name exists or conflicts"}}"#, status: 409) }
            return Response(status: 204)
        }
        let client = client()
        try await client.batchModify(ids: ["a", "b"], add: ["Label_1"], remove: ["INBOX"])
        let modify = try #require(StubURLProtocol.requests.last)
        let json = try #require(try JSONSerialization.jsonObject(with: modify.body) as? [String: [String]])
        #expect(json == ["ids": ["a", "b"], "addLabelIds": ["Label_1"], "removeLabelIds": ["INBOX"]])
        #expect(try await client.attachment(messageID: "m", attachmentID: "att1") == Data("hello".utf8))
        await #expect(throws: GmailError.alreadyExists) { try await client.createLabel(name: "Dingo/Receipts") }
    }

    typealias Response = StubURLProtocol.Response

    static func batchIDs(_ body: String) -> [String] {
        body.matches(of: #/GET /gmail/v1/users/me/messages/([^?]+)\?/#).map { String($0.output.1) }
    }

    static func batchResponse(_ parts: [(Int, String, String)]) -> Response {
        let boundary = "batch_ResponseBoundary"
        var body = ""
        for (index, status, json) in parts {
            body += "--\(boundary)\r\nContent-Type: application/http\r\nContent-ID: <response-item\(index)>\r\n\r\n"
            body += "HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(json)\r\n"
        }
        body += "--\(boundary)--\r\n"
        return Response(status: 200, headers: ["Content-Type": "multipart/mixed; boundary=\(boundary)"], body: Data(body.utf8))
    }
}
