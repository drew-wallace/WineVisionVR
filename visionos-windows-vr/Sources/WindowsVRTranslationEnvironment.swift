import Foundation

/// Defaults must reach Wine even when the app uses the preserved native plugin.
/// Explicit process/manifest overrides remain available for controlled comparisons.
enum WindowsVRTranslationEnvironment {
    /// Snapshot before applyDefaults writes into the process environment.
    static let inheritedCodeCacheOverride = ProcessInfo.processInfo.environment["FEX_ENABLECODECACHINGWIP"]
    static let inheritedJITPoolOverride = ProcessInfo.processInfo.environment["WVR_JIT_POOL_MIB"]

    static let defaults: [String: String] = [
        "FEX_MULTIBLOCK": "1",
        // Upstream default block size limit.
        "FEX_MAXINST": "5000",
        "FEX_SILENTLOG": "1",
        // Second-level indirect-branch lookup cache before the slow path.
        "FEX_DISABLEL2CACHE": "0",
        "FEX_STACKDERIVEDNONTSO": "1",
        "FEX_THREADLOCALNONTSO": "1",
        // Safe again: patch 0015 publishes the GDI shared table into every
        // child process, so a game spawned by the cache launcher no longer
        // faults in gdi32. Environment overrides can still disable it.
        "FEX_ENABLECODECACHINGWIP": "1",
        "FEX_ENABLELAZYCODECACHINGWIP": "0",
        "FEX_ENABLECODECACHEVALIDATION": "0"
    ]

    static func applyDefaults() {
        _ = inheritedCodeCacheOverride
        _ = inheritedJITPoolOverride
        for (name, value) in defaults where getenv(name) == nil {
            setenv(name, value, 0)
        }
    }

    static func compatibilityEnvironment(steamAppID: Int, base: [String: String] = [:],
                                         inheritedCacheOverride: String?,
                                         inheritedJITPoolOverride: String? = WindowsVRTranslationEnvironment.inheritedJITPoolOverride) -> [String: String] {
        var environment = base
        // M5 device trace: the cache launcher, Dock and Steam each reserve
        // 128 MiB before Slay the Spire 2 starts. The 640 MiB pool then refuses
        // even a 1 MiB game buffer. Without caching, the same scene reaches
        // video initialization. Keep this workaround local to the measured game.
        let key = "FEX_ENABLECODECACHINGWIP"
        if steamAppID == 2868840, environment[key] == nil {
            environment[key] = inheritedCacheOverride ?? "0"
        }
        // Normal device runs exhaust the 640 MiB arena
        // during Act-1 loading. Keep extra executable capacity local to this
        // game; the bridge validates the requested size before allocating it.
        let poolKey = "WVR_JIT_POOL_MIB"
        if steamAppID == 2868840, environment[poolKey] == nil {
            environment[poolKey] = inheritedJITPoolOverride ?? "896"
        }
        return environment
    }
}
