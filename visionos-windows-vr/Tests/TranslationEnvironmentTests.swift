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
  for appID in [2868840, 632360, 457550, 2379780] {
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
  let balatro = WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2379780,
      base: ["LOVE_GRAPHICS_USE_OPENGLES": "1"], inheritedCacheOverride: nil,
      inheritedJITPoolOverride: nil, inheritedL2CacheOverride: nil, inheritedFEXArenaOverride: nil)
  assert(balatro == [key: "0", poolKey: "896", "LOVE_GRAPHICS_USE_OPENGLES": "1"])
  let bigscreen = WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 457550,
      inheritedCacheOverride: nil, inheritedJITPoolOverride: nil,
      inheritedL2CacheOverride: nil, inheritedFEXArenaOverride: nil)
  assert(bigscreen == [key: "0", poolKey: "896", l2Key: "1", arenaKey: "32"])
  let savedBigscreen = WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 457550,
      base: ["OPENSSL_ia32cap": "0"], inheritedCacheOverride: nil, inheritedJITPoolOverride: nil)
  assert(savedBigscreen[key] == "0" && savedBigscreen[poolKey] == "896")
  assert(savedBigscreen[l2Key] == "1" && savedBigscreen[arenaKey] == "32")
  assert(savedBigscreen["OPENSSL_ia32cap"] == "0")
  let explicitBigscreen = WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 457550,
      base: [l2Key: "0", arenaKey: "16"], inheritedCacheOverride: nil,
      inheritedL2CacheOverride: "1", inheritedFEXArenaOverride: "32")
  assert(explicitBigscreen[l2Key] == "0" && explicitBigscreen[arenaKey] == "16")
  let inheritedBigscreen = WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 457550,
      inheritedCacheOverride: nil, inheritedL2CacheOverride: "0", inheritedFEXArenaOverride: "16")
  assert(inheritedBigscreen[l2Key] == "0" && inheritedBigscreen[arenaKey] == "16")
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
  print("PASS: Bigscreen arena/cache defaults, saved environments and explicit profile/process overrides")
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
