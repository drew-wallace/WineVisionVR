import Foundation

public enum WindowsVRRenderingPreset: String, Codable, Sendable, CaseIterable {
    case automatic
    case m5Quality

    /// Session-fixed logical raster. Never use gaze-dependent physical allocation sizes.
    public func eyeSize(supportsApple10: Bool, baseline: PixelSize) -> PixelSize {
        self == .m5Quality && supportsApple10
            ? PixelSize(width: max(baseline.width, 2048), height: max(baseline.height, 1920))
            : baseline
    }
}

/// Pure timing policy shared by the renderer and host regressions. Presentation
/// timestamps come from CompositorServices, never from guest frame arrival.
public struct WindowsVRDisplayCadence: Sendable {
    public private(set) var period: Double = 1 / 90
    public private(set) var revision: UInt64 = 0
    private var previous: Double?
    private var samples: [Double] = []

    public init() {}

    public mutating func reset() {
        previous = nil
        samples.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    public mutating func observe(presentationTime: Double, tracked: Bool) {
        guard tracked, presentationTime.isFinite else { reset(); return }
        defer { previous = presentationTime }
        guard let previous else { return }
        let interval = presentationTime - previous
        // Missed ticks must not masquerade as a lower refresh rate.
        guard interval >= 0.007, interval <= 0.014 else { reset(); return }
        samples.append(interval)
        if samples.count > 8 { samples.removeFirst() }
        guard samples.count >= 4 else { return }
        let median = samples.sorted()[samples.count / 2]
        if abs(median - period) / period > 0.03 {
            period = median
            revision &+= 1
        }
    }
}

public struct WindowsVRAdaptiveSynthesis: Sendable {
    public private(set) var engaged = false
    public private(set) var pacingLocked = false
    public private(set) var engagements: UInt64 = 0
    public var medianInterval: Double? {
        intervals.count >= 4 ? intervals.sorted()[intervals.count / 2] : nil
    }
    private var intervals: [Double] = []
    private var lastReal: Double?
    private var belowSince: Double?
    private var aboveSince: Double?
    private var emptyTicks = 0

    public init() {}
    public mutating func reset() {
        engaged = false; pacingLocked = false
        intervals.removeAll(keepingCapacity: true)
        lastReal = nil; belowSince = nil; aboveSince = nil; emptyTicks = 0
    }

    public mutating func tick(hasNewFrame: Bool, now: Double, period: Double,
                              forecastReliable: Bool) -> Bool {
        guard now.isFinite, period.isFinite, period > 0 else { reset(); return false }
        if let lastReal, now < lastReal || now - lastReal > 0.25 { reset() }
        if hasNewFrame {
            if let lastReal {
                let delta = now - lastReal
                if delta > 0.001 && delta < 0.25 {
                    intervals.append(delta)
                    if intervals.count > 16 { intervals.removeFirst() }
                }
            }
            lastReal = now; emptyTicks = 0
        } else { emptyTicks += 1 }
        if let interval = medianInterval {
            let ratio = period / interval
            if !engaged {
                if ratio < 85.0 / 90.0 {
                    belowSince = belowSince ?? now
                    if now - belowSince! >= 1 {
                        engaged = true; engagements &+= 1; belowSince = nil
                    }
                } else { belowSince = nil }
            } else if ratio >= 88.0 / 90.0 {
                aboveSince = aboveSince ?? now
                if now - aboveSince! >= 2 { engaged = false; aboveSince = nil }
            } else { aboveSince = nil }
        }
        pacingLocked = engaged && intervals.count == 16 &&
            intervals.allSatisfy { (1.8...2.25).contains($0 / period) }
        guard engaged, !hasNewFrame, forecastReliable,
              let interval = medianInterval, let lastReal,
              now - lastReal <= interval else { return false }
        return !pacingLocked || emptyTicks % 2 != 0
    }
}
