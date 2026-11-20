import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The deck is a real model: `design/build_deck.py` builds it in Blender and
/// renders each control through a camera tilted 24 degrees, so every key shows
/// its front wall and stands off the plate. The views here place those
/// renders, light them, and move them. They are decorative: actions, gestures
/// and accessibility stay with the controls in `ControllerScreen`.
enum GenesisPalette {
    static let hex: [UInt32] = [0x3478F6, 0x9B5CF6, 0xF0529C, 0xFF9933, 0x30C778, 0x29C4DE]
    /// The same six identities as light: brighter and more saturated.
    static let glowHex: [UInt32] = [0x2E7DFF, 0xA259FF, 0xFF3D9A, 0xFF8A1F, 0x1FD873, 0x12CDEB]

    static func rgb(_ h: UInt32) -> Color {
        Color(red: Double((h >> 16) & 255) / 255, green: Double((h >> 8) & 255) / 255, blue: Double(h & 255) / 255)
    }
    static func color(_ index: Int) -> Color { rgb(hex[max(0, min(5, index))]) }
    static func glow(_ index: Int) -> Color { rgb(glowHex[max(0, min(5, index))]) }

    /// The light for what a chat is doing. Idle is plain white, so an idle key is just its snow cap.
    static func light(_ activity: ChatActivity?) -> Color {
        switch activity {
        case .thinking: return rgb(0x2E7DFF)
        case .complete: return rgb(0x1FD873)
        case .needsInput: return rgb(0xFFB81C)
        case .error: return rgb(0xFF3B30)
        case .idle, .none: return .white
        }
    }
    /// How strongly a key is lit, 0…1. Unassigned keys are nearly dark; idle is a faint white.
    static func level(_ activity: ChatActivity?, assigned: Bool) -> Double {
        switch activity {
        case .thinking: return 1.0
        case .needsInput, .error: return 0.95
        case .complete: return 0.85
        case .idle: return 0.26
        case .none: return assigned ? 0.12 : 0.05
        }
    }
    /// The color for everything around the keys (the other keys, knobs, backdrop, Send).
    /// White would vanish there, so an idle chat uses a quiet slate.
    static let slate = rgb(0x6F7D92)
    static func accent(_ activity: ChatActivity?) -> Color {
        switch activity {
        case .idle, .none: return slate
        default: return light(activity)
        }
    }
    /// A dot that shows on a white surface: the light itself, or a pale grey for idle.
    static func dot(_ activity: ChatActivity?) -> Color {
        switch activity {
        case .idle: return rgb(0xD5DBE5)
        case .none: return rgb(0xD5DBE5).opacity(0.5)
        default: return light(activity)
        }
    }

    static let ink = Color(red: 0.10, green: 0.12, blue: 0.16)
    static let text = ink
    static let dim = Color(red: 0.36, green: 0.39, blue: 0.45)
    static let canvas = Color(red: 0.945, green: 0.953, blue: 0.965)
    static let panel = Color.white.opacity(0.74)
    static let panelRaised = Color.white
    static let hairline = Color.black.opacity(0.08)
}

/// The deck's decoration: color for everything that is not a status light.
///
/// The six chat caps belong to status (white, blue, green, yellow, red) and a
/// theme never touches them. A theme colors the glow under and around the
/// body, the knobs and the Home button, and only while there is nothing to
/// report: a chat that is working, finished, waiting or failed takes those
/// over with its own light.
enum DeckTheme: String, CaseIterable, Identifiable {
    case aurora, sunset, candy, mono
    static let storageKey = "deck.theme"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .aurora: return "Aurora"
        case .sunset: return "Sunset"
        case .candy: return "Candy"
        case .mono: return "Mono"
        }
    }
    var detail: String {
        switch self {
        case .aurora: return "Teal, violet and sky."
        case .sunset: return "Coral, magenta and amber."
        case .candy: return "Pink, lilac and aqua."
        case .mono: return "No color until a chat has something to say."
        }
    }
    /// The colors the deck drifts through. Empty for Mono.
    var colors: [Color] {
        switch self {
        case .aurora: return [0x19D3C5, 0x7C5CFF, 0x3FB6FF, 0x5EF0B0].map(GenesisPalette.rgb)
        case .sunset: return [0xFF7A59, 0xFF4FA3, 0xFFB347, 0x9B5CF6].map(GenesisPalette.rgb)
        case .candy: return [0xFF6FB5, 0xB08CFF, 0x5CE1E6, 0xFFD166].map(GenesisPalette.rgb)
        case .mono: return []
        }
    }
    /// One of the theme's colors, or the quiet slate when the theme has none.
    func color(_ index: Int) -> Color { colors.isEmpty ? GenesisPalette.slate : colors[index % colors.count] }
    /// What a part of the deck shows: the chat's light when it has one, otherwise this theme's color.
    func accent(_ activity: ChatActivity?, _ index: Int = 0) -> Color {
        switch activity {
        case .idle, .none: return color(index)
        default: return GenesisPalette.light(activity)
        }
    }
}

/// The theme's colors turning slowly, used as the glow under the deck.
struct ThemeDrift: View {
    let theme: DeckTheme
    var period: Double = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = false
    var body: some View {
        let colors = theme.colors
        AngularGradient(colors: colors + [colors.first ?? .clear], center: .center)
            .rotationEffect(.degrees(turned ? 360 : 0))
            // Slow enough to be felt, not watched.
            .animation(reduceMotion ? nil : .linear(duration: period).repeatForever(autoreverses: false), value: turned)
            .onAppear { turned = true }
            .accessibilityHidden(true)
    }
}

/// A soft white panel used by every surface around the deck.
struct GenesisPanel: ViewModifier {
    var radius: CGFloat = 20
    var raised = false
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(raised ? GenesisPalette.panelRaised : GenesisPalette.panel)
                .shadow(color: .black.opacity(raised ? 0.10 : 0.05), radius: raised ? 8 : 5, y: raised ? 3 : 2)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(contrast == .increased ? GenesisPalette.ink.opacity(0.55) : GenesisPalette.hairline, lineWidth: 1))
        }
    }
}
extension View {
    func genesisPanel(radius: CGFloat = 20, raised: Bool = false) -> some View { modifier(GenesisPanel(radius: radius, raised: raised)) }
}

/// The room behind the controller: bright, with a faint wash of the selected chat's light.
struct GenesisBackdrop: View {
    let color: Color
    var theme: DeckTheme = .mono
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            GenesisPalette.canvas
            LinearGradient(colors: [.white.opacity(0.9), .clear], startPoint: .top, endPoint: .center)
            RadialGradient(colors: [color.opacity(0.16), color.opacity(0.05), .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 520)
            if !theme.colors.isEmpty {
                // Two faint pools of the theme's other colors, off to the corners.
                RadialGradient(colors: [theme.color(1).opacity(0.13), .clear], center: UnitPoint(x: 0.05, y: 0.88), startRadius: 0, endRadius: 360)
                RadialGradient(colors: [theme.color(2).opacity(0.11), .clear], center: UnitPoint(x: 0.98, y: 0.12), startRadius: 0, endRadius: 340)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: color)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Pixel geometry of the renders, copied from `design/deck-metrics.json`.
enum DeckArt {
    /// Vertical foreshortening of anything lying flat, from the camera's tilt.
    static let flat: CGFloat = 0.9135

    struct Sprite {
        let name: String
        let image: CGSize
        /// The control's silhouette inside the image; this is what a layout frame maps to.
        let bounds: CGRect
        /// Fixed borders for nine-slice stretching, in pixels.
        var insets = EdgeInsets()
    }

    static let shell = Sprite(name: "DeckShell", image: CGSize(width: 1536, height: 1536),
                              bounds: CGRect(x: 65.45, y: 91.96, width: 1405.11, height: 1354.8),
                              insets: EdgeInsets(top: 292, leading: 265, bottom: 346, trailing: 265))
    /// Plate margins inside the shell's silhouette, as fractions of its width.
    static let plateSide: CGFloat = 66.78 / 1405.11
    static let plateTop: CGFloat = 75.13 / 1405.11
    static let plateBottom: CGFloat = 132.18 / 1405.11
    /// Height of the body's front wall, where the tagline is printed.
    static let frontWall: CGFloat = 57.0 / 1405.11

    static let capBounds = CGRect(x: 134.4, y: 144.09, width: 371.2, height: 355.88)
    static let capUp = Sprite(name: "DeckCapUp", image: CGSize(width: 640, height: 640), bounds: capBounds,
                              insets: EdgeInsets(top: 214, leading: 241, bottom: 296, trailing: 241))
    /// The pressed cap is placed in the same frame, so it sits lower in it.
    static let capDown = Sprite(name: "DeckCapDown", image: CGSize(width: 640, height: 640), bounds: capBounds,
                                insets: EdgeInsets(top: 236, leading: 241, bottom: 274, trailing: 241))
    /// The top face inside the cap's silhouette, as fractions of the cap's width.
    static let capTopSide: CGFloat = 36.27 / 371.2
    static let capFront: CGFloat = 90.83 / 371.2
    static let capTravel: CGFloat = 21.69 / 371.2

    static let knobBounds = CGRect(x: 123.73, y: 130.67, width: 392.53, height: 412.02)
    static let knobSnow = Sprite(name: "DeckKnobSnow", image: CGSize(width: 640, height: 640), bounds: knobBounds)
    static let knobGraphite = Sprite(name: "DeckKnobGraphite", image: CGSize(width: 640, height: 640), bounds: knobBounds)
    static let knobTopCenter = CGPoint(x: 320 - 123.73, y: 274.88 - 130.67)
    static let knobTopRadius: CGFloat = 157.87

    static let puckBounds = CGRect(x: 89.6, y: 116.97, width: 332.8, height: 301.46)
    static let puck = Sprite(name: "DeckPuck", image: CGSize(width: 512, height: 512), bounds: puckBounds)
    static let puckTopCenter = CGPoint(x: 256 - 89.6, y: 245.59 - 116.97)
    static let puckTopRadius: CGFloat = 140.8

    private static var cache: [String: UIImage] = [:]
    /// The named render at a density that makes one pixel `1 / pixelsPerPoint` points.
    static func image(_ name: String, pixelsPerPoint: CGFloat) -> UIImage? {
        let density = max(0.1, (pixelsPerPoint * 50).rounded() / 50)
        let key = "\(name)@\(density)"
        if let cached = cache[key] { return cached }
        guard let source = UIImage(named: name)?.cgImage else { return nil }
        let image = UIImage(cgImage: source, scale: density, orientation: .up)
        if cache.count > 96 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// Draws a render so that its silhouette fills `size`. `unit` is the width
/// the silhouette has when it is not stretched; anything beyond that comes
/// from stretching the middle of the image and leaving its corners alone.
struct SlicedSprite: View {
    let sprite: DeckArt.Sprite
    var suffix = ""
    let unit: CGFloat
    let size: CGSize
    var tint: Color?

    var body: some View {
        let density = sprite.bounds.width / max(1, unit)
        let left = sprite.bounds.minX / density, right = (sprite.image.width - sprite.bounds.maxX) / density
        let top = sprite.bounds.minY / density, bottom = (sprite.image.height - sprite.bounds.maxY) / density
        if let image = DeckArt.image(sprite.name + suffix, pixelsPerPoint: density) {
            Image(uiImage: image)
                .renderingMode(tint == nil ? .original : .template)
                .resizable(capInsets: EdgeInsets(top: sprite.insets.top / density, leading: sprite.insets.leading / density,
                                                 bottom: sprite.insets.bottom / density, trailing: sprite.insets.trailing / density),
                           resizingMode: .stretch)
                .interpolation(.high)
                .foregroundStyle(tint ?? .clear)
                .frame(width: size.width + left + right, height: size.height + top + bottom)
                .offset(x: (right - left) / 2, y: (bottom - top) / 2)
                .frame(width: size.width, height: size.height)
        }
    }
}

/// The rendered body, stretched to any deck size, on its own soft shadow.
struct DeckChassis: View {
    let glow: Color
    var scale: CGFloat = 1
    var theme: DeckTheme = .mono
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if !theme.colors.isEmpty {
                    // Light spilling out from under the body, turning slowly.
                    ThemeDrift(theme: theme)
                        .frame(width: size.width * 1.5, height: size.width * 1.5)
                        .mask(RoundedRectangle(cornerRadius: size.width * 0.11, style: .continuous)
                            .frame(width: size.width * 1.02, height: size.height * 1.02))
                        .blur(radius: 22 * scale)
                        .opacity(0.62)
                        .frame(width: size.width, height: size.height)
                }
                SlicedSprite(sprite: DeckArt.shell, unit: size.width, size: size)
                    .shadow(color: glow.opacity(0.28), radius: 26 * scale, y: 10 * scale)
                    .shadow(color: .black.opacity(0.24), radius: 16 * scale, y: 14 * scale)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: glow)
                if !theme.colors.isEmpty {
                    // The same light seen through the plate, under the keys. The keys
                    // are drawn above it with their own shadows, so they still sit proud.
                    let side = size.width * DeckArt.plateSide, top = size.width * DeckArt.plateTop, bottom = size.width * DeckArt.plateBottom
                    ThemeDrift(theme: theme)
                        .frame(width: size.width * 1.5, height: size.width * 1.5)
                        .mask(RoundedRectangle(cornerRadius: size.width * 0.035, style: .continuous)
                            .frame(width: max(0, size.width - side * 2), height: max(0, size.height - top - bottom))
                            .offset(y: (top - bottom) / 2))
                        .blur(radius: 14 * scale)
                        .opacity(0.20)
                        .blendMode(.multiply)
                        .frame(width: size.width, height: size.height)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A snow keycap over a colored LED. The cap and the light it throws are
/// renders; the light is a white mask tinted here, so its color and strength
/// can change freely. A resting chat glows softly, the chat in use glows hard.
struct Keycap<Label: View>: View {
    var led: Color
    /// 0 is unlit, 1 is fully lit.
    var level: Double
    var breathing = false
    var pressed = false
    var scale: CGFloat = 1
    var haptic = true
    /// Width of one key, which fixes the render's scale; a wider frame stretches the cap.
    let unit: CGFloat
    @ViewBuilder var label: () -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var down = false
    @State private var pressStarted = Date.distantPast
    @State private var generation = 0

    var body: some View {
        GeometryReader { geometry in
            if breathing && !reduceMotion && scenePhase == .active {
                // Only the chat in use breathes; the timeline is local
                // decoration and never touches controller state.
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    cap(size: geometry.size, breath: (sin(context.date.timeIntervalSinceReferenceDate * .pi / 2.2) + 1) / 2)
                }
            } else {
                cap(size: geometry.size, breath: breathing ? 0.8 : 0)
            }
        }
        .onChange(of: pressed) { _, now in pressChanged(now) }
        .onDisappear { down = false }
    }

    private func pressChanged(_ now: Bool) {
        generation += 1
        if now {
            pressStarted = Date()
            if haptic, !ControllerSound.shared.captureIsActive() {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.75)
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.045)) { down = true }
        } else {
            // A quick tap still shows a full stroke before the cap comes back up.
            let current = generation
            let wait = max(0, 0.11 - Date().timeIntervalSince(pressStarted))
            Task { @MainActor in
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard generation == current else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.5)) { down = false }
            }
        }
    }

    private func cap(size: CGSize, breath: Double) -> some View {
        let lit = min(1, max(0, level * (breathing ? 0.86 + breath * 0.14 : 1) + (down ? 0.22 : 0)))
        // Two stacked tints: the first carries the color, the second and the
        // white core only arrive near full strength, which is what reads as
        // a light turned up hard rather than a darker tint.
        let wash = min(1, lit * 1.15)
        let drive = max(0, lit - 0.5) / 0.5
        let side = unit * DeckArt.capTopSide
        let front = unit * DeckArt.capFront
        let travel = down ? unit * DeckArt.capTravel : 0
        let face = CGSize(width: max(0, size.width - side * 2), height: max(0, size.height - front))
        return ZStack(alignment: .top) {
            SlicedSprite(sprite: DeckArt.capUp, unit: unit, size: size).opacity(down ? 0 : 1)
            SlicedSprite(sprite: DeckArt.capDown, unit: unit, size: size).opacity(down ? 1 : 0)
            Group {
                SlicedSprite(sprite: DeckArt.capUp, suffix: "Glow", unit: unit, size: size, tint: led).opacity(down ? 0 : 1)
                SlicedSprite(sprite: DeckArt.capDown, suffix: "Glow", unit: unit, size: size, tint: led).opacity(down ? 1 : 0)
            }.opacity(wash)
            Group {
                SlicedSprite(sprite: DeckArt.capUp, suffix: "Glow", unit: unit, size: size, tint: led).opacity(down ? 0 : 1)
                SlicedSprite(sprite: DeckArt.capDown, suffix: "Glow", unit: unit, size: size, tint: led).opacity(down ? 1 : 0)
            }.opacity(drive * 0.42)
            ZStack {
                Ellipse().fill(RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: max(1, min(face.width, face.height) * 0.52)))
                    .frame(width: face.width * 0.96, height: face.height * 0.92)
                    .opacity(drive * 0.9)
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: unit * 0.13, style: .continuous).strokeBorder(GenesisPalette.ink.opacity(0.7), lineWidth: 1.2 * scale)
                }
                label().foregroundStyle(GenesisPalette.ink)
            }
            .frame(width: face.width, height: face.height)
            .offset(y: travel)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.30), value: level)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.30), value: led)
    }
}

/// A cap for keys that run on a tap and open their editor on a hold. The
/// recognizers are the same exclusive pair the controller has always used.
/// Touch-down comes from a passive observer instead of a SwiftUI gesture:
/// folding it into the pair stops the tap from being recognized, and any
/// simultaneous SwiftUI gesture stops the page scrolling from a key.
struct HoldTapKeycap<Label: View>: View {
    var led: Color
    var level: Double
    var breathing = false
    var scale: CGFloat = 1
    let unit: CGFloat
    let tap: () -> Void
    let hold: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var touching = false
    @State private var stroke = false

    var body: some View {
        Keycap(led: led, level: level, breathing: breathing, pressed: touching || stroke, scale: scale, unit: unit, label: label)
            // The touch area reaches halfway into the gap on every side, so a
            // thumb that lands between two keys still presses the nearer one.
            .contentShape(Rectangle().inset(by: -4 * scale))
            .gesture(LongPressGesture(minimumDuration: 0.65).exclusively(before: TapGesture()).onEnded { value in
                // Activation always shows a stroke, including from VoiceOver
                // or a touch too brief for the observer to draw.
                stroke = true
                Task { @MainActor in stroke = false }
                switch value {
                case .first: hold()
                case .second: tap()
                }
            })
            .gesture(TouchObserver { touching = $0 })
            .onDisappear { touching = false }
    }
}

/// Reports a finger resting on a view without taking part in recognition:
/// it never begins, prevents nothing, and gives up once the finger travels.
struct TouchObserver: UIGestureRecognizerRepresentable {
    let changed: (Bool) -> Void
    func makeUIGestureRecognizer(context: Context) -> PassiveTouchRecognizer {
        let recognizer = PassiveTouchRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.changed = changed
        return recognizer
    }
    func updateUIGestureRecognizer(_ recognizer: PassiveTouchRecognizer, context: Context) {
        recognizer.changed = changed
    }
}

final class PassiveTouchRecognizer: UIGestureRecognizer {
    var changed: ((Bool) -> Void)?
    private var origin: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard origin == nil, let touch = touches.first else { return }
        origin = touch.location(in: nil)
        changed?(true)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let origin, let point = touches.first?.location(in: nil) else { return }
        if hypot(point.x - origin.x, point.y - origin.y) > 10 { finish() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish() }
    override func reset() {
        if origin != nil { changed?(false) }
        origin = nil
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    private func finish() {
        guard origin != nil else { return }
        origin = nil
        changed?(false)
        state = .failed
    }
}

/// Button style for plain keys: the cap follows the button's pressed state.
struct KeycapButtonStyle: ButtonStyle {
    var led: Color
    var level: Double
    var scale: CGFloat = 1
    let unit: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        Keycap(led: led, level: level, pressed: configuration.isPressed, scale: scale, unit: unit) { configuration.label }
    }
}

/// Lays something flat on top of a rendered control: `content` is drawn in a
/// square of the top face's diameter, then foreshortened to match the tilt.
private struct OnTopFace<Content: View>: View {
    let center: CGPoint
    let radius: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(x: 1, y: DeckArt.flat)
            .position(center)
    }
}

/// The round Home button: a black glass puck on a chrome ring, with the
/// activity matrix lying on its face inside a ring of the selected chat's light.
struct HomePuckStyle: ButtonStyle {
    var color: Color
    var caption: String
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return VStack(spacing: 2 * scale) {
            GeometryReader { geometry in
                let width = min(geometry.size.width * 0.86, geometry.size.height * 0.94 * DeckArt.puckBounds.width / DeckArt.puckBounds.height)
                let density = DeckArt.puckBounds.width / max(1, width)
                let size = CGSize(width: width, height: width * DeckArt.puckBounds.height / DeckArt.puckBounds.width)
                let center = CGPoint(x: DeckArt.puckTopCenter.x / density, y: DeckArt.puckTopCenter.y / density)
                let radius = DeckArt.puckTopRadius / density
                ZStack(alignment: .topLeading) {
                    SlicedSprite(sprite: DeckArt.puck, unit: width, size: size)
                    OnTopFace(center: center, radius: radius) {
                        ZStack {
                            Circle().strokeBorder(color, lineWidth: max(1.4, radius * 0.07)).blur(radius: down ? 3 * scale : 1.5 * scale)
                            Circle().strokeBorder(color, lineWidth: max(1.2, radius * 0.055))
                            configuration.label
                        }
                    }
                    .offset(y: down ? 1.5 * scale : 0)
                }
                .frame(width: size.width, height: size.height)
                .scaleEffect(down ? 0.965 : 1, anchor: .bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(caption).font(.system(size: 7 * scale, weight: .bold, design: .monospaced)).tracking(0.6 * scale)
                .foregroundStyle(GenesisPalette.ink.opacity(0.55))
        }
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : (down ? .easeOut(duration: 0.05) : .spring(response: 0.24, dampingFraction: 0.5)), value: down)
    }
}

/// A rendered knob. The body is rotationally symmetric, so turning it only
/// moves what lies on its top face: the pointer and, on the chat dial, six
/// slot lights. The pointer always aims at the lit slot.
struct DialKnob: View {
    enum Finish { case snow, graphite }
    let finish: Finish
    let color: Color
    /// 0…1 strength of the light inside the snow knob.
    var level: Double = 0.4
    /// The six slot lights on the chat dial; `nil` draws a single ring.
    var ringSelection: Int?
    /// The color of each of the six lights: what each key's chat is doing.
    var ringColors: [Color] = []
    var rotation: Double
    var active = false
    var pressed = false
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The knob's drawn width inside a frame.
    private static func width(in frame: CGSize) -> CGFloat {
        // Short of the full height, so the skirt clears the caption beneath.
        min(frame.width * 0.94, frame.height * 0.92 * DeckArt.knobBounds.width / DeckArt.knobBounds.height)
    }

    /// Where the top face lies inside a frame: its center, and its radius
    /// across. Seen at the camera's tilt it is `DeckArt.flat` times as tall.
    static func face(in frame: CGSize) -> (center: CGPoint, radius: CGFloat) {
        let width = max(1, width(in: frame))
        let ratio = width / DeckArt.knobBounds.width
        let height = DeckArt.knobBounds.height * ratio
        return (CGPoint(x: (frame.width - width) / 2 + DeckArt.knobTopCenter.x * ratio,
                        y: (frame.height - height) / 2 + DeckArt.knobTopCenter.y * ratio),
                DeckArt.knobTopRadius * ratio)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = Self.width(in: geometry.size)
            Group {
                if finish == .snow && level > 0.7 && !reduceMotion && scenePhase == .active {
                    TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                        knob(width: width, breath: (sin(context.date.timeIntervalSinceReferenceDate * .pi / 2.2) + 1) / 2)
                    }
                } else {
                    knob(width: width, breath: 0.6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func knob(width: CGFloat, breath: Double) -> some View {
        let snow = finish == .snow
        let density = DeckArt.knobBounds.width / max(1, width)
        let size = CGSize(width: width, height: width * DeckArt.knobBounds.height / DeckArt.knobBounds.width)
        let center = CGPoint(x: DeckArt.knobTopCenter.x / density, y: DeckArt.knobTopCenter.y / density)
        let radius = DeckArt.knobTopRadius / density
        let lit = min(1, level * (level > 0.7 ? 0.86 + breath * 0.14 : 1) + (active ? 0.15 : 0) + (pressed ? 0.2 : 0))
        return ZStack(alignment: .topLeading) {
            SlicedSprite(sprite: snow ? DeckArt.knobSnow : DeckArt.knobGraphite, unit: width, size: size)
            if snow {
                SlicedSprite(sprite: DeckArt.knobSnow, suffix: "Glow", unit: width, size: size, tint: color).opacity(min(1, lit * 1.1))
                SlicedSprite(sprite: DeckArt.knobSnow, suffix: "Glow", unit: width, size: size, tint: color).opacity(max(0, lit - 0.5) / 0.5 * 0.35)
            }
            OnTopFace(center: center, radius: radius) {
                ZStack {
                    if snow {
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: radius * 0.7))
                            .opacity(max(0, lit - 0.5) / 0.5 * 0.85)
                    }
                    ring(radius: radius, lit: lit)
                    Capsule().fill(snow ? GenesisPalette.ink.opacity(0.85) : Color.white.opacity(0.95))
                        .frame(width: max(2, radius * 0.10), height: radius * 0.36)
                        .offset(y: -radius * 0.40)
                        .rotationEffect(.degrees(rotation))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(pressed ? 0.965 : 1, anchor: .bottom)
        .offset(y: pressed ? 1.5 * scale : 0)
        .animation(reduceMotion ? nil : (pressed ? .easeOut(duration: 0.05) : .spring(response: 0.25, dampingFraction: 0.5)), value: pressed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: color)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: ringSelection)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.30), value: level)
    }

    @ViewBuilder private func ring(radius: CGFloat, lit: Double) -> some View {
        let width = max(2, radius * 0.11)
        if let ringSelection {
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    let on = index == ringSelection
                    let tint = index < ringColors.count ? ringColors[index] : GenesisPalette.slate
                    let arc = Circle().inset(by: width / 2 + radius * 0.07)
                        .trim(from: CGFloat(index) / 6 + 0.018, to: CGFloat(index + 1) / 6 - 0.018)
                    ZStack {
                        if on { arc.stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round)).blur(radius: 3 * scale) }
                        arc.stroke(tint.opacity(on ? 1 : 0.38), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                }
            }
            // Segment 0 is centered at twelve o'clock, where the pointer rests for the first slot.
            .rotationEffect(.degrees(-120))
        } else {
            let arc = Circle().inset(by: width / 2 + radius * 0.07)
            ZStack {
                arc.stroke(color, lineWidth: width * 0.8).blur(radius: (active || pressed ? 4 : 2) * scale)
                arc.stroke(color, lineWidth: width * 0.7)
            }
        }
    }
}

/// The activity matrix: three steady pixels at rest, a moving pattern while working.
struct PixelLight: View {
    let color: Color
    let working: Bool
    let reduceMotion: Bool
    var scale: CGFloat = 1
    /// Colors for the resting pattern. Empty keeps the three still dots.
    var idleColors: [Color] = []

    /// How brightly a pixel is lit while resting: a ring that opens out from
    /// the centre every few seconds, then a pause. Slow and soft on purpose.
    static func idleLevel(row: Int, column: Int, time: TimeInterval) -> Double {
        let ring = Double(max(abs(row - 2), abs(column - 2)))      // 0 at the centre, 2 at the edge
        let cycle = 4.8, t = time.truncatingRemainder(dividingBy: cycle)
        let front = t / 0.55                                        // the ring the wave has reached
        let distance = abs(front - ring)
        let wave = front <= 3.2 ? max(0, 1 - distance) : 0          // one soft ring, then rest
        return 0.22 + 0.78 * wave
    }
    /// Which resting color is showing: one per ripple.
    static func idleColorIndex(time: TimeInterval, count: Int) -> Int { count == 0 ? 0 : Int(time / 4.8) % count }

    var body: some View {
        let animatesIdle = !idleColors.isEmpty && !working
        TimelineView(.animation(minimumInterval: working ? 0.25 : 0.1, paused: reduceMotion || (!working && !animatesIdle))) { context in
            let now = context.date.timeIntervalSince1970
            let phase = Int(now * 4) % 12
            let resting = animatesIdle && !reduceMotion
            let tint = resting ? idleColors[Self.idleColorIndex(time: now, count: idleColors.count)] : color
            VStack(spacing: 2 * scale) {
                ForEach(0..<5) { row in HStack(spacing: 2 * scale) {
                    ForEach(0..<5) { column in
                        let i = row * 5 + column
                        let level: Double = working ? ((i + phase) % 7 < 2 ? 1 : 0.22)
                            : resting ? Self.idleLevel(row: row, column: column, time: now)
                            : ([11, 12, 13].contains(i) ? 1 : 0.22)
                        Circle().fill(tint.opacity(level)).frame(width: 3.4 * scale, height: 3.4 * scale)
                            .shadow(color: tint.opacity(level > 0.6 ? 0.9 * level : 0), radius: 2 * scale)
                    }
                }
                }
            }
        }.accessibilityHidden(true)
    }
}
