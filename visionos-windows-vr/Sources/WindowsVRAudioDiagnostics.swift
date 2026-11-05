import AVFAudio
import Foundation
import UIKit

/// Audio-session observation and system-recommended recovery during playback.
@MainActor
enum WindowsVRAudioDiagnostics {
    private static var observers: [NSObjectProtocol] = []
    private static var runtimeIsRunning: @MainActor () -> Bool = { false }
    private static let recovery = WindowsVRAudioRecoveryCoordinator(
        runtimeIsRunning: { runtimeIsRunning() },
        canRecover: { UIApplication.shared.applicationState != .background },
        activate: {
            try configureSpatialExperience(immersive: immersiveAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        },
        restart: {
            await Task.detached(priority: .userInitiated) { wvr_audio_output_reset_v1() }.value
        },
        report: { snapshot($0) })

    private static var immersiveAudio = false

    static func configureSpatialExperience(immersive: Bool) throws {
        let audio = AVAudioSession.sharedInstance()
        if immersive { try audio.setIntendedSpatialExperience(.bypassed) }
        else {
            try audio.setIntendedSpatialExperience(.headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        immersiveAudio = immersive
    }

    static func start(runtimeIsRunning: @escaping @MainActor () -> Bool) {
        self.runtimeIsRunning = runtimeIsRunning
        guard observers.isEmpty else { return }
        let foreground = UIApplication.shared.applicationState != .background
        Task { @MainActor in await recovery.handle(.foreground(foreground)) }
        let events: [(Notification.Name, String)] = [
            (AVAudioSession.routeChangeNotification, "route-change"),
            (AVAudioSession.didBecomeActiveNotification, "became-active"),
            (AVAudioSession.didBecomeInactiveNotification, "became-inactive"),
            (AVAudioSession.resumptionRecommendationNotification, "resumption-recommendation"),
            (AVAudioSession.mediaServicesWereLostNotification, "media-services-lost"),
            (AVAudioSession.mediaServicesWereResetNotification, "media-services-reset"),
            (UIApplication.didEnterBackgroundNotification, "application-background"),
            (UIApplication.willEnterForegroundNotification, "application-foreground"),
            (UIApplication.didBecomeActiveNotification, "application-active")
        ]
        for (name, label) in events {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                let observedUptime = ProcessInfo.processInfo.systemUptime
                // Copy only numeric event fields across the actor boundary;
                // port names and other user/device identifiers are unnecessary.
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                let source = (notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext)?.source.rawValue
                let recommendation = (notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext)?.recommendation.rawValue
                let transition: WindowsVRAudioRecoveryCoordinator.Event?
                switch name {
                case AVAudioSession.didBecomeInactiveNotification: transition = .deactivated
                case AVAudioSession.didBecomeActiveNotification: transition = .activated
                case AVAudioSession.resumptionRecommendationNotification:
                    transition = .resumptionRecommended(recommendation == AVAudioSession.ResumptionRecommendation.shouldResume.rawValue)
                case UIApplication.didEnterBackgroundNotification: transition = .foreground(false)
                case UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification:
                    transition = .foreground(true)
                default: transition = nil
                }
                let event = "\(label) reason=\(reason.map(String.init) ?? "-") source=\(source.map(String.init) ?? "-") resumption=\(recommendation.map(String.init) ?? "-")"
                Task { @MainActor in
                    let deliveryMS = (ProcessInfo.processInfo.systemUptime - observedUptime) * 1_000
                    snapshot("\(event) delivery-delay=\(deliveryMS)ms")
                    if let transition { await recovery.handle(transition) }
                }
            })
        }
    }

    static func resetOutput(reason: String) async -> Bool {
        await recovery.resetOutput(reason: reason)
    }

    static func snapshot(_ event: String) {
        let audio = AVAudioSession.sharedInstance()
        let outputs = audio.currentRoute.outputs.map {
            "\($0.portType.rawValue):\($0.channels?.count ?? 0)ch"
        }.joined(separator: ",")
        LaunchLog().notice("Audio diagnostic: \(event); uptime=\(ProcessInfo.processInfo.systemUptime)s app-state=\(UIApplication.shared.applicationState.rawValue) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) category=\(audio.category.rawValue) mode=\(audio.mode.rawValue) options=\(audio.categoryOptions.rawValue) rate=\(audio.sampleRate)Hz io=\(audio.ioBufferDuration)s latency=\(audio.outputLatency)s outputs=[\(outputs)] otherAudio=\(audio.isOtherAudioPlaying)")
    }

    static func control(_ name: String, send: () -> Void) {
        snapshot("before \(name)")
        send()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            snapshot("after \(name)")
        }
    }
}
