import Foundation
import Security

/// Checks the Wi-Fi listener end to end on this Mac: its certificate, which
/// addresses it admits, TLS with a pinned fingerprint, and that its requests
/// are marked as coming from the network. Uses a scratch folder and port.
@main struct WiFiPairingTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL", what) } }

    final class Pinning: NSObject, URLSessionTaskDelegate {
        let pin: String
        init(pin: String) { self.pin = pin }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  WiFiIdentity.fingerprint(of: SecCertificateCopyData(leaf) as Data) == pin else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    @MainActor static func main() async throws {
        // Which callers the Wi-Fi listener lets in.
        for host in ["192.168.1.20", "10.0.0.5", "172.20.1.1", "169.254.3.4", "100.101.102.103", "127.0.0.1",
                     "fe80::1%en0", "fd7a:115c:a1e0::1", "::1", "::ffff:192.168.0.9"] {
            check(WiFiIdentity.isPrivate(host), "private \(host)")
        }
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2001:4860::8888", "::ffff:8.8.8.8", "example.com", ""] {
            check(!WiFiIdentity.isPrivate(host), "public \(host)")
        }

        // The certificate is made once and kept; loading it again gives the same fingerprint.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("amc-wifi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try WiFiIdentity.loadOrCreate(in: folder)
        let again = try WiFiIdentity.loadOrCreate(in: folder)
        check(first.fingerprint == again.fingerprint, "fingerprint survives a reload")
        check(first.fingerprint.count == 43, "fingerprint is base64url SHA-256")
        let mode = (try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("wifi-identity.json").path)[.posixPermissions] as? NSNumber)?.intValue
        check(mode == 0o600, "certificate file readable by this user only")
        let other = try WiFiIdentity.loadOrCreate(in: folder.appendingPathComponent("x", isDirectory: true).creatingDirectory())
        check(other.fingerprint != first.fingerprint, "each Mac gets its own certificate")

        // TLS round trip on a scratch port.
        var sawNetwork: Bool?
        let server = RemoteHTTPServer(port: 18799, tls: first.identity, admits: WiFiIdentity.isPrivate) { request in
            sawNetwork = request.viaNetwork
            return .json(["ok": true])
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        func get(pin: String) async -> Int? {
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 4
            let session = URLSession(configuration: config, delegate: Pinning(pin: pin), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            guard let (_, response) = try? await session.data(from: URL(string: "https://127.0.0.1:18799/v1/status")!) else { return nil }
            return (response as? HTTPURLResponse)?.statusCode
        }
        check(await get(pin: first.fingerprint) == 200, "pinned certificate accepted")
        check(sawNetwork == true, "Wi-Fi request marked as from the network")
        sawNetwork = nil
        check(await get(pin: other.fingerprint) == nil, "another Mac's certificate refused")
        check(sawNetwork == nil, "refused connection never reached the handler")
        // Plain HTTP to the TLS port gets nothing.
        let plain = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:18799/v1/status")!)
        check((plain?.1 as? HTTPURLResponse)?.statusCode != 200, "unencrypted request refused")

        if failures > 0 { print("\(failures) Wi-Fi pairing checks failed"); exit(1) }
        print("PASS Wi-Fi pairing: certificate, admitted addresses, pinned TLS, network marking")
    }
}

extension URL {
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true); return self
    }
}
