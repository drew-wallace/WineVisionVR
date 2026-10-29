import Foundation
import Metal
import WindowsVRCore

/// Snapshot used by launch policy and journals. Capability is not a benchmark.
struct WindowsVRHardwareCapabilities: Codable, Sendable {
    let deviceName: String
    let appleGPUFamily: Int
    let supportsRaytracing: Bool
    let supportsFoveation: Bool
    let physicalMemoryBytes: UInt64
    let recommendedGPUWorkingSetBytes: UInt64
    let tensorReconstructionCandidate: Bool
    let automaticReconstructionBackend: String
    let metalFXTemporalAvailable: Bool

    static let current = detect(MTLCreateSystemDefaultDevice())

    static func detect(_ device: (any MTLDevice)?) -> Self {
        let family = (1...10).reversed().first {
            guard let gpuFamily = MTLGPUFamily(rawValue: 1000 + $0) else { return false }
            return device?.supportsFamily(gpuFamily) == true
        } ?? 0
        return Self(deviceName: device?.name ?? "unavailable", appleGPUFamily: family,
                    supportsRaytracing: device?.supportsRaytracing ?? false,
                    supportsFoveation: device?.supportsRasterizationRateMap(layerCount: 1) ?? false,
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                    recommendedGPUWorkingSetBytes: device?.recommendedMaxWorkingSetSize ?? 0,
                    tensorReconstructionCandidate: family >= 10,
                    automaticReconstructionBackend: "existing-metal-kernels",
                    metalFXTemporalAvailable: false)
    }
}

/// Published before opening the immersive space; immutable for the session.
/// A lock permits the compositor's dedicated executor to read the launch snapshot.
enum WindowsVRLaunchRendering {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var size: PixelSize?
    }
    private static let storage = Storage()
    static func resolve(preset: WindowsVRRenderingPreset) -> PixelSize {
        let baseline = PixelSize(
            width: max(1, Bundle.main.object(forInfoDictionaryKey: "WVRUniformEyeWidth") as? Int ?? 1888),
            height: max(1, Bundle.main.object(forInfoDictionaryKey: "WVRUniformEyeHeight") as? Int ?? 1792))
        return preset.eyeSize(supportsApple10: WindowsVRHardwareCapabilities.current.appleGPUFamily >= 10,
                              baseline: baseline)
    }
    static func configure(preset: WindowsVRRenderingPreset) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.size = resolve(preset: preset)
    }
    static var eyeSize: PixelSize {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.size ?? resolve(preset: .automatic)
    }
}
