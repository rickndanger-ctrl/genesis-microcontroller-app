import Foundation

@main struct CompanionSupportTests {
    static var checks = 0
    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError("FAIL: \(message)") }
    }
    static func v(_ text: String) -> CompanionVersion { CompanionVersion(text)! }

    static func main() throws {
        parsing()
        ordering()
        support()
        try decoding()
        try sections()
        try activity()
        print("Companion support: \(checks) checks passed")
    }

    static func parsing() {
        for text in ["0.6.0", "1", "1.2", "1.2.3", "1.2.3.4", "0.5.2-preview", "10.20.30"] {
            expect(CompanionVersion(text) != nil, "\"\(text)\" must parse as a version.")
        }
        expect(v("v0.6.0") == v("0.6.0"), "A leading lowercase v must be ignored.")
        expect(v("V0.6.0") == v("0.6.0"), "A leading uppercase V must be ignored.")
        expect(v("  0.6.0\n").description == "0.6.0", "Surrounding whitespace must be trimmed from the description.")
        expect(v(" v0.6.0 ").description == "v0.6.0", "The description keeps the text it was made from, trimmed.")
        expect(v("0.5.2-preview").description == "0.5.2-preview", "A pre-release version keeps its full text.")
        expect(v("1.0-rc-1") != v("1.0-rc"), "Only the first dash splits off the pre-release tag.")

        for text in ["", "   ", "v", "abc", "1.a", "1.2.3.4.5", "-1", "1.-2", "+1", "1..2", ".1", "1.", "1.0-", "-preview", "1 .0", "1.0.0 beta", "99999999999999999999"] {
            expect(CompanionVersion(text) == nil, "\"\(text)\" must be rejected as a version.")
        }
        expect(v("0.6") == v("0.6.0"), "\"0.6\" must equal \"0.6.0\".")
        expect(v("1") == v("1.0.0.0"), "Missing components must count as zero.")
        expect(v("0.6.0-a") != v("0.6.0"), "A pre-release must not equal its release.")
        expect(v("0.6.0-a") == v("0.6-a"), "Padding applies to pre-release versions too.")
    }

    static func ordering() {
        expect(v("0.5.9") < v("0.6.0"), "0.5.9 must be lower than 0.6.0.")
        expect(v("0.10.0") > v("0.9.0"), "Components must compare numerically, not as text.")
        expect(v("1.0") > v("0.99.99"), "A higher major version must win.")
        expect(v("0.6.0.1") > v("0.6.0"), "A fourth component must count.")
        expect(!(v("0.6") < v("0.6.0")) && !(v("0.6.0") < v("0.6")), "Equal versions must not order either way.")
        expect(v("0.6.0-preview") < v("0.6.0"), "A pre-release must be lower than its release.")
        expect(!(v("0.6.0") < v("0.6.0-preview")), "A release must not be lower than its pre-release.")
        expect(v("0.6.0-alpha") < v("0.6.0-beta"), "Pre-release tags must compare as plain strings.")
        expect(!(v("0.6.0-beta") < v("0.6.0-alpha")), "A later tag must not be lower than an earlier one.")
        expect(v("0.5.9-zzz") < v("0.6.0-aaa"), "The core must decide before the tag does.")
        expect(v("0.6.0-preview") > v("0.5.9"), "A pre-release of a newer core must beat an older release.")
        expect([v("0.6.0"), v("0.5.2-preview"), v("0.5.2")].sorted().map(\.description) == ["0.5.2-preview", "0.5.2", "0.6.0"],
               "Sorting must place pre-releases before their release.")
    }

    static func support() {
        expect(CompanionSupport.minimum == v("0.6.0"), "The minimum companion must be 0.6.0.")
        expect(CompanionSupport.isOutOfDate(nil), "A companion that reports no version must be out of date.")
        expect(CompanionSupport.isOutOfDate("garbage"), "An unreadable version must count as out of date.")
        expect(CompanionSupport.isOutOfDate(""), "An empty version must count as out of date.")
        expect(CompanionSupport.isOutOfDate("0.5.2-preview"), "0.5.2-preview must be out of date.")
        expect(CompanionSupport.isOutOfDate("0.5.99"), "0.5.99 must be out of date.")
        expect(CompanionSupport.isOutOfDate("0.6.0-preview"), "0.6.0-preview must be out of date because it is below 0.6.0.")
        expect(!CompanionSupport.isOutOfDate("0.6.0"), "0.6.0 must be current.")
        expect(!CompanionSupport.isOutOfDate("0.6"), "0.6 must be current.")
        expect(!CompanionSupport.isOutOfDate(" v0.7.1 "), "A newer version with a v prefix and spaces must be current.")
        expect(!CompanionSupport.isOutOfDate("1.0.0"), "1.0.0 must be current.")

        let advice = "Update Agent Micro Controller on that Mac to get Muse and recent fixes."
        expect(CompanionSupport.notice(hostName: "Studio", reported: "0.6.0") == nil, "A current companion must give no notice.")
        expect(CompanionSupport.notice(hostName: "Studio", reported: "1.2") == nil, "A newer companion must give no notice.")
        expect(CompanionSupport.notice(hostName: "Studio", reported: nil) == "Studio is running an older companion. \(advice)",
               "A missing version must give the older-companion notice.")
        expect(CompanionSupport.notice(hostName: "Studio", reported: "not a version") == "Studio is running an older companion. \(advice)",
               "An unreadable version must give the older-companion notice.")
        expect(CompanionSupport.notice(hostName: "Studio", reported: "0.5.2-preview") == "Studio is running companion 0.5.2-preview. \(advice)",
               "A too-old version must be named in the notice.")
        expect(CompanionSupport.notice(hostName: "Studio", reported: "  0.4.0 \n") == "Studio is running companion 0.4.0. \(advice)",
               "The reported version must be trimmed in the notice.")
        expect(CompanionSupport.notice(hostName: "", reported: nil) == "This Mac is running an older companion. \(advice)",
               "An empty host name must become This Mac.")
        expect(CompanionSupport.notice(hostName: "  \t", reported: "0.4.0") == "This Mac is running companion 0.4.0. \(advice)",
               "A blank host name must become This Mac.")
    }

    static func decoding() throws {
        let json = """
        {
          "checkedAt": 780000000,
          "companionVersion": "0.6.0",
          "summary": "1 problem",
          "futureField": {"ignored": true},
          "items": [
            {"provider": "mac", "name": "Accessibility", "ok": true, "detail": "Granted", "extra": 1},
            {"provider": "muse", "name": "Muse window", "ok": false, "detail": "Not found"}
          ]
        }
        """
        let report = try JSONDecoder().decode(SelfCheckReport.self, from: Data(json.utf8))
        expect(report.checkedAt == Date(timeIntervalSinceReferenceDate: 780_000_000), "A numeric date must decode as seconds since 2001-01-01.")
        expect(report.checkedAt.timeIntervalSince1970 == 780_000_000 + 978_307_200, "The decoded date must sit on the 2001 reference epoch.")
        expect(report.companionVersion == "0.6.0" && report.summary == "1 problem", "Report text fields must decode.")
        expect(report.items.count == 2 && report.items[1].detail == "Not found", "Report items must decode and unknown keys must be ignored.")
        expect(report.problemCount == 1, "A decoded report must count its failing item.")

        let activity = """
        {"entries": [
          {"time": 780000000.5, "provider": "claude", "action": "send", "status": "confirmed", "message": "Sent", "durationMs": 120, "note": "x"},
          {"time": 780000060, "provider": "muse", "action": "play", "status": "failed", "message": "No window", "durationMs": 40}
        ], "unknown": []}
        """
        let decoded = try JSONDecoder().decode(ActivityReport.self, from: Data(activity.utf8))
        expect(decoded.entries.count == 2, "Both activity entries must decode.")
        expect(decoded.entries[0].time == Date(timeIntervalSinceReferenceDate: 780_000_000.5), "A fractional numeric date must decode exactly.")
        expect(decoded.entries[1].status == "failed" && decoded.entries[1].durationMs == 40, "Activity fields must decode.")

        // The phone and Mac must agree on the wire format.
        let again = try JSONDecoder().decode(ActivityReport.self, from: JSONEncoder().encode(decoded))
        expect(again == decoded, "An activity report must survive an encode and decode round trip.")
    }

    static func item(_ provider: String, _ name: String, ok: Bool = true) -> SelfCheckItem {
        SelfCheckItem(provider: provider, name: name, ok: ok, detail: "")
    }

    static func sections() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let empty = SelfCheckReport(checkedAt: date, companionVersion: "0.6.0", summary: "", items: [])
        expect(empty.sections.isEmpty, "An empty report must have no sections.")
        expect(empty.problemCount == 0, "An empty report must have no problems.")

        let report = SelfCheckReport(checkedAt: date, companionVersion: "0.6.0", summary: "", items: [
            item("codex", "C1"), item("zed", "Z1", ok: false), item("muse", "M1"), item("mac", "A1"),
            item("alpha", "L1"), item("mac", "A2", ok: false), item("zed", "Z2"), item("claude", "B1"),
        ])
        expect(report.sections.map(\.title) == ["This Mac", "Claude", "Muse", "Codex", "Zed", "Alpha"],
               "Sections must run mac, claude, muse, codex, then other providers in first-seen order with capitalised titles.")
        expect(report.sections[0].items.map(\.name) == ["A1", "A2"], "Item order inside a section must be preserved.")
        expect(report.sections[4].items.map(\.name) == ["Z1", "Z2"], "An unknown provider must keep its items together in order.")
        expect(report.sections.map(\.id) == report.sections.map(\.title), "A section id must be its title.")
        expect(report.problemCount == 2, "The problem count must include only items that are not ok.")

        let partial = SelfCheckReport(checkedAt: date, companionVersion: "0.6.0", summary: "", items: [item("codex", "C1"), item("mac", "A1")])
        expect(partial.sections.map(\.title) == ["This Mac", "Codex"], "Sections with no items must be left out.")

        expect(item("mac", "Accessibility").id == "mac/Accessibility", "An item id must be provider and name joined by a slash.")
        expect(item("mac", "A").id != item("claude", "A").id, "The same name under different providers must have different ids.")
    }

    static func makeEntry(_ seconds: Double, provider: String = "claude", action: String = "send",
                          status: String = "confirmed", ms: Int = 10) -> ActivityEntry {
        ActivityEntry(time: Date(timeIntervalSinceReferenceDate: seconds), provider: provider, action: action,
                      status: status, message: "", durationMs: ms)
    }

    static func activity() throws {
        let expected = ["confirmed": true, "queued": true, "failed": false, "uncertain": false, "refused": false, "mystery": false]
        for (status, succeeded) in expected {
            expect(makeEntry(1, status: status).succeeded == succeeded, "Status \"\(status)\" must report succeeded as \(succeeded).")
        }

        let first = makeEntry(1), second = makeEntry(2), third = makeEntry(3)
        let report = ActivityReport(entries: [first, second, third])
        expect(report.newestFirst == [third, second, first], "newestFirst must reverse the oldest-first entries.")
        expect(report.entries == [first, second, third], "newestFirst must not change the stored order.")
        expect(ActivityReport(entries: []).newestFirst.isEmpty, "An empty activity report must have no entries to show.")

        expect(makeEntry(1).id == makeEntry(1).id, "An entry id must be stable for the same entry.")
        var reworded = makeEntry(1)
        reworded.message = "changed"
        expect(reworded.id == makeEntry(1).id, "An entry id must not depend on its message or status text.")
        let distinct = [makeEntry(1), makeEntry(2), makeEntry(1, provider: "muse"), makeEntry(1, action: "play"), makeEntry(1, ms: 11), makeEntry(1.5)]
        expect(Set(distinct.map(\.id)).count == distinct.count, "Entries that differ in time, provider, action or duration must have distinct ids.")
    }
}
