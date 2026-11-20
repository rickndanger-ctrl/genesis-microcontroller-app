import Foundation

/// Turns a failure to reach a Mac into what to do about it. System network
/// errors ("The request timed out.") say nothing a person can act on.
enum ConnectionHelp {
    enum Problem: Equatable {
        /// iOS is blocking this app from devices on the local network.
        case localNetworkBlocked
        /// The phone has no usable network at all, or iOS blocked the request
        /// before it left (which is how a denied Local Network permission shows up).
        case phoneOffline
        /// The network works but the Mac did not answer.
        case macUnreachable
        /// Something answered, but not over a connection this app trusts.
        case untrustedConnection
    }

    /// Where the free Mac app is offered, with a download button.
    static let macAppPage = URL(string: "https://rickndanger-ctrl.github.io/agent-micro-controller-site/")!

    static func problem(_ error: Error) -> Problem? {
        let ns = error as NSError
        let text = describeChain(ns).lowercased()
        if text.contains("local network prohibited") || text.contains("local network denied") { return .localNetworkBlocked }
        guard ns.domain == NSURLErrorDomain else { return nil }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return .phoneOffline
        case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorResourceUnavailable:
            return .macUnreachable
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed:
            return .untrustedConnection
        default:
            return nil
        }
    }

    /// What to tell the person, naming the Mac when it is known.
    static func message(_ problem: Problem, mac: String?) -> String {
        let theMac = mac.map { "“\($0)”" } ?? "your Mac"
        let TheMac = mac.map { "“\($0)”" } ?? "Your Mac"
        switch problem {
        case .localNetworkBlocked:
            return "iPhone is blocking Agent Micro Controller from your local network. Turn on Local Network for it in Settings, then try again."
        case .phoneOffline:
            return "Your phone can’t reach \(theMac). Check that Wi-Fi is on, and that Local Network is turned on for Agent Micro Controller in Settings."
        case .macUnreachable:
            return "\(TheMac) didn’t answer. Make sure it’s awake, Agent Micro Controller is running on it, and your phone is on the same Wi-Fi. Away from home, Tailscale needs to be on for both."
        case .untrustedConnection:
            return "\(TheMac) didn’t prove it’s the Mac you paired. If you reinstalled the Mac app, scan a new code from its setup window."
        }
    }

    /// Whether the fix lives in this app's page in iOS Settings.
    static func fixedInSettings(_ problem: Problem) -> Bool {
        problem == .localNetworkBlocked || problem == .phoneOffline
    }

    /// The text to show for any error: the plain version for network trouble,
    /// the error's own wording otherwise.
    static func describe(_ error: Error, mac: String?) -> String {
        problem(error).map { message($0, mac: mac) } ?? error.localizedDescription
    }

    private static func describeChain(_ error: NSError) -> String {
        var parts = [error.localizedDescription, error.debugDescription]
        if let path = error.userInfo["_NSURLErrorNWPathKey"] { parts.append(String(describing: path)) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append(describeChain(underlying)) }
        return parts.joined(separator: " ")
    }
}
