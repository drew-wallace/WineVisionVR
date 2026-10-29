import XCTest
@testable import WindowsVRCore

final class PerformancePolicyTests: XCTestCase {
    func testCadencesAndMissedTicks() {
        for hz in [90.0, 96, 100, 120] {
            var cadence = WindowsVRDisplayCadence()
            var time = 1.0
            for _ in 0..<20 { cadence.observe(presentationTime: time, tracked: true); time += 1 / hz }
            XCTAssertEqual(cadence.period, 1 / hz, accuracy: 0.00001)
            let revision = cadence.revision
            cadence.observe(presentationTime: time + 1 / hz, tracked: true)
            XCTAssertEqual(cadence.period, 1 / hz, accuracy: 0.00001)
            XCTAssertGreaterThan(cadence.revision, revision)
            cadence.observe(presentationTime: time + 1, tracked: false)
            XCTAssertEqual(cadence.period, 1 / hz, accuracy: 0.00001)
        }
    }

    func testCadenceTransitions() {
        var cadence = WindowsVRDisplayCadence()
        var time = 1.0
        for hz in [90.0, 120, 96, 100, 90] {
            for _ in 0..<20 { time += 1 / hz; cadence.observe(presentationTime: time, tracked: true) }
            XCTAssertEqual(cadence.period, 1 / hz, accuracy: 0.00001)
        }
    }

    func testSynthesisScalesWithCadenceAndResets() {
        for hz in [90.0, 96, 100, 120] {
            var policy = WindowsVRAdaptiveSynthesis()
            let period = 1 / hz
            for tick in 0..<Int(hz * 2) {
                _ = policy.tick(hasNewFrame: tick % 2 == 0, now: Double(tick) * period,
                                period: period, forecastReliable: true)
            }
            XCTAssertTrue(policy.engaged)
            XCTAssertTrue(policy.pacingLocked)
            XCTAssertEqual(policy.medianInterval!, period * 2, accuracy: 0.00001)
            // A stalled game must stop extrapolation and discard its history.
            XCTAssertFalse(policy.tick(hasNewFrame: false, now: 3, period: period, forecastReliable: true))
            XCTAssertFalse(policy.engaged)
            policy.reset()
            XCTAssertNil(policy.medianInterval)
            for tick in 0..<Int(hz * 2) {
                XCTAssertFalse(policy.tick(hasNewFrame: true, now: 4 + Double(tick) * period,
                                           period: period, forecastReliable: true))
            }
            XCTAssertFalse(policy.engaged)
        }
    }

    func testPresetAndOldProfileCompatibility() throws {
        let baseline = PixelSize(width: 1888, height: 1792)
        XCTAssertEqual(WindowsVRRenderingPreset.automatic.eyeSize(supportsApple10: true, baseline: baseline), baseline)
        XCTAssertEqual(WindowsVRRenderingPreset.m5Quality.eyeSize(supportsApple10: false, baseline: baseline), baseline)
        XCTAssertEqual(WindowsVRRenderingPreset.m5Quality.eyeSize(supportsApple10: true, baseline: baseline), PixelSize(width: 2048, height: 1920))
        // Build legacy JSON from a real profile so enum wire values stay authoritative.
        let profile = try WindowsVRLaunchProfile(name: "Saved", backend: .windowsWineFEX, graphics: .direct3D11, launchArguments: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "renderingPreset")
        let decoded = try JSONDecoder().decode(WindowsVRLaunchProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.renderingPreset)
        var quality = decoded
        quality.renderingPreset = .m5Quality
        XCTAssertEqual(try JSONDecoder().decode(WindowsVRLaunchProfile.self, from: JSONEncoder().encode(quality)), quality)
    }
}
