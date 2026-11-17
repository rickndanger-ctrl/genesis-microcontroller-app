import Foundation

/// Turns one finger stroke on a knob into detent steps.
///
/// A stroke that runs along the knob's edge turns it, following the finger's
/// angle around the center. A stroke aimed across the knob, or one that starts
/// in its middle, is a swipe: right or up is forward. Which it is gets decided
/// once, from the first few points of movement, so a straight swipe that
/// happens to pass just above or just below the center cannot come out as a
/// turn in a direction that depends on which side it passed.
struct DialTracking {
    static let degreesPerStep = 32.0
    /// How far the dial must turn from the detent it rests on before it clicks
    /// over to the next, as a fraction of a step, the same in both directions.
    /// More than half, so a finger wobbling on a boundary cannot flicker
    /// between two steps: undoing a step takes a third of a step of travel.
    static let detentHold = 0.65

    private enum Mode { case undecided, turn, swipe }

    private let start: CGPoint
    private let center: CGPoint
    private let deadZone: CGFloat
    private let fullLeverage: CGFloat
    private let swipeDistance: CGFloat
    private let decisionTravel: CGFloat
    private let stepDegrees: Double
    private var mode: Mode
    private var lastAngle: Double?
    private var horizontalSwipe: Bool?

    private(set) var degrees = 0.0
    private(set) var steps = 0
    /// The farthest the finger has been from where it landed.
    private(set) var travel: CGFloat = 0

    /// `radius` is the radius of the knob's top face around `center`.
    /// `swipeDistance` is how far a swipe travels per step; a small knob
    /// passes a fixed thumb-sized distance rather than one tied to its size.
    init(start: CGPoint, center: CGPoint, radius: CGFloat, degreesPerStep: Double = DialTracking.degreesPerStep,
         swipeDistance: CGFloat? = nil) {
        self.start = start
        self.center = center
        stepDegrees = degreesPerStep
        deadZone = radius * 0.3
        fullLeverage = radius * 0.7
        self.swipeDistance = swipeDistance ?? max(14, radius * 0.7)
        decisionTravel = max(4, radius * 0.12)
        // The middle of the face has no useful angle, so a stroke from there swipes.
        mode = hypot(start.x - center.x, start.y - center.y) < deadZone ? .swipe : .undecided
    }

    mutating func move(to point: CGPoint) -> Int {
        let dx = point.x - start.x
        let dy = point.y - start.y
        travel = max(travel, hypot(dx, dy))
        if mode == .undecided {
            guard hypot(dx, dy) >= decisionTravel else { return 0 }
            let rx = start.x - center.x
            let ry = start.y - center.y
            let along = abs(dx * ry - dy * rx)
            let across = abs(dx * rx + dy * ry)
            mode = along >= across ? .turn : .swipe
            if mode == .turn { lastAngle = atan2(Double(ry), Double(rx)) }
        }
        if mode == .turn {
            let x = point.x - center.x
            let y = point.y - center.y
            let distance = hypot(x, y)
            guard distance >= deadZone else {
                lastAngle = nil
                return 0
            }
            let angle = atan2(Double(y), Double(x))
            if let previous = lastAngle {
                let change = angle - previous
                // Keep the change continuous across the -π / +π seam. Close to
                // the hub a small slip of the finger sweeps a large angle, so
                // the turn counts for less there and in full farther out.
                let leverage = min(1, Double(distance / fullLeverage))
                degrees += atan2(sin(change), cos(change)) * 180 / .pi * leverage
            }
            lastAngle = angle
        } else {
            if horizontalSwipe == nil, dx != 0 || dy != 0 { horizontalSwipe = abs(dx) >= abs(dy) }
            let distance = horizontalSwipe == false ? -dy : dx
            degrees = Double(distance / swipeDistance) * stepDegrees
        }
        let before = steps
        while degrees >= (Double(steps) + Self.detentHold) * stepDegrees { steps += 1 }
        while degrees <= (Double(steps) - Self.detentHold) * stepDegrees { steps -= 1 }
        return steps - before
    }
}
