@MainActor
private final class Fixture {
    var running = true
    var foregroundAtCall = true
    var activations = 0
    var restarts = 0
    var result: Int32 = 0
    var activationFails = false
    var duringRestart: (@MainActor () async -> Void)?
    var reports: [String] = []
    enum Failure: Error { case activation }
    lazy var coordinator = WindowsVRAudioRecoveryCoordinator(
        runtimeIsRunning: { self.running },
        canRecover: { self.foregroundAtCall },
        activate: {
            self.activations += 1
            if self.activationFails { throw Failure.activation }
        },
        restart: {
            self.restarts += 1
            if let action = self.duringRestart {
                self.duringRestart = nil
                await action()
            }
            return self.result
        },
        report: { self.reports.append($0) })
}

@main
struct AudioRecoveryCoordinatorTests {
    @MainActor
    static func main() async {
        let activation = Fixture()
        await activation.coordinator.handle(.activated)
        assert(activation.restarts == 0, "Initial activation must not reset an uncreated unit")
        await activation.coordinator.handle(.foreground(false))
        await activation.coordinator.handle(.foreground(true))
        assert(activation.restarts == 0, "Focus/lifecycle alone must not reset playback")
        await activation.coordinator.handle(.deactivated)
        assert(activation.restarts == 0 && activation.activations == 0)
        await activation.coordinator.handle(.activated)
        assert(activation.restarts == 1 && activation.activations == 0,
               "Actual reactivation must rebuild output without reactivating the session")
        await activation.coordinator.handle(.resumptionRecommended(true))
        await activation.coordinator.handle(.activated)
        assert(activation.restarts == 1, "Activation and recommendation must coalesce")

        let recommendation = Fixture()
        await recommendation.coordinator.handle(.resumptionRecommended(true))
        assert(recommendation.activations == 1 && recommendation.restarts == 1,
               "A recommendation without an observed deactivation must still resume")

        let background = Fixture()
        await background.coordinator.handle(.deactivated)
        await background.coordinator.handle(.foreground(false))
        await background.coordinator.handle(.resumptionRecommended(true))
        assert(background.activations == 0 && background.restarts == 0,
               "Do not activate a background app's audio session")
        await background.coordinator.handle(.foreground(true))
        assert(background.activations == 1 && background.restarts == 1)

        let delayedBackgroundNotification = Fixture()
        delayedBackgroundNotification.foregroundAtCall = false
        await delayedBackgroundNotification.coordinator.handle(.deactivated)
        await delayedBackgroundNotification.coordinator.handle(.resumptionRecommended(true))
        assert(delayedBackgroundNotification.restarts == 0 && delayedBackgroundNotification.activations == 0,
               "Check actual foreground state even before its notification arrives")
        delayedBackgroundNotification.foregroundAtCall = true
        await delayedBackgroundNotification.coordinator.handle(.foreground(true))
        assert(delayedBackgroundNotification.restarts == 1)

        let denied = Fixture()
        await denied.coordinator.handle(.deactivated)
        await denied.coordinator.handle(.resumptionRecommended(false))
        await denied.coordinator.handle(.foreground(false))
        await denied.coordinator.handle(.foreground(true))
        assert(denied.activations == 0 && denied.restarts == 0,
               "Foregrounding must not override shouldNotResume")
        await denied.coordinator.handle(.activated)
        assert(denied.restarts == 1 && denied.activations == 0)

        let stopped = Fixture()
        await stopped.coordinator.handle(.deactivated)
        stopped.running = false
        await stopped.coordinator.handle(.activated)
        await stopped.coordinator.handle(.resumptionRecommended(true))
        assert(stopped.activations == 0 && stopped.restarts == 0)
        stopped.running = true
        await stopped.coordinator.handle(.activated)
        assert(stopped.restarts == 0, "An old game's interruption must not reset a later game")

        let failure = Fixture()
        failure.result = -10867
        await failure.coordinator.handle(.deactivated)
        await failure.coordinator.handle(.activated)
        await failure.coordinator.handle(.activated)
        await failure.coordinator.handle(.resumptionRecommended(true))
        assert(failure.restarts == 1, "A failed recovery must not create an automatic retry loop")
        failure.result = 0
        let retry = await failure.coordinator.resetOutput(reason: "desktop control")
        assert(retry && failure.restarts == 2 && failure.activations == 1)

        let activationFailure = Fixture()
        activationFailure.activationFails = true
        await activationFailure.coordinator.handle(.deactivated)
        await activationFailure.coordinator.handle(.resumptionRecommended(true))
        assert(activationFailure.activations == 1 && activationFailure.restarts == 0,
               "Failed activation must not restart the output")

        let overlap = Fixture()
        overlap.duringRestart = {
            let duplicate = await overlap.coordinator.resetOutput(reason: "desktop control")
            assert(!duplicate, "Two native output restarts must not overlap")
            await overlap.coordinator.handle(.deactivated)
            await overlap.coordinator.handle(.activated)
        }
        await overlap.coordinator.handle(.deactivated)
        await overlap.coordinator.handle(.activated)
        assert(overlap.restarts == 2 && overlap.activations == 0,
               "An interruption during recovery must survive the earlier completion")
        print("PASS: reactivation, recommendation order, foreground deferral, denied resumption, stopped runtime, failures, manual retry and interruption during recovery")
    }
}
