import Foundation
import Testing
@testable import DingoKit

/// OAuth tests that use the global URL stub run inside the serialized client suite.
extension GmailClientTests {
    static let oauthClient = GoogleOAuthClient(id: "client-id.apps.googleusercontent.com", secret: "not-so-secret")

    /// A plain session for talking to the loopback listener the way a browser would.
    static func browserGet(_ url: URL) async throws -> (Int, String) {
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test func signInThroughLoopback() async throws {
        let verifierSeen = Counter()
        StubURLProtocol.install { request, _ in
            if request.url.host == "oauth2.googleapis.com" {
                let form = Dictionary(uniqueKeysWithValues: String(decoding: request.body, as: UTF8.self).split(separator: "&").map { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                    return (parts[0], parts.count > 1 ? parts[1] : "")
                })
                #expect(form["grant_type"] == "authorization_code")
                #expect(form["code"] == "4/0AbCode")
                #expect(form["client_secret"] == "not-so-secret")
                #expect(form["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
                verifierSeen.record(form["code_verifier"] ?? "")
                return .json(#"{"access_token":"ya29.a","expires_in":3599,"refresh_token":"1//refresh","scope":"https://www.googleapis.com/auth/gmail.modify","token_type":"Bearer"}"#)
            }
            #expect(request.url.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/profile")
            #expect(request.headers["Authorization"] == "Bearer ya29.a")
            return .json(#"{"emailAddress":"ada@example.com","messagesTotal":1,"threadsTotal":1,"historyId":"1"}"#)
        }

        let pages = Counter()
        let challenges = Counter()
        let redirects = Counter()
        let oauth = GoogleOAuth(client: Self.oauthClient, session: StubURLProtocol.session()) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func item(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            #expect(url.host == "accounts.google.com")
            #expect(item("code_challenge_method") == "S256")
            #expect(item("scope") == GoogleOAuth.scope)
            #expect(item("access_type") == "offline")
            #expect(item("login_hint") == "ada@example.com")
            challenges.record(item("code_challenge"))
            let redirect = item("redirect_uri")
            redirects.record(redirect)
            Task {
                // A favicon request and a forged state are ignored; the real redirect finishes.
                do {
                    let favicon = try await Self.browserGet(URL(string: "\(redirect)/favicon.ico")!)
                    pages.record("\(favicon.0)")
                    let forged = try await Self.browserGet(URL(string: "\(redirect)/?state=wrong&code=evil")!)
                    pages.record("\(forged.0)")
                    let real = try await Self.browserGet(URL(string: "\(redirect)/?state=\(item("state"))&code=4/0AbCode&scope=x")!)
                    pages.record("\(real.0) \(real.1.contains("You can close this tab."))")
                } catch {
                    pages.record("\(error)")
                }
            }
        }

        let signIn = try await oauth.signIn(loginHint: "ada@example.com", timeout: .seconds(10))
        #expect(signIn.emailAddress == "ada@example.com")
        #expect(signIn.refreshToken == "1//refresh")
        #expect(signIn.accessToken.value == "ya29.a")
        #expect(signIn.accessToken.expiresAt.timeIntervalSinceNow > 3000)
        let verifier = try #require(verifierSeen.all.first)
        #expect(GoogleOAuth.challenge(for: verifier) == challenges.all.first)
        try await Task.sleep(for: .milliseconds(100))
        #expect(pages.all == ["404", "404", "200 true"])
        await Self.expectClosed(redirects.all.first ?? "")
    }

    @Test func signInDenied() async throws {
        StubURLProtocol.install { _, _ in .json("{}", status: 500) }
        let oauth = GoogleOAuth(client: Self.oauthClient, session: StubURLProtocol.session()) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            Task { _ = try? await Self.browserGet(URL(string: "\(redirect)/?error=access_denied&state=\(state)")!) }
        }
        await #expect(throws: GoogleOAuthError.denied) { try await oauth.signIn(timeout: .seconds(10)) }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func signInTimesOutAndClosesListener() async throws {
        let redirects = Counter()
        let oauth = GoogleOAuth(client: Self.oauthClient, session: StubURLProtocol.session()) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            redirects.record(items.first { $0.name == "redirect_uri" }?.value ?? "")
        }
        await #expect(throws: GoogleOAuthError.timedOut) { try await oauth.signIn(timeout: .milliseconds(200)) }
        let redirect = try #require(redirects.all.first)
        await Self.expectClosed(redirect)
    }

    @Test func signInCancelsAndClosesListener() async throws {
        let redirects = Counter()
        let oauth = GoogleOAuth(client: Self.oauthClient, session: StubURLProtocol.session()) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            redirects.record(items.first { $0.name == "redirect_uri" }?.value ?? "")
        }
        let task = Task { try await oauth.signIn(timeout: .seconds(30)) }
        while redirects.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        await #expect(throws: GoogleOAuthError.cancelled) { try await task.value }
        let redirect = try #require(redirects.all.first)
        await Self.expectClosed(redirect)
    }

    @Test func refreshMapsInvalidGrant() async throws {
        StubURLProtocol.install { request, _ in
            let form = String(decoding: request.body, as: UTF8.self)
            return form.contains("refresh_token=good")
                ? .json(#"{"access_token":"ya29.new","expires_in":3600}"#)
                : .json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400)
        }
        let oauth = GoogleOAuth(client: Self.oauthClient, session: StubURLProtocol.session()) { _ in }
        #expect(try await oauth.refresh(refreshToken: "good").value == "ya29.new")
        await #expect(throws: GoogleOAuthError.invalidGrant) { try await oauth.refresh(refreshToken: "revoked") }
    }

    @Test func accessTokenSourceSharesOneRefresh() async throws {
        let refreshes = Counter()
        let source = AccessTokenSource(refreshToken: "r") { _ in
            refreshes.record("refresh")
            try await Task.sleep(for: .milliseconds(50))
            return GoogleAccessToken(value: "fresh", expiresAt: Date().addingTimeInterval(3600))
        }
        async let first = source.token()
        async let second = source.token()
        #expect(try await [first, second] == ["fresh", "fresh"])
        #expect(try await source.token(replacing: "stale") == "fresh")
        #expect(refreshes.all.count == 1)
        _ = try await source.token(replacing: "fresh")
        #expect(refreshes.all.count == 2)
    }

    static func expectClosed(_ redirect: String) async {
        let url = URL(string: "\(redirect)/?state=x&code=y")!
        await #expect(throws: (any Error).self) { _ = try await browserGet(url) }
    }
}
