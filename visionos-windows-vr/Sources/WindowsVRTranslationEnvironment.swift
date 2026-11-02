import Foundation

/// Defaults must reach Wine even when the app uses the preserved native plugin.
/// Explicit process/manifest overrides remain available for controlled comparisons.
enum WindowsVRTranslationEnvironment {
    /// Snapshot before applyDefaults writes into the process environment.
    static let inheritedCodeCacheOverride = ProcessInfo.processInfo.environment["FEX_ENABLECODECACHINGWIP"]
    static let inheritedJITPoolOverride = ProcessInfo.processInfo.environment["WVR_JIT_POOL_MIB"]
    static let inheritedL2CacheOverride = ProcessInfo.processInfo.environment["FEX_DISABLEL2CACHE"]
    static let inheritedFEXArenaOverride = ProcessInfo.processInfo.environment["WVR_FEX_ARENA_GIB"]
    static let inheritedDisplayEnvironment = ProcessInfo.processInfo.environment.filter {
        $0.key == "MADEIRA_SCREEN_W" || $0.key == "MADEIRA_SCREEN_H"
    }
    static let inheritedControllerEnvironment = ProcessInfo.processInfo.environment.filter {
        $0.key == "MADEIRA_HIDPAD" || $0.key == "MADEIRA_HIDPAD_NAME"
    }

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
        _ = inheritedL2CacheOverride
        _ = inheritedFEXArenaOverride
        _ = inheritedDisplayEnvironment
        for (name, value) in defaults where getenv(name) == nil {
            setenv(name, value, 0)
        }
    }

    /// Host-only settings: MADEIRA_ names are reserved and must never enter a
    /// game manifest. Any explicit process dimension owns the whole mode.
    static func desktopDisplayEnvironment(isDesktop: Bool, width: Int = 1920, height: Int = 1080,
                                          inherited: [String: String]) -> [String: String] {
        let keys = ["MADEIRA_SCREEN_W", "MADEIRA_SCREEN_H"]
        guard isDesktop, keys.allSatisfy({ inherited[$0] == nil }) else { return [:] }
        return [keys[0]: String(width), keys[1]: String(height)]
    }

    /// Rewired in Risk of Rain 2 requests Windows.Gaming.Input. Its HID
    /// enumeration requires a Windows device in addition to XInput snapshots.
    static func desktopControllerEnvironment(isDesktop: Bool, steamAppID: Int?,
                                             inherited: [String: String]) -> [String: String] {
        guard isDesktop, steamAppID == 632360, inherited["MADEIRA_HIDPAD"] == nil else { return [:] }
        var result = ["MADEIRA_HIDPAD": "generic"]
        if inherited["MADEIRA_HIDPAD_NAME"] == nil { result["MADEIRA_HIDPAD_NAME"] = "WineVision Gamepad" }
        return result
    }

    static func compatibilityEnvironment(steamAppID: Int, base: [String: String] = [:],
                                         inheritedCacheOverride: String?,
                                         inheritedJITPoolOverride: String? = WindowsVRTranslationEnvironment.inheritedJITPoolOverride,
                                         inheritedL2CacheOverride: String? = WindowsVRTranslationEnvironment.inheritedL2CacheOverride,
                                         inheritedFEXArenaOverride: String? = WindowsVRTranslationEnvironment.inheritedFEXArenaOverride) -> [String: String] {
        var environment = base
        // M5 device trace: the cache launcher, Dock and Steam each reserve
        // 128 MiB before the game starts. Slay the Spire 2 refuses even a
        // 1 MiB game buffer; Risk of Rain 2 cannot load D3D11/DXGI once these
        // reservations fill the 640 MiB pool. Limit this to observed failures.
        let needsAdditionalCodeSpace = steamAppID == 2868840 || steamAppID == 632360
        let key = "FEX_ENABLECODECACHINGWIP"
        if needsAdditionalCodeSpace, environment[key] == nil {
            environment[key] = inheritedCacheOverride ?? "0"
        }
        // Device runs exhaust the arena during Slay the Spire 2 Act-1 loading
        // and Risk of Rain 2 graphics initialization. The bridge validates the
        // requested size before allocating it.
        let poolKey = "WVR_JIT_POOL_MIB"
        if needsAdditionalCodeSpace, environment[poolKey] == nil {
            environment[poolKey] = inheritedJITPoolOverride ?? "896"
        }
        // Risk of Rain 2 creates enough translator threads to exhaust the
        // 16 GiB host arena with 50 MiB lookup tables. The supported L1-only
        // layout uses 2 MiB per thread.
        let needsAdditionalAddressSpace = steamAppID == 632360
        let l2Key = "FEX_DISABLEL2CACHE"
        if needsAdditionalAddressSpace, environment[l2Key] == nil {
            environment[l2Key] = inheritedL2CacheOverride ?? "1"
        }
        // Builds 51 and 52 filled the real 16 GiB reservation even with L2
        // disabled. Native patch 0025 attempts 32 GiB and retains the existing
        // fallback ladder and configured size cap if reservation fails.
        let arenaKey = "WVR_FEX_ARENA_GIB"
        if needsAdditionalAddressSpace, environment[arenaKey] == nil {
            environment[arenaKey] = inheritedFEXArenaOverride ?? "32"
        }
        return environment
    }
}
