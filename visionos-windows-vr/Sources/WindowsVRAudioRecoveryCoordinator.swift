/// Coordinates actual audio-session transitions independently of window focus.
/// An activation following deactivation needs to rebuild the runtime output,
/// even when the system does not also send a resumption recommendation.
@MainActor
final class WindowsVRAudioRecoveryCoordinator {
    enum Event: Sendable {
        case deactivated
        case activated
        case resumptionRecommended(Bool)
        case foreground(Bool)
        case playbackRequested
    }

    private let runtimeIsRunning: @MainActor () -> Bool
    private let canRecover: @MainActor () -> Bool
    private let activate: @MainActor () throws -> Void
    private let restart: @MainActor () async -> Int32
    private let report: @MainActor (String) -> Void
    private var isForeground = true
    private var sessionActive = true
    private var resumeAllowed = false
    private var pending = false
    private var generation: UInt64 = 0
    private var attemptedGeneration: UInt64?
    private var inProgress = false

    var needsPlaybackRecovery: Bool { pending && !inProgress && attemptedGeneration != generation }

    init(runtimeIsRunning: @escaping @MainActor () -> Bool,
         canRecover: @escaping @MainActor () -> Bool = { true },
         activate: @escaping @MainActor () throws -> Void,
         restart: @escaping @MainActor () async -> Int32,
         report: @escaping @MainActor (String) -> Void) {
        self.runtimeIsRunning = runtimeIsRunning
        self.canRecover = canRecover
        self.activate = activate
        self.restart = restart
        self.report = report
    }

    func handle(_ event: Event) async {
        switch event {
        case .deactivated:
            generation &+= 1
            pending = runtimeIsRunning()
            sessionActive = false
            resumeAllowed = false
        case .activated:
            sessionActive = true
        case .resumptionRecommended(let allowed):
            resumeAllowed = allowed
            sessionActive = false
            // Preserve resumption even if observation began after deactivation.
            // An already attempted generation still coalesces the later notice.
            if allowed { pending = runtimeIsRunning() }
        case .foreground(let foreground):
            isForeground = foreground
        case .playbackRequested:
            // Explicitly returning to/using the game is a new playback request.
            // Some other apps deactivate us without ever sending a resumption
            // recommendation. Do not leave that session permanently silent.
            // Activation can still fail while a higher-priority call owns audio;
            // keep manual Reset audio available rather than retrying every input.
            guard runtimeIsRunning() else { pending = false; return }
            guard isForeground, needsPlaybackRecovery else { return }
            _ = await performReset(reason: "game playback requested", requestActivation: true)
            return
        }
        await recoverIfNeeded()
    }

    func resetOutput(reason: String) async -> Bool {
        await performReset(reason: reason, requestActivation: true)
    }

    private func performReset(reason: String, requestActivation: Bool) async -> Bool {
        guard runtimeIsRunning(), canRecover(), !inProgress else { return false }
        inProgress = true
        let startedGeneration = generation
        attemptedGeneration = startedGeneration
        let success: Bool
        do {
            // An actual activation notification already established the active
            // session. Manual recovery still explicitly requests activation.
            if requestActivation { try activate() }
            let status = await restart()
            success = status == 0
            report("output reset reason=\(reason) status=\(status) generation=\(startedGeneration)")
        } catch {
            success = false
            report("output reset reason=\(reason) activation failed: \(error)")
        }
        if success && generation == startedGeneration { pending = false }
        inProgress = false
        // An interruption during the await belongs to a new recovery cycle.
        // It must not be erased by the older operation finishing successfully.
        if generation != startedGeneration { await recoverIfNeeded() }
        return success
    }

    private func recoverIfNeeded() async {
        guard runtimeIsRunning() else { pending = false; return }
        guard isForeground, canRecover(), pending, !inProgress,
              attemptedGeneration != generation, sessionActive || resumeAllowed else { return }
        _ = await performReset(reason: sessionActive ? "session reactivated" : "system resumption",
                               requestActivation: !sessionActive)
    }
}
