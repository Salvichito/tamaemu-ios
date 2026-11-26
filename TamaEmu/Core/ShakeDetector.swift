import CoreMotion
import Foundation

/// Turns a sharp jolt of the phone into one "tap" on a first-gen toy's tap
/// sensor (see V1IconProfile.hasTapSensor). The Angel, Morino and Umino
/// have a small sensor inside the shell that notices taps and shakes; you
/// use it to scare off bats and predators.
///
/// Battery: the motion sensor only runs while a sensor model's page is on
/// screen and live (V1PageView starts and stops it), at 30 samples a
/// second, and nothing else is computed.
@MainActor
final class ShakeDetector {
    /// One shared manager, as Apple recommends: several running at once
    /// slow down how fast each gets its readings.
    private static let manager = CMMotionManager()

    /// Acceleration on top of gravity, in g. Walking or turning the phone
    /// over stays well under 1 g; a deliberate shake or a knock on the
    /// case passes 1.3 g.
    private static let threshold = 1.3
    /// One shake swings back and forth several times; count it once.
    private static let cooldown: TimeInterval = 0.5

    private var lastJolt = Date.distantPast
    private var running = false

    func start(onShake: @escaping @MainActor () -> Void) {
        let manager = Self.manager
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let a = motion?.userAcceleration else { return }
            let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let now = Date()
            guard g > Self.threshold, now.timeIntervalSince(self.lastJolt) > Self.cooldown else { return }
            self.lastJolt = now
            onShake()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        Self.manager.stopDeviceMotionUpdates()
    }
}
