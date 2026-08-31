import Foundation
import simd

enum AutoTourPolicy: Equatable {
    case enabled
    case reduceMotion
    case disabled

    static func launch(
        automationRequested: Bool,
        hasQAMode: Bool,
        hasStartupError: Bool,
        reduceMotion: Bool,
        hasMetalDevice: Bool = true
    ) -> Self {
        if automationRequested || hasQAMode || hasStartupError || !hasMetalDevice {
            return .disabled
        }
        return reduceMotion ? .reduceMotion : .enabled
    }
}

enum AutoTourState: Equatable {
    case disabled
    case active
    case userControlled
}

struct AutoTourSample: Equatable {
    let cameraPosition: SIMD3<Float>
    let lookAtTarget: SIMD3<Float>
    let evidenceView: EvidenceView
    let sectionID: Int
    let sectionTitle: String

    var yaw: Float {
        let direction = lookAtTarget - cameraPosition
        return atan2(direction.x, direction.z)
    }

    var pitch: Float {
        let direction = lookAtTarget - cameraPosition
        let length = simd_length(direction)
        guard length > 0 else { return .nan }
        return asin(min(1, max(-1, direction.y / length)))
    }

    var isValid: Bool {
        return cameraPosition.x.isFinite
            && cameraPosition.y.isFinite
            && cameraPosition.z.isFinite
            && lookAtTarget.x.isFinite
            && lookAtTarget.y.isFinite
            && lookAtTarget.z.isFinite
            && yaw.isFinite
            && pitch.isFinite
            && simd_length(lookAtTarget - cameraPosition) > 0.001
    }
}

struct AutoTourTimeline {
    private struct Waypoint {
        let time: TimeInterval
        let cameraPosition: SIMD3<Float>
        let lookAtTarget: SIMD3<Float>
        let evidenceView: EvidenceView
        let sectionTitle: String
    }

    let duration: TimeInterval = 96

    // An island walk. Camera x/z follows these stations; the y stored here is
    // informational — sample() re-grounds the camera on TerrainField each
    // frame so the tour rides the terrain at eye level. Look targets reference
    // live scene content: the sea plane (y 52), creature centers and shroom
    // cluster centers from SceneData.makeHero, and the warm sky window
    // azimuth (sun bearing ~ -2.75 rad).
    private static let waypoints = [
        Waypoint(
            time: 0,
            cameraPosition: SIMD3<Float>(282, 60.7, 158),
            lookAtTarget: SIMD3<Float>(255, 52.5, 135),
            evidenceView: .final,
            sectionTitle: "THE SHORE"
        ),
        Waypoint(
            time: 12,
            cameraPosition: SIMD3<Float>(266, 62, 152),
            lookAtTarget: SIMD3<Float>(238, 52.5, 148),
            evidenceView: .final,
            sectionTitle: "ALONG THE WATER"
        ),
        Waypoint(
            time: 24,
            cameraPosition: SIMD3<Float>(252, 95.3, 252),
            lookAtTarget: SIMD3<Float>(262.5, 92, 297.5),
            evidenceView: .final,
            sectionTitle: "SOMETHING IN THE FOG"
        ),
        Waypoint(
            time: 36,
            cameraPosition: SIMD3<Float>(255, 83.6, 272),
            lookAtTarget: SIMD3<Float>(288, 96, 311),
            evidenceView: .final,
            sectionTitle: "THE WATCHERS"
        ),
        Waypoint(
            time: 48,
            cameraPosition: SIMD3<Float>(290, 92.6, 268),
            lookAtTarget: SIMD3<Float>(274, 80.5, 278),
            evidenceView: .final,
            sectionTitle: "THE GLOW BELOW"
        ),
        Waypoint(
            time: 60,
            cameraPosition: SIMD3<Float>(279, 85.8, 273),
            lookAtTarget: SIMD3<Float>(250, 87.5, 284),
            evidenceView: .final,
            sectionTitle: "AMONG THE LANTERNS"
        ),
        Waypoint(
            time: 72,
            cameraPosition: SIMD3<Float>(306, 95.2, 289),
            lookAtTarget: SIMD3<Float>(291, 107, 252),
            evidenceView: .final,
            sectionTitle: "THE RIDGE"
        ),
        Waypoint(
            time: 84,
            cameraPosition: SIMD3<Float>(295, 79, 225),
            lookAtTarget: SIMD3<Float>(282, 53, 160),
            evidenceView: .final,
            sectionTitle: "BACK TO THE SEA"
        ),
    ]

    func sample(at elapsedTime: TimeInterval) -> AutoTourSample {
        guard elapsedTime.isFinite else {
            return AutoTourSample(
                cameraPosition: SIMD3<Float>(repeating: .nan),
                lookAtTarget: SIMD3<Float>(repeating: .nan),
                evidenceView: .final,
                sectionID: 0,
                sectionTitle: Self.waypoints[0].sectionTitle
            )
        }
        let remainder = elapsedTime.truncatingRemainder(dividingBy: duration)
        let time = remainder < 0 ? remainder + duration : remainder
        var sectionID = 0
        for index in 1..<Self.waypoints.count where Self.waypoints[index].time <= time {
            sectionID = index
        }
        let nextID = (sectionID + 1) % Self.waypoints.count
        let previousID = (sectionID + Self.waypoints.count - 1) % Self.waypoints.count
        let followingID = (nextID + 1) % Self.waypoints.count
        let startTime = Self.waypoints[sectionID].time
        let endTime = nextID == 0 ? duration : Self.waypoints[nextID].time
        let fraction = Float((time - startTime) / (endTime - startTime))
        let eased = fraction * fraction * (3 - 2 * fraction)
        let waypoint = Self.waypoints[sectionID]

        var cameraPosition = catmullRom(
            Self.waypoints[previousID].cameraPosition,
            waypoint.cameraPosition,
            Self.waypoints[nextID].cameraPosition,
            Self.waypoints[followingID].cameraPosition,
            t: eased
        )
        cameraPosition.y = TerrainField.smoothHeight(x: cameraPosition.x, z: cameraPosition.z) + 1.8
        return AutoTourSample(
            cameraPosition: cameraPosition,
            lookAtTarget: catmullRom(
                Self.waypoints[previousID].lookAtTarget,
                waypoint.lookAtTarget,
                Self.waypoints[nextID].lookAtTarget,
                Self.waypoints[followingID].lookAtTarget,
                t: eased
            ),
            evidenceView: waypoint.evidenceView,
            sectionID: sectionID,
            sectionTitle: waypoint.sectionTitle
        )
    }

    private func catmullRom(
        _ p0: SIMD3<Float>,
        _ p1: SIMD3<Float>,
        _ p2: SIMD3<Float>,
        _ p3: SIMD3<Float>,
        t: Float
    ) -> SIMD3<Float> {
        let t2 = t * t
        let t3 = t2 * t
        let linear = (p2 - p0) * t
        let quadraticVector = p0 * 2 - p1 * 5 + p2 * 4 - p3
        let cubicVector = -p0 + p1 * 3 - p2 * 3 + p3
        let quadratic = quadraticVector * t2
        let cubic = cubicVector * t3
        return (p1 * 2 + linear + quadratic + cubic) * 0.5
    }
}

struct AutoTourController {
    let policy: AutoTourPolicy
    private(set) var state: AutoTourState
    private(set) var lastSample: AutoTourSample?
    private(set) var failure: String?

    private let timeline = AutoTourTimeline()
    private var startTime: TimeInterval

    init(policy: AutoTourPolicy, startTime: TimeInterval) {
        self.policy = policy
        self.startTime = startTime
        state = policy == .enabled ? .active : .disabled
        lastSample = policy == .enabled ? timeline.sample(at: 0) : nil
    }

    mutating func sample(at time: TimeInterval) -> AutoTourSample? {
        guard state == .active else { return nil }
        let sample = timeline.sample(at: time - startTime)
        guard sample.isValid else {
            state = .userControlled
            failure = "AUTO TOUR STOPPED · INVALID CAMERA SAMPLE"
            return nil
        }
        lastSample = sample
        return sample
    }

    mutating func takeControl() -> AutoTourSample? {
        guard state == .active else { return nil }
        state = .userControlled
        return lastSample
    }

    mutating func takeFailure() -> String? {
        defer { failure = nil }
        return failure
    }

    mutating func restart(at time: TimeInterval) -> AutoTourSample? {
        guard policy == .enabled else { return nil }
        startTime = time
        state = .active
        failure = nil
        let sample = timeline.sample(at: 0)
        guard sample.isValid else {
            state = .userControlled
            failure = "AUTO TOUR STOPPED · INVALID CAMERA SAMPLE"
            return nil
        }
        lastSample = sample
        return sample
    }
}
