import AVFAudio
import Foundation
import UIKit

// The actual notification observer and coordinator run on visionOS. Substitute
// only the runtime reset, so this fixture never boots Wine or plays game audio.
private final class NativeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private let nativeCalls = NativeCalls()
func wvr_audio_output_reset_v1() -> Int32 { nativeCalls.increment(); return 0 }
@MainActor private final class RuntimeState { var running = true }

@main
struct SimulatorAudioLifecycleProbe {
    @MainActor
    static func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    @MainActor
    static func main() async throws {
        let state = RuntimeState()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: .mixWithOthers)
        try WindowsVRAudioDiagnostics.configureSpatialExperience(immersive: true)
        assert(session.intendedSpatialExperience is AVAudioSession.BypassedSpatialExperience,
               "VR audio must bypass the system's window anchoring")
        try WindowsVRAudioDiagnostics.configureSpatialExperience(immersive: false)
        assert(session.intendedSpatialExperience is AVAudioSession.HeadTrackedSpatialExperience,
               "Desktop audio retains system spatialization")
        try WindowsVRAudioDiagnostics.configureSpatialExperience(immersive: true)
        try session.setActive(true)
        WindowsVRAudioDiagnostics.start { state.running }
        WindowsVRAudioDiagnostics.start { state.running } // Observer installation is idempotent.
        try await settle()
        assert(nativeCalls.count == 0)
        let center = NotificationCenter.default
        center.post(name: AVAudioSession.didBecomeInactiveNotification, object: session)
        center.post(name: AVAudioSession.didBecomeActiveNotification, object: session)
        try await settle()
        assert(nativeCalls.count == 1, "Actual audio-notification wiring must trigger one output restart")

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: AVAudioSession.didBecomeInactiveNotification, object: session)
        center.post(name: AVAudioSession.didBecomeActiveNotification, object: session)
        try await settle()
        assert(nativeCalls.count == 1, "Do not reset while backgrounded")
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await settle()
        assert(nativeCalls.count == 2, "Foreground must deliver the pending actual reactivation")

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await settle()
        assert(nativeCalls.count == 2, "A focus change alone must not restart audio")
        assert(session.intendedSpatialExperience is AVAudioSession.BypassedSpatialExperience,
               "Recovery must preserve immersive audio routing")
        state.running = false
        center.post(name: AVAudioSession.didBecomeInactiveNotification, object: session)
        center.post(name: AVAudioSession.didBecomeActiveNotification, object: session)
        try await settle()
        assert(nativeCalls.count == 2, "A stopped runtime must not restart audio")
        try session.setActive(false)
        print("PASS visionOS notification wiring, idempotent observers, background deferral, focus-only exclusion and stopped runtime (native output restart stubbed)")
    }
}
