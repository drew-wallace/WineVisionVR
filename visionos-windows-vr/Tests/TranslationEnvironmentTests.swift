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
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2868840,
      inheritedCacheOverride: nil)[key] == "0")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2868840,
      base: [key: "1"], inheritedCacheOverride: nil)[key] == "1")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2868840,
      inheritedCacheOverride: "1")[key] == "1")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 123,
      inheritedCacheOverride: nil)[key] == nil)
  let poolKey = "WVR_JIT_POOL_MIB"
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2868840,
      inheritedCacheOverride: nil, inheritedJITPoolOverride: nil)[poolKey] == "896")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2868840,
      base: [poolKey: "640"], inheritedCacheOverride: nil, inheritedJITPoolOverride: "1024")[poolKey] == "640")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 2868840,
      inheritedCacheOverride: nil, inheritedJITPoolOverride: "768")[poolKey] == "768")
  assert(WindowsVRTranslationEnvironment.compatibilityEnvironment(steamAppID: 123,
      inheritedCacheOverride: nil, inheritedJITPoolOverride: "896")[poolKey] == nil)
  print("PASS: translation defaults apply before Wine, preserve explicit overrides and enable the implemented persistent cache")
 }
}
