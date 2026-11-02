import Foundation
@main struct Probe {
 static func main() {
  for name in WindowsVRTranslationEnvironment.defaults.keys { unsetenv(name) }
  setenv("FEX_MAXINST", "1024", 1)
  WindowsVRTranslationEnvironment.applyDefaults()
  assert(String(cString: getenv("FEX_MAXINST")) == "1024")
  assert(String(cString: getenv("FEX_MULTIBLOCK")) == "1")
  assert(String(cString: getenv("FEX_ENABLECODECACHINGWIP")) == "1")
  assert(String(cString: getenv("FEX_ENABLECODECACHEVALIDATION")) == "0")
  setenv("FEX_ENABLECODECACHINGWIP", "0", 1)
  WindowsVRTranslationEnvironment.applyDefaults()
  assert(String(cString: getenv("FEX_ENABLECODECACHINGWIP")) == "0")
  let key = "FEX_ENABLECODECACHINGWIP"
  let poolKey = "WVR_JIT_POOL_MIB"
  for appID in [2868840, 632360] {
    let defaults = WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: appID,
        inheritedCacheOverride: nil, inheritedJITPoolOverride: nil)
    assert(defaults[key] == "0")
    assert(defaults[poolKey] == "896")
    let explicit = WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: appID,
        base: [key: "1", poolKey: "640"], inheritedCacheOverride: "0", inheritedJITPoolOverride: "1024")
    assert(explicit[key] == "1")
    assert(explicit[poolKey] == "640")
    let inherited = WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: appID,
        inheritedCacheOverride: "1", inheritedJITPoolOverride: "768")
    assert(inherited[key] == "1")
    assert(inherited[poolKey] == "768")
  }
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 123,
      inheritedCacheOverride: nil, inheritedJITPoolOverride: "896").isEmpty)
  let l2Key = "FEX_DISABLEL2CACHE"
  let arenaKey = "WVR_FEX_ARENA_GIB"
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 632360,
      inheritedCacheOverride: nil, inheritedL2CacheOverride: nil)[l2Key] == "1")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 632360,
      base: [l2Key: "0"], inheritedCacheOverride: nil, inheritedL2CacheOverride: "1")[l2Key] == "0")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 632360,
      inheritedCacheOverride: nil, inheritedL2CacheOverride: "0")[l2Key] == "0")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2868840,
      inheritedCacheOverride: nil, inheritedL2CacheOverride: "1")[l2Key] == nil)
  let display = ["MADEIRA_SCREEN_W": "1920", "MADEIRA_SCREEN_H": "1080"]
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 632360,
      inheritedCacheOverride: nil, inheritedFEXArenaOverride: nil)[arenaKey] == "32")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 632360,
      base: [arenaKey: "16"], inheritedCacheOverride: nil, inheritedFEXArenaOverride: "32")[arenaKey] == "16")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 632360,
      inheritedCacheOverride: nil, inheritedFEXArenaOverride: "16")[arenaKey] == "16")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2868840,
      inheritedCacheOverride: nil, inheritedFEXArenaOverride: "32")[arenaKey] == nil)
  assert(WindowsVRTranslationEnvironment.desktopDisplayEnvironment(isDesktop: true, inherited: [:]) == display)
  assert(WindowsVRTranslationEnvironment.desktopDisplayEnvironment(isDesktop: false, inherited: [:]).isEmpty)
  for explicit in [["MADEIRA_SCREEN_W": "1280"], ["MADEIRA_SCREEN_H": "800"],
                   ["MADEIRA_SCREEN_W": "1280", "MADEIRA_SCREEN_H": "720"]] {
    assert(WindowsVRTranslationEnvironment.desktopDisplayEnvironment(isDesktop: true, inherited: explicit).isEmpty)
  }
  assert(WindowsVRTranslationEnvironment.desktopDisplayEnvironment(isDesktop: true, width: 1440, height: 1080,
      inherited: [:]) == ["MADEIRA_SCREEN_W": "1440", "MADEIRA_SCREEN_H": "1080"])
  print("PASS: measured-game code-space defaults, unrelated-game exclusion and explicit overrides")
  print("PASS: universal 1080p desktop fallback, profile size override, VR exclusion and explicit process overrides")
  print("PASS: translation defaults apply before Wine, preserve explicit overrides and enable the implemented persistent cache")
  let hid = ["MADEIRA_HIDPAD": "generic", "MADEIRA_HIDPAD_NAME": "WineVision Gamepad"]
  assert(WindowsVRTranslationEnvironment.desktopControllerEnvironment(isDesktop: true,
      steamAppID: 632360, inherited: [:]) == hid)
  for appID in [2868840, 123] {
    assert(WindowsVRTranslationEnvironment.desktopControllerEnvironment(isDesktop: true,
        steamAppID: appID, inherited: [:]).isEmpty)
  }
  assert(WindowsVRTranslationEnvironment.desktopControllerEnvironment(isDesktop: false,
      steamAppID: 632360, inherited: [:]).isEmpty)
  assert(WindowsVRTranslationEnvironment.desktopControllerEnvironment(isDesktop: true,
      steamAppID: 632360, inherited: ["MADEIRA_HIDPAD": "dualsense"]).isEmpty)
  assert(WindowsVRTranslationEnvironment.desktopControllerEnvironment(isDesktop: true,
      steamAppID: 632360, inherited: ["MADEIRA_HIDPAD_NAME": "Custom"])
      == ["MADEIRA_HIDPAD": "generic"])
 }
}
