import CoreGraphics
import Foundation
import XCTest
@testable import WindowsVRCore

final class DesktopPresentationTests: XCTestCase {
    func testLegacyProfileAndAllOverridesRoundTripWithoutChangingManifest() throws {
        let manifest = try WindowsGameManifest(id: "sample", title: "Sample", executableRelativePath: "game.exe",
            backend: .windowsWineFEX, graphics: .direct3D11, launchArguments: [], schemaVersion: 1)
        for aspect in WindowsDesktopAspectRatio.allCases {
            let profile = try WindowsVRLaunchProfile(name: "Display", backend: .windowsWineFEX,
                graphics: .direct3D11, launchArguments: [], desktopAspectRatio: aspect)
            let data = try JSONEncoder().encode(profile)
            XCTAssertEqual(try JSONDecoder().decode(WindowsVRLaunchProfile.self, from: data).desktopAspectRatio, aspect)
            XCTAssertEqual(try profile.applying(to: manifest).environment, [:])
            var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            old.removeValue(forKey: "desktopAspectRatio")
            XCTAssertEqual(try JSONDecoder().decode(WindowsVRLaunchProfile.self,
                from: JSONSerialization.data(withJSONObject: old)).desktopAspectRatio, .automatic)
        }
        XCTAssertEqual(WindowsDesktopAspectRatio.automatic.initialDisplaySize, CGSize(width: 1920, height: 1080))
    }

    func testSteamProfilesDoNotShareTheLaunchHostIdentity() throws {
        func manifest(_ title: String) throws -> WindowsGameManifest {
            try WindowsGameManifest(id: "steam.shared", title: title, executableRelativePath: "AVPPlaySteam/dockhost.exe",
                backend: .windowsWineFEX, graphics: .direct3D11, launchArguments: [], schemaVersion: 1)
        }
        let first = try manifest("Game A"), second = try manifest("Game B")
        let entry = WindowsVRLibraryEntry(manifest: first, folderBookmark: Data([1]), profiles: [],
            selectedProfileID: nil, steamAppID: 123)
        XCTAssertTrue(entry.matchesGame(first, steamAppID: 123))
        XCTAssertFalse(entry.matchesGame(second, steamAppID: 456))
        XCTAssertFalse(entry.matchesGame(first, steamAppID: 456))
        XCTAssertFalse(entry.matchesGame(first, steamAppID: nil))
        var legacy = entry
        legacy.steamAppID = nil
        XCTAssertTrue(legacy.matchesGame(first, steamAppID: 123))
        XCTAssertFalse(legacy.matchesGame(second, steamAppID: 456))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "steamAppID")
        XCTAssertNil(try JSONDecoder().decode(WindowsVRLibraryEntry.self,
            from: JSONSerialization.data(withJSONObject: json)).steamAppID)
    }

    func testReframingRemovesDesktopPaddingAndPreservesInputCoordinates() throws {
        // 16:9 and 4:3 games, portrait, ultrawide, non-zero window origins,
        // and a fixed-ratio viewport that deliberately retains letterboxing.
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 800, height: 600),
                     CGSize(width: 1080, height: 1920), CGSize(width: 3440, height: 1440)] {
            let current = CGRect(x: 20, y: 30, width: 1200, height: 900)
            let client = CGRect(x: 60, y: 140, width: size.width / 2, height: size.height / 2)
            for viewport in [CGRect(x: 20, y: 30, width: 1000, height: 1000 * size.height / size.width),
                             CGRect(x: 20, y: 30, width: 1280, height: 720)] {
                let frame = try XCTUnwrap(WindowsDesktopPresentation.compositorFrame(current: current, client: client, viewport: viewport))
                let scale = frame.width / current.width
                let transformed = CGRect(x: frame.minX + (client.minX - current.minX) * scale,
                                         y: frame.minY + (client.minY - current.minY) * scale,
                                         width: client.width * scale, height: client.height * scale)
                XCTAssertEqual(transformed.midX, viewport.midX, accuracy: 0.0001)
                XCTAssertEqual(transformed.midY, viewport.midY, accuracy: 0.0001)
                XCTAssertLessThanOrEqual(transformed.width, viewport.width + 0.0001)
                XCTAssertLessThanOrEqual(transformed.height, viewport.height + 0.0001)
                for x in [0.0, 0.25, 0.5, 1.0] {
                    for y in [0.0, 0.25, 0.5, 1.0] {
                        // Native point -> guest mapping uses this same transformed rectangle.
                        let point = CGPoint(x: transformed.minX + transformed.width * x,
                                            y: transformed.minY + transformed.height * y)
                        XCTAssertEqual((point.x - transformed.minX) / transformed.width, x, accuracy: 0.0001)
                        XCTAssertEqual((point.y - transformed.minY) / transformed.height, y, accuracy: 0.0001)
                    }
                }
                let repeated = try XCTUnwrap(WindowsDesktopPresentation.compositorFrame(current: frame, client: transformed, viewport: viewport))
                XCTAssertEqual(repeated.minX, frame.minX, accuracy: 0.0001)
                XCTAssertEqual(repeated.minY, frame.minY, accuracy: 0.0001)
                XCTAssertEqual(repeated.width, frame.width, accuracy: 0.0001)
                XCTAssertEqual(repeated.height, frame.height, accuracy: 0.0001)
            }
        }
        XCTAssertNil(WindowsDesktopPresentation.compositorFrame(current: .zero, client: .zero, viewport: .zero))
    }
}
