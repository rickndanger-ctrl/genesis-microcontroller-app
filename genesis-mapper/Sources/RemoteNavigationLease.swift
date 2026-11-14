import Foundation

/// One remote navigation lease belongs to one provider, phone route and popup.
/// Root-element and process identity are checked separately by MenuNavigator.
struct RemoteNavigationLease {
    let session: String
    let provider: String
    let chatID: String?
    let generation: Int
    var observedAt: TimeInterval

    static let commands = ["menuPrevious", "menuNext", "menuSelect", "menuBack", "menuHome"]
    static let lifetime: TimeInterval = 30

    func accepts(session: String, provider: String, chatID: String?, generation: Int, now: TimeInterval) -> Bool {
        self.session == session && UUID(uuidString: session) != nil &&
        self.provider == provider && self.chatID == chatID && self.generation == generation &&
        generation >= 0 && now.isFinite && observedAt.isFinite &&
        now >= observedAt && now - observedAt <= Self.lifetime
    }
}

struct RemoteNavigationState: Codable {
    var active: Bool
    var session: String?
    var label: String
    var selection: String?
    static let inactive = RemoteNavigationState(active: false, session: nil,
        label: "Open a menu or file picker on the selected Mac to navigate it.", selection: nil)
}
