import Foundation
import CoreGraphics

/// Window presentation is profile metadata, never part of the guest/plugin manifest.
public enum WindowsDesktopAspectRatio: String, Codable, Sendable, CaseIterable {
    case automatic, desktop, fourThree, sixteenNine, sixteenTen, ultrawide

    public var title: String {
        switch self {
        case .automatic: L("Automatic", "Automatisch")
        case .desktop: L("Whole desktop", "Gesamter Desktop")
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .sixteenTen: "16:10"
        case .ultrawide: "21:9"
        }
    }

    public var fixedRatio: Double? {
        switch self {
        case .automatic, .desktop: nil
        case .fourThree: 4 / 3
        case .sixteenNine: 16 / 9
        case .sixteenTen: 16 / 10
        case .ultrawide: 21 / 9
        }
    }

    public var initialDisplaySize: CGSize {
        switch self {
        case .fourThree: CGSize(width: 1440, height: 1080)
        case .sixteenTen: CGSize(width: 1920, height: 1200)
        case .ultrawide: CGSize(width: 2520, height: 1080)
        default: CGSize(width: 1920, height: 1080)
        }
    }
}

public enum WindowsDesktopPresentation {
    /// Reframe the compositor so the selected client fits the viewport. Applying
    /// the same affine transform to its frame preserves native input mapping.
    public static func compositorFrame(current: CGRect, client: CGRect, viewport: CGRect) -> CGRect? {
        let rects = [current, client, viewport]
        guard rects.allSatisfy({ r in
            [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0
        }) else { return nil }
        let scale = min(viewport.width / client.width, viewport.height / client.height)
        let target = CGRect(x: viewport.midX - client.width * scale / 2,
                            y: viewport.midY - client.height * scale / 2,
                            width: client.width * scale, height: client.height * scale)
        return CGRect(x: target.minX + (current.minX - client.minX) * scale,
                      y: target.minY + (current.minY - client.minY) * scale,
                      width: current.width * scale, height: current.height * scale)
    }
}
