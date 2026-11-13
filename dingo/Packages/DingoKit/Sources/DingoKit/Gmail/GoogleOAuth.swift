import CryptoKit
import Foundation
import Network
import Security

/// The app's Google OAuth client, from a "Desktop app" client in Google Cloud Console. Google
/// treats a desktop client's secret as non-confidential: it ships in the app, and PKCE is what
/// keeps an intercepted authorization code useless to anyone else.
public struct GoogleOAuthClient: Sendable, Equatable {
    public var id: String
    public var secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }
}

public enum GoogleOAuthError: Error, Equatable, Sendable {
    /// The user declined, or unticked Gmail access on the consent screen.
    case denied
    case cancelled
    /// Nobody finished signing in in the browser before the timeout.
    case timedOut
    case network
    case misconfigured(String)
    /// Google no longer honors the refresh token (revoked, expired, or the password changed). Sign in again.
    case invalidGrant
}

/// An access token and when Google says it stops working.
public struct GoogleAccessToken: Sendable, Equatable {
    public var value: String
    public var expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

/// A finished sign-in: the account, the long-lived refresh token for the Keychain, and a first access token.
public struct GoogleSignIn: Sendable, Equatable {
    public var emailAddress: String
    public var refreshToken: String
    public var accessToken: GoogleAccessToken
}

/// Google's installed-app OAuth flow: Dingo listens on a loopback port, opens Google's consent page
/// in the browser, and Google redirects the browser back to that port with a code that Dingo
/// exchanges for tokens. PKCE (S256) binds the code to this sign-in, and `state` ties the redirect
/// to the page Dingo opened, so another local process can't feed it a code.
public struct GoogleOAuth: Sendable {
    public static let scope = "https://www.googleapis.com/auth/gmail.modify"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let profileEndpoint = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!

    private let client: GoogleOAuthClient
    private let session: URLSession
    private let open: @Sendable (URL) -> Void

    /// `open` shows the consent page; the app passes `NSWorkspace.shared.open`.
    public init(client: GoogleOAuthClient, session: URLSession = .shared, open: @escaping @Sendable (URL) -> Void) {
        self.client = client
        self.session = session
        self.open = open
    }

    /// Runs the whole browser sign-in. `loginHint` preselects an account when signing in again.
    /// The loopback listener closes when this returns, throws, times out, or is cancelled.
    public func signIn(loginHint: String? = nil, timeout: Duration = .seconds(300)) async throws -> GoogleSignIn {
        let verifier = Self.randomToken(bytes: 32)
        let state = Self.randomToken(bytes: 16)
        let server = LoopbackServer(state: state)
        defer { server.stop() }
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        open(authorizationURL(redirectURI: redirectURI, state: state, challenge: Self.challenge(for: verifier), loginHint: loginHint))

        let code: String
        switch try await server.callback(timeout: timeout) {
        case .code(let value): code = value
        case .denied: throw GoogleOAuthError.denied
        case .error(let error): throw GoogleOAuthError.misconfigured(error)
        }
        let tokens = try await token([
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": redirectURI,
        ])
        // Granular consent lets people untick Gmail access and still finish; without it nothing works.
        if let scope = tokens.scope, !scope.split(separator: " ").contains(Substring(Self.scope)) {
            throw GoogleOAuthError.denied
        }
        guard let refreshToken = tokens.refreshToken else {
            throw GoogleOAuthError.misconfigured("Google didn't return a refresh token.")
        }
        let accessToken = tokens.accessToken
        return GoogleSignIn(emailAddress: try await emailAddress(accessToken: accessToken.value),
                            refreshToken: refreshToken, accessToken: accessToken)
    }

    /// A fresh access token for a stored refresh token.
    public func refresh(refreshToken: String) async throws -> GoogleAccessToken {
        try await token(["grant_type": "refresh_token", "refresh_token": refreshToken]).accessToken
    }

    /// The signed-in Gmail address, which names the account in Dingo and the Keychain.
    public func emailAddress(accessToken: String) async throws -> String {
        var request = URLRequest(url: Self.profileEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await load(request)
        guard status == 200, let profile = try? JSONDecoder().decode(GmailAPI.Profile.self, from: data) else {
            throw status == 401 ? GoogleOAuthError.invalidGrant : GoogleOAuthError.misconfigured("Couldn't read the Gmail profile (HTTP \(status)).")
        }
        return profile.emailAddress
    }

    func authorizationURL(redirectURI: String, state: String, challenge: String, loginHint: String?) -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Offline access and a forced consent screen make Google return a refresh token every time.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64URLEncodedString()
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        let value: String
        let expiresIn: Int?
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case value = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token", scope
        }

        var accessToken: GoogleAccessToken {
            GoogleAccessToken(value: value, expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600)))
        }
    }

    private struct ErrorBody: Decodable {
        let error: String
        let errorDescription: String?
        enum CodingKeys: String, CodingKey { case error, errorDescription = "error_description" }
    }

    private func token(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let fields = form.merging(["client_id": client.id, "client_secret": client.secret]) { value, _ in value }
        request.httpBody = Data(Self.formEncode(fields).utf8)
        let (data, status) = try await load(request)
        if status == 200, let body = try? JSONDecoder().decode(TokenResponse.self, from: data) { return body }
        switch try? JSONDecoder().decode(ErrorBody.self, from: data) {
        case let body? where body.error == "invalid_grant": throw GoogleOAuthError.invalidGrant
        case let body?: throw GoogleOAuthError.misconfigured(body.errorDescription ?? body.error)
        case nil: throw status >= 500 ? GoogleOAuthError.network : GoogleOAuthError.misconfigured("Token request failed (HTTP \(status)).")
        }
    }

    private func load(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw GoogleOAuthError.cancelled }
            throw GoogleOAuthError.network
        }
    }

    static func formEncode(_ fields: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
        }.joined(separator: "&")
    }
}

/// Keeps one account's access token fresh. Holds the refresh token and the cached access token,
/// refreshes shortly before expiry, and shares one refresh among concurrent callers so a burst
/// of requests after a 401 costs one round trip to Google.
public actor AccessTokenSource {
    public typealias Refresh = @Sendable (_ refreshToken: String) async throws -> GoogleAccessToken

    public nonisolated let refreshToken: String
    private let refresh: Refresh
    private var current: GoogleAccessToken?
    private var inFlight: Task<GoogleAccessToken, any Error>?

    public init(refreshToken: String, accessToken: GoogleAccessToken? = nil, refresh: @escaping Refresh) {
        self.refreshToken = refreshToken
        self.current = accessToken
        self.refresh = refresh
    }

    public init(refreshToken: String, accessToken: GoogleAccessToken? = nil, oauth: GoogleOAuth) {
        self.init(refreshToken: refreshToken, accessToken: accessToken) { try await oauth.refresh(refreshToken: $0) }
    }

    /// A token good for at least another minute.
    public func token() async throws -> String {
        if let current, current.expiresAt.timeIntervalSinceNow > 60 { return current.value }
        return try await refreshNow().value
    }

    /// A new token after Gmail rejected `rejected`. Skips the refresh when another request already replaced it.
    public func token(replacing rejected: String) async throws -> String {
        if inFlight == nil, let current, current.value != rejected, current.expiresAt.timeIntervalSinceNow > 60 {
            return current.value
        }
        return try await refreshNow().value
    }

    private func refreshNow() async throws -> GoogleAccessToken {
        if let inFlight { return try await inFlight.value }
        let task = Task { [refresh, refreshToken] in try await refresh(refreshToken) }
        inFlight = task
        defer { inFlight = nil }
        let token = try await task.value
        current = token
        return token
    }
}

/// The loopback HTTP listener that catches Google's redirect. It answers exactly one request that
/// carries the expected `state`, with a page telling the person to close the tab; anything else
/// (a favicon fetch, a stray request) gets a 404 and the listener keeps waiting.
final class LoopbackServer: @unchecked Sendable {
    enum Callback: Sendable, Equatable { case code(String), denied, error(String) }

    private let state: String
    private let queue = DispatchQueue(label: "dingo.oauth.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var outcome: Result<Callback, GoogleOAuthError>?
    private var waiter: CheckedContinuation<Callback, any Error>?

    init(state: String) { self.state = state }

    /// Starts listening on 127.0.0.1 and returns the port the system picked.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw GoogleOAuthError.network }
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let started = OneShot<UInt16>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                started.install(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue { started.resume(.success(port)) }
                    case .failed, .cancelled:
                        started.resume(.failure(GoogleOAuthError.network))
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            started.resume(.failure(GoogleOAuthError.cancelled))
            listener.cancel()
        }
    }

    /// Waits for the redirect. Throws `.timedOut` after `timeout` and `.cancelled` if the task is cancelled.
    func callback(timeout: Duration) async throws -> Callback {
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(.timedOut))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Callback, GoogleOAuthError>? = lock.withLock {
                    if outcome == nil { waiter = continuation }
                    return outcome
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            finish(.failure(.cancelled))
        }
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
    }

    private func finish(_ result: Result<Callback, GoogleOAuthError>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Callback, any Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
        stop()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let self else { return connection.cancel() }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let words = requestLine.split(separator: " ")
        let query = words.count >= 2 ? URLComponents(string: "http://127.0.0.1" + words[1])?.queryItems ?? [] : []
        func item(_ name: String) -> String? { query.first { $0.name == name }?.value }

        guard words.first == "GET", item("state") == state, item("code") != nil || item("error") != nil else {
            send(status: "404 Not Found", page: Self.page("Nothing here."), on: connection)
            return
        }
        let callback: Callback = if let code = item("code") {
            .code(code)
        } else if item("error") == "access_denied" {
            .denied
        } else {
            .error(item("error") ?? "unknown_error")
        }
        let message = callback == .denied ? "Sign-in was cancelled." : "Dingo has your sign-in."
        send(status: "200 OK", page: Self.page("\(message) You can close this tab."), on: connection)
        finish(.success(callback))
    }

    private func send(status: String, page: String, on connection: NWConnection) {
        let body = Data(page.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(_ message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Dingo</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:90vh;margin:0}</style>
        </head><body><p>\(message)</p></body></html>
        """
    }
}

/// A continuation that resumes once, whichever of several callbacks gets there first.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var early: Result<Value, any Error>?
    private var done = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let early = lock.withLock { () -> Result<Value, any Error>? in
            if self.early == nil { self.continuation = continuation }
            return self.early
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(_ result: Result<Value, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            guard !done else { return nil }
            done = true
            if self.continuation == nil { early = result }
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
