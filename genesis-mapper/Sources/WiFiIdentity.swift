import Foundation
import Security
import CryptoKit
import SystemConfiguration

/// This Mac's own certificate for connections over the local network.
///
/// It is self-signed, so nothing trusts it by default. A phone learns its
/// fingerprint from the pairing QR code, which it scanned off this Mac's
/// screen, and from then on trusts this certificate and no other for this Mac.
/// That is what keeps a stranger on the same Wi-Fi from posing as the Mac.
struct WiFiIdentity {
    static let port: UInt16 = 18766
    let identity: SecIdentity
    /// Base64url SHA-256 of the certificate, as carried in the QR code.
    let fingerprint: String

    enum Failure: LocalizedError {
        case needsNewerMacOS, couldNotCreate(String), couldNotLoad
        var errorDescription: String? {
            switch self {
            case .needsNewerMacOS: return "Wi-Fi pairing needs macOS 15 or later. Use Tailscale on this Mac instead."
            case .couldNotCreate(let step): return "Could not create this Mac's Wi-Fi certificate (\(step))."
            case .couldNotLoad: return "Could not load this Mac's Wi-Fi certificate."
            }
        }
    }

    private struct Stored: Codable { var p12: Data; var passphrase: String }

    /// Loads the certificate kept in `directory`, creating it the first time.
    /// The private key stays in that file (readable by this user only) and in
    /// memory; it is never added to a keychain.
    static func loadOrCreate(in directory: URL) throws -> WiFiIdentity {
        let file = directory.appendingPathComponent("wifi-identity.json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let loaded = try? load(stored) {
            return loaded
        }
        let stored = try create()
        let data = try JSONEncoder().encode(stored)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try load(stored)
    }

    private static func load(_ stored: Stored) throws -> WiFiIdentity {
        guard #available(macOS 15.0, *) else { throw Failure.needsNewerMacOS }
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: stored.passphrase,
                                      kSecImportToMemoryOnly as String: true]
        guard SecPKCS12Import(stored.p12 as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String] else { throw Failure.couldNotLoad }
        let identity = raw as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw Failure.couldNotLoad }
        return WiFiIdentity(identity: identity, fingerprint: fingerprint(of: SecCertificateCopyData(certificate) as Data))
    }

    static func fingerprint(of certificateDER: Data) -> String {
        Data(SHA256.hash(data: certificateDER)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Makes an RSA key and a ten-year self-signed certificate with the system
    /// openssl. (macOS's in-memory import reads RSA keys from it reliably.)
    private static func create() throws -> Stored {
        guard #available(macOS 15.0, *) else { throw Failure.needsNewerMacOS }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("amc-wifi-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let key = work.appendingPathComponent("key.pem").path, cert = work.appendingPathComponent("cert.pem").path
        let bundle = work.appendingPathComponent("identity.p12")
        let passphrase = DeviceRegistry.newToken()
        func openssl(_ step: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            // The passphrase goes through the environment, not the visible command line.
            process.environment = ["AMC_P12_PASS": passphrase]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw Failure.couldNotCreate(step) }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.couldNotCreate(step) }
        }
        try openssl("key", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                            "-subj", "/CN=Agent Micro Controller", "-keyout", key, "-out", cert])
        try openssl("bundle", ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", bundle.path, "-passout", "env:AMC_P12_PASS"])
        guard let p12 = try? Data(contentsOf: bundle) else { throw Failure.couldNotCreate("read") }
        return Stored(p12: p12, passphrase: passphrase)
    }

    /// The name other devices on this network know this Mac by, such as
    /// "Ricks-Mac-mini.local". Nil when Bonjour has not given it one.
    static var localHostName: String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    static var url: String? { localHostName.map { "https://\($0):\(port)" } }

    /// Whether a connection comes from a private or local network: home and
    /// office ranges, link-local, Tailscale's range and this Mac itself. The
    /// Wi-Fi listener refuses anything else, such as a public address on a Mac
    /// that is reachable from the internet.
    static func isPrivate(_ host: String) -> Bool {
        let host = host.split(separator: "%").first.map(String.init) ?? host
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            switch (b[0], b[1]) {
            case (10, _), (127, _): return true
            case (172, 16...31), (192, 168), (169, 254): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b[0] & 0xfe == 0xfc { return true }                 // fc00::/7 unique local
            if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true } // fe80::/10 link-local
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // ::1
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { // IPv4-mapped
                return isPrivate("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
            }
            return false
        }
        return false
    }
}
