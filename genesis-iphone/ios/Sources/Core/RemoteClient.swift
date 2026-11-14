import Foundation
import Security

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

/// Never forward the pairing token through an HTTP redirect.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class RemoteClient {
    private let session: URLSession
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    func request(_ host: RemoteHost, token: String, path: String, query: [URLQueryItem] = [],
                 method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard (body?.count ?? 0) <= 131_072 else { throw RemoteError.server(413, "This prompt is too long for the controller. Shorten it before sending.") }
        guard PairingPayload.validEndpoint(host.baseURL, allowLocalhost: Self.localDevelopmentAllowed),
              var parts = URLComponents(string: host.baseURL), path.hasPrefix("/v1/"), !path.contains("..") else {
            throw RemoteError.invalidEndpoint
        }
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
        let req = try request(host, token: token, path: path, query: query, method: method, body: body)
        let (data, response) = try await data(for: req, deadline: deadline)
        guard let http = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw RemoteError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw RemoteError.server(http.statusCode, error?["error"] as? String ?? error?["message"] as? String ?? "Mac companion returned HTTP \(http.statusCode).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RemoteError.invalidResponse }
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
