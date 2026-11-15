import Foundation

struct DialTracking {
    static let degreesPerStep = 32.0

    private let start: CGPoint
    private let center: CGPoint
    private let deadZone: CGFloat
    private let swipeDistance: CGFloat
    private let isCircular: Bool
    private var lastAngle: Double?
    private var horizontalSwipe: Bool?

    private(set) var degrees = 0.0
    private(set) var steps = 0

    init(start: CGPoint, center: CGPoint, radius: CGFloat) {
        self.start = start
        self.center = center
        deadZone = radius * 0.33
        swipeDistance = max(12, radius * 0.55)
        if hypot(start.x - center.x, start.y - center.y) >= deadZone {
            lastAngle = atan2(Double(start.y - center.y), Double(start.x - center.x))
        }
        isCircular = lastAngle != nil
    }

    mutating func move(to point: CGPoint) -> Int {
        if isCircular {
            let x = point.x - center.x
            let y = point.y - center.y
            guard hypot(x, y) >= deadZone else {
                lastAngle = nil
                return 0
            }
            let angle = atan2(Double(y), Double(x))
            if let previous = lastAngle {
                let change = angle - previous
                // Keep the change continuous across the -π / +π seam.
                degrees += atan2(sin(change), cos(change)) * 180 / .pi
            }
            lastAngle = angle
        } else {
            let dx = point.x - start.x
            let dy = point.y - start.y
            if horizontalSwipe == nil, dx != 0 || dy != 0 { horizontalSwipe = abs(dx) >= abs(dy) }
            let distance = horizontalSwipe == false ? -dy : dx
            degrees = Double(distance / swipeDistance) * Self.degreesPerStep
        }
        let next = Int((degrees / Self.degreesPerStep).rounded())
        let change = next - steps
        steps = next
        return change
    }
}
