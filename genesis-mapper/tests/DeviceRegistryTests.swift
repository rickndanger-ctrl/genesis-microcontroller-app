import Foundation

@main struct DeviceRegistryTests {
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
        passed += 1
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func after(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    static func clean(_ raw: String, _ existing: [String] = []) -> String { DeviceRegistry.cleanName(raw, existing: existing) }
    static func a(_ count: Int) -> String { String(repeating: "a", count: count) }

    static func main() {
        hashing()
        names()
        enrolling()
        lookup()
        seenRules()
        revokeAndRename()
        storage()
        pairing()
        comparison()
        print("Device registry: \(passed) checks passed")
    }

    static func hashing() {
        expect(DeviceRegistry.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "The hash of abc is the standard SHA-256 vector in lowercase hex")
        expect(DeviceRegistry.hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "The hash of an empty string is the standard SHA-256 vector")
        expect(DeviceRegistry.hash("abc") != DeviceRegistry.hash("abd"), "Different secrets hash differently")

        let first = DeviceRegistry.newToken()
        let second = DeviceRegistry.newToken()
        expect(first != second, "Two new tokens differ")
        expect(Data(base64Encoded: first)?.count == 32 && Data(base64Encoded: second)?.count == 32, "A token is base64 for 32 bytes")
    }

    static func names() {
        expect(clean("Rick's iPhone") == "Rick's iPhone", "A tidy name is kept as it is")
        expect(clean("  Rick's   iPhone \n") == "Rick's iPhone", "Edges are trimmed and inner runs of spaces become one")
        expect(clean("a\tb\n\nc \r\n d") == "a b c d", "Tabs and newlines count as whitespace and collapse to one space")
        expect(clean("a\u{07}b\u{00}c") == "abc", "Other control characters are dropped")
        expect(clean("") == "iPhone or iPad" && clean("  \n\t ") == "iPhone or iPad" && clean("\u{07}\u{01}") == "iPhone or iPad", "A name with nothing left becomes the default")
        expect(clean(a(50)) == a(40), "A long name is cut to 40 characters")
        expect(clean(a(39) + " b") == a(39), "A cut that ends on a space leaves no trailing space")

        expect(clean("Pixel", ["iPad"]) == "Pixel", "A free name is not changed")
        expect(clean("Rick's iPhone", ["Rick's iPhone"]) == "Rick's iPhone 2", "A taken name gets a 2")
        expect(clean("rick's IPHONE", ["Rick's iPhone"]) == "rick's IPHONE 2", "A clash ignores case")
        expect(clean("Phone", ["Phone", "phone 2"]) == "Phone 3", "Numbers count up until one is free")
        expect(clean("", ["iPhone or iPad"]) == "iPhone or iPad 2", "The default name is made unique too")
        expect(clean(a(40), [a(40)]) == a(38) + " 2", "The suffix shortens a 40-character name to stay within 40")
        expect(clean(a(40), [a(40), a(38) + " 2"]) == a(38) + " 3" && clean(a(40), [a(40), a(38) + " 2"]).count == 40, "The next suffix also fits in 40 characters")
        expect(clean(a(37) + " bb", [a(37) + " bb"]) == a(37) + " 2", "Shortening the base does not leave a space before the suffix")
    }

    static func enrolling() {
        var registry = DeviceRegistry()
        let (first, secret) = registry.enroll(name: "Rick's iPhone", now: t0, id: "id-1", token: "secret-one")
        expect(secret == "secret-one", "Enroll hands back the secret it was given")
        expect(first.id == "id-1" && first.name == "Rick's iPhone" && first.pairedAt == t0 && first.lastSeenAt == nil, "An enrolled device has its id, name, pairing time and no last seen")
        expect(first.tokenHash == DeviceRegistry.hash("secret-one"), "The registry stores the hash of the secret")
        expect(registry.devices == [first], "The device is appended to the registry")

        let json = String(decoding: (try? JSONEncoder().encode(registry)) ?? Data(), as: UTF8.self)
        expect(!json.isEmpty && !json.contains("secret-one"), "The secret appears nowhere in the stored JSON")
        expect(json.contains(DeviceRegistry.hash("secret-one")), "The stored JSON holds the hash")

        let (second, _) = registry.enroll(name: "Rick's iPhone", now: after(5), id: "id-2", token: "secret-two")
        expect(second.name == "Rick's iPhone 2", "A repeated name is made unique")

        let (third, _) = registry.enroll(name: "iPad", now: after(6), id: "id-1", token: "secret-three")
        expect(third.id != "id-1" && UUID(uuidString: third.id) != nil, "A repeated id is replaced with a fresh UUID")
        expect(registry.devices.count == 3 && Set(registry.devices.map(\.id)).count == 3, "Every registered device has its own id")

        let generated = registry.enroll(name: "Tablet", now: t0)
        expect(UUID(uuidString: generated.device.id) != nil && Data(base64Encoded: generated.token)?.count == 32, "Enroll generates a UUID and a 32-byte token by default")
        expect(generated.device.tokenHash == DeviceRegistry.hash(generated.token), "A generated token is stored as its hash")
    }

    static func lookup() {
        var registry = DeviceRegistry()
        let (one, _) = registry.enroll(name: "One", now: t0, id: "id-1", token: "secret-one")
        let (two, _) = registry.enroll(name: "Two", now: t0, id: "id-2", token: "secret-two")
        expect(registry.device(for: "secret-one") == one, "The first secret finds the first device")
        expect(registry.device(for: "secret-two") == two, "The second secret finds the second device")
        expect(registry.device(for: "secret-three") == nil, "A wrong secret finds nothing")
        expect(registry.device(for: "") == nil, "An empty secret finds nothing")
        expect(registry.device(for: DeviceRegistry.hash("secret-one")) == nil, "Presenting the stored hash does not work as a secret")
        expect(DeviceRegistry().device(for: "secret-one") == nil, "An empty registry finds nothing")

        expect(registry.revoke("id-1"), "A known device can be revoked")
        expect(registry.device(for: "secret-one") == nil, "A revoked device's secret stops working")
        expect(registry.device(for: "secret-two") == two, "Other devices keep working after a revoke")
    }

    static func seenRules() {
        var registry = DeviceRegistry()
        _ = registry.enroll(name: "One", now: t0, id: "id-1", token: "secret-one")
        expect(registry.seen("id-1", now: after(10)), "The first sighting changes the registry")
        expect(registry.devices[0].lastSeenAt == after(10), "The first sighting is recorded")
        expect(!registry.seen("id-1", now: after(20)) && registry.devices[0].lastSeenAt == after(10), "A sighting within 60 seconds changes nothing")
        expect(!registry.seen("id-1", now: after(70)) && registry.devices[0].lastSeenAt == after(10), "A sighting at exactly 60 seconds changes nothing")
        expect(registry.seen("id-1", now: after(70.5)) && registry.devices[0].lastSeenAt == after(70.5), "A sighting more than 60 seconds later is recorded")
        expect(!registry.seen("id-1", now: after(0)), "A clock that went backwards changes nothing")

        let before = registry
        expect(!registry.seen("nobody", now: after(500)) && registry == before, "An unknown id changes nothing")
    }

    static func revokeAndRename() {
        var registry = DeviceRegistry()
        _ = registry.enroll(name: "One", now: t0, id: "id-1", token: "secret-one")
        _ = registry.enroll(name: "Two", now: t0, id: "id-2", token: "secret-two")

        expect(!registry.revoke("nobody") && registry.devices.count == 2, "Revoking an unknown id removes nothing")
        expect(registry.revoke("id-1") && registry.devices.map(\.id) == ["id-2"], "Revoking removes just that device")
        expect(!registry.revoke("id-1"), "A device cannot be revoked twice")

        _ = registry.enroll(name: "Three", now: t0, id: "id-3", token: "secret-three")
        expect(registry.rename("id-2", to: "  Kitchen   iPad "), "A new name is applied")
        expect(registry.devices[0].name == "Kitchen iPad", "The new name is cleaned")
        expect(!registry.rename("id-2", to: "Kitchen iPad") && registry.devices[0].name == "Kitchen iPad", "Renaming to the same name reports no change")
        expect(registry.rename("id-3", to: "kitchen ipad") && registry.devices[1].name == "kitchen ipad 2", "A name another device has gets a number, ignoring case")
        expect(registry.rename("id-2", to: "KITCHEN IPAD") && registry.devices[0].name == "KITCHEN IPAD", "A device may change only the case of its own name")
        expect(registry.rename("id-2", to: "   ") && registry.devices[0].name == "iPhone or iPad", "A blank name becomes the default")
        expect(!registry.rename("nobody", to: "Anything"), "Renaming an unknown id reports no change")
    }

    static func storage() {
        func decode(_ json: String) -> DeviceRegistry? { try? JSONDecoder().decode(DeviceRegistry.self, from: Data(json.utf8)) }

        let empty = decode("{}")
        expect(empty?.devices.isEmpty == true && empty?.legacySecretAccepted == true, "An empty object loads with no devices and the legacy secret accepted")
        expect(decode("{\"devices\":[]}")?.legacySecretAccepted == true, "A file without legacySecretAccepted loads as accepted")
        let off = decode("{\"legacySecretAccepted\":false}")
        expect(off?.legacySecretAccepted == false && off?.devices.isEmpty == true, "A file without devices loads as empty and keeps the stored flag")

        let device = "{\"id\":\"id-1\",\"name\":\"One\",\"tokenHash\":\"abc\",\"pairedAt\":1000}"
        let older = decode("{\"devices\":[\(device)]}")
        expect(older?.devices.count == 1 && older?.devices.first?.name == "One" && older?.legacySecretAccepted == true, "Devices load from a file that lacks the flag")

        var registry = DeviceRegistry()
        _ = registry.enroll(name: "One", now: t0, id: "id-1", token: "secret-one")
        _ = registry.enroll(name: "Two", now: after(30), id: "id-2", token: "secret-two")
        _ = registry.seen("id-2", now: after(90))
        registry.legacySecretAccepted = false
        let data = try? JSONEncoder().encode(registry)
        let decoded = data.flatMap { try? JSONDecoder().decode(DeviceRegistry.self, from: $0) }
        expect(decoded == registry, "A registry survives a round trip through JSON")
        expect(decoded?.legacySecretAccepted == false && decoded?.devices[1].lastSeenAt == after(90), "The flag and last seen survive the round trip")
    }

    static func pairing() {
        // Accepted once, then never again.
        var codes = PairingCodes()
        _ = codes.issue(now: t0, code: "good")
        expect(codes.activeCount(now: t0) == 1, "An issued code is active")
        expect(codes.redeem("good", now: after(1)) == .accepted, "A valid code is accepted")
        expect(codes.redeem("good", now: after(2)) == .rejected, "A used code is rejected")
        expect(codes.activeCount(now: after(2)) == 0, "A used code is no longer active")
        var fresh = PairingCodes()
        let generated = fresh.issue(now: t0)
        expect(Data(base64Encoded: generated)?.count == 32 && fresh.redeem(generated, now: after(1)) == .accepted, "A code is generated when none is given, and it works")

        // Expiry at exactly the lifetime.
        codes = PairingCodes()
        _ = codes.issue(now: t0, code: "soon")
        expect(codes.activeCount(now: after(PairingCodes.lifetime - 1)) == 1, "A code is active just before its lifetime ends")
        expect(codes.activeCount(now: after(PairingCodes.lifetime)) == 0, "A code is inactive at exactly its lifetime")
        expect(codes.redeem("soon", now: after(PairingCodes.lifetime)) == .rejected, "A code is rejected at exactly its lifetime")
        codes = PairingCodes()
        _ = codes.issue(now: t0, code: "soon")
        expect(codes.redeem("soon", now: after(PairingCodes.lifetime - 1)) == .accepted, "A code works just before its lifetime ends")

        // Issuing drops expired codes first.
        codes = PairingCodes()
        _ = codes.issue(now: t0, code: "old")
        _ = codes.issue(now: after(601), code: "new")
        expect(codes.activeCount(now: after(601)) == 1, "Issuing a code drops the expired ones")
        expect(codes.redeem("old", now: after(602)) == .rejected && codes.redeem("new", now: after(602)) == .accepted, "Only the new code still works")

        // The cap drops the code that would expire soonest.
        codes = PairingCodes()
        for (index, name) in ["a", "b", "c", "d"].enumerated() { _ = codes.issue(now: after(Double(index)), code: name) }
        expect(codes.activeCount(now: after(3)) == PairingCodes.maxActive, "No more than three codes are active")
        expect(codes.redeem("a", now: after(4)) == .rejected, "The oldest code was dropped")
        expect(codes.redeem("b", now: after(4)) == .accepted && codes.redeem("c", now: after(4)) == .accepted && codes.redeem("d", now: after(4)) == .accepted, "The three newest codes still work")

        // Lockout after five failures.
        codes = PairingCodes()
        _ = codes.issue(now: t0, code: "good")
        var outcomes: [PairingCodes.Outcome] = []
        for _ in 0..<5 { outcomes.append(codes.redeem("wrong", now: after(10))) }
        expect(outcomes == Array(repeating: .rejected, count: 5), "All five failures are rejected, including the one that starts the lockout")
        expect(codes.redeem("wrong", now: after(12)) == .lockedOut(until: after(70)), "A wrong code is told to slow down during a lockout, until 60 seconds after the fifth failure")
        expect(codes.activeCount(now: after(12)) == 1, "A locked-out attempt consumes nothing")
        expect(codes.redeem("wrong", now: after(69.5)) == .lockedOut(until: after(70)), "The lockout lasts until its end time")
        expect(codes.redeem("good", now: after(69.6)) == .accepted, "The correct code is accepted during a lockout, so wrong guesses cannot block the owner")
        expect(codes.redeem("good", now: after(69.7)) == .rejected, "An accepted code ends the lockout and cannot be used twice")

        // After a lockout the count starts again from zero.
        codes = PairingCodes()
        _ = codes.issue(now: t0, code: "good")
        for _ in 0..<5 { _ = codes.redeem("wrong", now: after(10)) }
        var afterLockout: [PairingCodes.Outcome] = []
        for _ in 0..<4 { afterLockout.append(codes.redeem("wrong", now: after(80))) }
        expect(afterLockout == Array(repeating: .rejected, count: 4), "Four more failures after a lockout do not start another")
        expect(codes.redeem("good", now: after(80)) == .accepted, "The code still works after those four failures")

        // Success resets the failure count.
        codes = PairingCodes()
        _ = codes.issue(now: t0, code: "one")
        _ = codes.issue(now: t0, code: "two")
        for _ in 0..<4 { _ = codes.redeem("wrong", now: after(1)) }
        expect(codes.redeem("one", now: after(1)) == .accepted, "A correct code is accepted after four failures")
        for _ in 0..<4 { _ = codes.redeem("wrong", now: after(2)) }
        expect(codes.redeem("two", now: after(2)) == .accepted, "A success resets the count, so four more failures do not lock out")

        // An empty code is a failure.
        codes = PairingCodes()
        _ = codes.issue(now: t0, code: "good")
        expect(codes.redeem("", now: after(1)) == .rejected, "An empty code is rejected")
        for _ in 0..<3 { _ = codes.redeem("", now: after(1)) }
        expect(codes.redeem("wrong", now: after(1)) == .rejected, "The fifth failure is still rejected")
        expect(codes.redeem("wrong", now: after(2)) == .lockedOut(until: after(61)), "Empty codes count as failures toward the lockout")
        codes = PairingCodes()
        _ = codes.issue(now: t0, code: "")
        expect(codes.redeem("", now: after(1)) == .rejected, "An empty code never matches, even if one was issued")
    }

    static func comparison() {
        expect(constantTimeEquals("secret", "secret"), "Equal strings match")
        expect(constantTimeEquals("", ""), "Two empty strings match")
        expect(!constantTimeEquals("secret", "secreT"), "A difference in the last character is found")
        expect(!constantTimeEquals("Secret", "secret"), "A difference in the first character is found")
        expect(!constantTimeEquals("secret", "secrets") && !constantTimeEquals("secrets", "secret"), "Different lengths do not match, in either order")
        expect(!constantTimeEquals("", "a") && !constantTimeEquals("a", ""), "An empty string matches no other")
        expect(!constantTimeEquals("a", "a\u{0}"), "Padding bytes of zero do not make a shorter string match")
        expect(constantTimeEquals("héllo ✓", "héllo ✓") && !constantTimeEquals("héllo", "hello"), "Non-ASCII text is compared by its bytes")
    }
}
