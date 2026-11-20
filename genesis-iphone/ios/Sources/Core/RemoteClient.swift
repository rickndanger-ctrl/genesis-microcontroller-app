import Foundation
import Security
import CryptoKit

protocol ControllerCredentialVault {
    func token(for hostID: String) -> String?
    func save(_ token: String, for hostID: String) throws
    func remove(for hostID: String)
}

final class GenesisCredentials: ControllerCredentialVault {
    private let service: String
    init(service: String = "com.richardholguin.genesis-controller.hosts") { self.service = service }
    func token(for hostID: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: hostID,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func save(_ token: String, for hostID: String) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: hostID]
        let update: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = key; update.forEach { add[$0.key] = $0.value }
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CredentialError.unavailable }
        } else if status != errSecSuccess { throw CredentialError.unavailable }
    }
    func remove(for hostID: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: hostID]
        SecItemDelete(query as CFDictionary)
    }
    enum CredentialError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Could not securely save pairing. Unlock your phone and try again." }
    }
}

/// The certificates this device trusts for Macs it reaches over Wi-Fi, by
/// host and port. Each came from a QR code scanned off that Mac's screen.
/// Any connection to a listed address must present exactly that certificate;
/// other addresses (Tailscale) get the system's normal checks.
final class PinnedCertificates: @unchecked Sendable {
    static let shared = PinnedCertificates()
    private let lock = NSLock()
    private var pins: [String: String] = [:]
    private static func key(_ host: String, _ port: Int) -> String { host.lowercased() + ":" + String(port) }

    func remember(_ pin: String, for url: URL) {
        guard let host = url.host else { return }
        lock.lock(); pins[Self.key(host, url.port ?? 443)] = pin; lock.unlock()
    }
    func pin(host: String, port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pins[Self.key(host, port)]
    }

    static func fingerprint(_ certificateDER: Data) -> String {
        Data(SHA256.hash(data: certificateDER)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Answers a server-trust challenge for URLSession and WKWebView alike.
    static func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              let expected = shared.pin(host: space.host, port: space.port) else { return (.performDefaultHandling, nil) }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              fingerprint(SecCertificateCopyData(leaf) as Data) == expected else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Never forward the pairing token through an HTTP redirect, and hold Wi-Fi
/// connections to the certificate their Mac introduced in its QR code.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let answer = PinnedCertificates.evaluate(challenge); completionHandler(answer.0, answer.1)
    }
}

/// Which way to try a Mac first. After Wi-Fi fails and Tailscale works, the
/// client sticks with Tailscale for a minute, so a phone away from home does
/// not wait on Wi-Fi before every request.
final class RouteMemory: @unchecked Sendable {
    static let tailnetHold: TimeInterval = 60
    private let lock = NSLock()
    private var tailnetUntil: [String: Date] = [:]
    private var lastUsed: [String: RemoteHost.Route] = [:]
    func ordered(_ host: RemoteHost, now: Date = Date()) -> [(route: RemoteHost.Route, url: String)] {
        let all = host.routes
        lock.lock(); let hold = tailnetUntil[host.id]; lock.unlock()
        guard let hold, hold > now else { return all }
        return all.filter { $0.route == .tailnet } + all.filter { $0.route != .tailnet }
    }
    func worked(_ route: RemoteHost.Route, for host: RemoteHost, afterFailure: Bool, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastUsed[host.id] = route
        if route == .tailnet, afterFailure { tailnetUntil[host.id] = now.addingTimeInterval(Self.tailnetHold) }
        if route == .wifi { tailnetUntil[host.id] = nil }
    }
    func last(_ host: RemoteHost) -> RemoteHost.Route? { lock.lock(); defer { lock.unlock() }; return lastUsed[host.id] }
}

final class RemoteClient {
    private let session: URLSession
    let routes = RouteMemory()
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// A request on the way this Mac is best reached right now.
    func request(_ host: RemoteHost, token: String, path: String, query: [URLQueryItem] = [],
                 method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let first = routes.ordered(host).first else { throw RemoteError.invalidEndpoint }
        return try request(host, via: first, token: token, path: path, query: query, method: method, body: body)
    }
    private func request(_ host: RemoteHost, via route: (route: RemoteHost.Route, url: String), token: String, path: String,
                         query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        guard (body?.count ?? 0) <= 131_072 else { throw RemoteError.server(413, "This prompt is too long for the controller. Shorten it before sending.") }
        guard PairingPayload.validEndpoint(route.url, allowLocalhost: Self.localDevelopmentAllowed),
              var parts = URLComponents(string: route.url), path.hasPrefix("/v1/"), !path.contains("..") else {
            throw RemoteError.invalidEndpoint
        }
        if route.route == .wifi, let pin = host.pin, let url = parts.url { PinnedCertificates.shared.remember(pin, for: url) }
        parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw RemoteError.invalidEndpoint }
        var req = URLRequest(url: url)
        req.httpMethod = method; req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }
    static var localDevelopmentAllowed: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    func fetch<T: Decodable>(_ type: T.Type, host: RemoteHost, token: String, path: String,
                              query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                              deadline: TimeInterval? = nil) async throws -> T {
        let order = routes.ordered(host)
        guard !order.isEmpty else { throw RemoteError.invalidEndpoint }
        var data = Data(), response: URLResponse?
        for (index, route) in order.enumerated() {
            var req = try request(host, via: route, token: token, path: path, query: query, method: method, body: body)
            let fallback = index < order.count - 1
            // With Tailscale to fall back on, give up on Wi-Fi quickly.
            if fallback, route.route == .wifi { req.timeoutInterval = 4 }
            do {
                (data, response) = try await self.data(for: req, deadline: fallback && route.route == .wifi ? min(deadline ?? 4, 4) : deadline)
                routes.worked(route.route, for: host, afterFailure: index > 0)
                break
            } catch {
                // A task cancelled by the app also surfaces as .cancelled; never retry that.
                guard fallback, !Task.isCancelled, Self.shouldTryNextRoute(error, method: method) else { throw error }
            }
        }
        guard let response else { throw RemoteError.invalidResponse }
        guard let http = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw RemoteError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw RemoteError.server(http.statusCode, error?["error"] as? String ?? error?["message"] as? String ?? "Mac companion returned HTTP \(http.statusCode).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RemoteError.invalidResponse }
    }

    /// Whether a failure on one route means the request may go the other way.
    /// A request that changes something (a Send) is retried only when it
    /// certainly never reached the Mac; a read may also be retried after a timeout.
    static func shouldTryNextRoute(_ error: Error, method: String) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        let neverSent: Set<URLError.Code> = [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
                                             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                                             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .cancelled]
        if neverSent.contains(code) { return true }
        return method == "GET" && [.timedOut, .networkConnectionLost].contains(code)
    }

    private func data(for request: URLRequest, deadline: TimeInterval?) async throws -> (Data, URLResponse) {
        guard let deadline else { return try await session.data(for: request) }
        guard deadline.isFinite, deadline > 0, deadline <= 30 else { throw RemoteError.invalidResponse }
        // A receipt readback gets one wall-clock budget, not several full-length
        // requests. Cancelling URLSession's async child cancels its HTTP task.
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await self.session.data(for: request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}

struct LocalControllerSettings: Codable {
    var hosts: [RemoteHost] = []
    var selectedHostID: String = ""
    var selectedProvider: ProviderID = .claude
    var profiles: [String: RemoteProfile] = [:]
    var selectedChats: [String: ChatRecord] = [:]
    var chatHistory: [String: ControllerChatHistory]? = nil
    var ledger = DraftLedger()
}

final class ControllerPersistence {
    private let customDirectory: URL?
    init(directory: URL? = nil) { customDirectory = directory }
    private var directory: URL {
        customDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GenesisController", isDirectory: true)
    }
    func load() -> LocalControllerSettings {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("controller.json")),
              let settings = try? JSONDecoder().decode(LocalControllerSettings.self, from: data) else { return .init() }
        return settings
    }
    func save(_ settings: LocalControllerSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try data.write(to: directory.appendingPathComponent("controller.json"), options: [.atomic, .completeFileProtection])
    }
}
