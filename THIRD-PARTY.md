# Third-party software and credits

WineVision VR's own code and documents are MIT-licensed (see `LICENSE` for the exact scope). It depends on, adapts
and was inspired by the projects below. Each keeps its own license and copyright.

## Components this project uses

WineVision VR (`visionos-windows-vr/`, `windows-runtime-plugin/`, `windows-vr-*`) runs Windows PC VR games on the
Vision Pro. It stands on the work of the projects below. None of their binaries are checked
into this repository: the pinned source caches (`third-party/madeira`, `openvr`, `openxr`, `opencomposite`,
`alvr-visionos`, the D3D12 DXMT checkout) are fetched by `windows-vr-tools/fetch_sources.py` and are ignored by
Git. Their exact revisions are in `windows-vr-tools/sources.lock.json`. Each component keeps its own licence;
the licence texts travel with the source caches and, in a built app, in `Runtime/legal`.

| Component | Authors and credit | Licence | How it is used here |
|---|---|---|---|
| [Madeira](https://github.com/willfaust/Madeira) at `48f9764` | Will Faust (creator); Nick (125hz), Jfishin, Jesse (JesseLovelace), Dan Perks, bahacan16, spitefulowl, meshoklv, TheHadesc and the other contributors named in Madeira's README | GPL-3.0-or-later with the Madeira Converter Exception (`LICENSE-EXCEPTION.md`) | Runs Wine and FEX inside an iOS/visionOS process: the in-process wineserver, the JIT bridge, the Wine process bridge, Madeira Dock. The app's launch adapter and its binary patches build on it |
| [Wine](https://www.winehq.org/) (Madeira's fork) | The Wine project and its contributors | LGPL-2.1-or-later (fork applied under GPL-3.0-or-later as Madeira documents) | Windows API and kernel emulation (`ntdll`, `wineserver`, `win32u`, PE builtins) |
| [FEX-Emu](https://github.com/FEX-Emu/FEX) (Madeira's fork) | The FEX-Emu team | MIT upstream, Madeira's changes GPL-3.0-or-later | x86-64 to ARM64EC translation and JIT |
| [DXMT](https://github.com/3Shain/DXMT) | Feifan He (3Shain); the Direct3D 9 frontend by David Acevedo (dacevedo12) | MIT upstream; D3D9 frontend and D3D12 headers LGPL-2.1-or-later (CodeWeavers contributor notices) | Direct3D 11 to Metal. The VR frame-transfer extension and the query and encoder fixes are shipped as patches in `windows-vr-openxr/patches/` |
| [OpenComposite (OpenOVR)](https://gitlab.com/znixian/OpenOVR) | Znixian and the OpenComposite contributors | GPL-3.0 | OpenVR to OpenXR layer for Unity and other OpenVR games |
| [OpenVR](https://github.com/ValveSoftware/openvr) | Valve Corporation | BSD-3-Clause | Headers for the OpenVR boundary |
| [OpenXR-SDK](https://github.com/KhronosGroup/OpenXR-SDK) | The Khronos Group | Apache-2.0; see its `LICENSE` and per-file notices | Headers and loader used by the guest OpenXR runtime |
| [ALVR visionOS client](https://github.com/alvr-org/alvr-visionos) | The ALVR organisation and contributors | MIT | Reference for the CompositorServices scene (immersion style, hidden upper limbs and overlays, rotational reprojection with a distant colour plane) |
| [StikDebug for visionOS](https://github.com/rebelancap/StikDebug-visionos) (rebelancap's port of [StikDebug](https://github.com/StikDebug/StikDebug)) and [StikJIT](https://github.com/StikDebug/StikJIT) | rebelancap; the StikDebug and StikJIT contributors | See each repository (Madeira records StikJIT 1.9.0 as MPL-2.0) | Enables JIT on the headset through a debugger script. Used as a separate app; nothing from it is copied here |
| [idevice](https://github.com/jkcoxson/idevice) | Jackson Coxson | MIT | The JIT and pairing path used by StikJIT and Madeira |
| [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) and [LLVM](https://llvm.org/) | Martin Storsjo; the LLVM project | Apache-2.0 with LLVM exceptions; llvm-mingw's own licence | Cross compiler for the ARM64EC and x64 guest DLLs and the Metal shader tooling |
| [FreeType](https://freetype.org/), GnuTLS, GMP, Nettle, FFmpeg, {fmt}, xxHash, SoftFloat, rpmalloc, Zstandard decoder | Their respective authors; see Madeira's `THIRD-PARTY-NOTICES.md` for versions and licences | As listed there | Statically linked into Wine and FEX by Madeira's own build |
| Steam client library code (`visionos-windows-vr/Sources/Steam`, `third-party/steam-native`) | Adapted from Madeira's native Steam client: copyright Jfishin and 125hz, used with the authors' permission as recorded in Madeira's docs | GPL-3.0-or-later with the Madeira Converter Exception (`third-party/steam-native/COPYING`) | Steam sign-in, library, depot downloads, Madeira Dock hand-off. Per-file SPDX and provenance notices are kept |
| [Apple Metal Shader Converter](https://developer.apple.com/metal/shader-converter/) | Apple | Proprietary, not included in this repository | Linked by Madeira's DXMT build, hence the Converter Exception; Apple's terms apply to it |
| [OpenSuperSampling (OSS)](https://github.com/cashcon57/open-supersampling) | cashcon57 and contributors | Apache-2.0 | 2D Gaussian canvas reconstruction and temporal extrapolation architecture adapted for visionOS foveated neural upscaling and 90Hz frame extrapolation (Mode 4) |
| [VeRantyx](https://github.com/Ag3497120/VeRantyx) | Ag3497120 | MIT | Custom DirectX/Vulkan runtime bridge architectures on Apple Silicon, in-process synchronization models, and zero-copy IOSurface texture transport |
| [ANGLE](https://chromium.googlesource.com/angle/angle/) x64 renderer from Chrome for Testing 134.0.6998.165 | The ANGLE project and its contributors | BSD-style license and component notices; the complete upstream Chromium credits accompany the DLLs in `ANGLECompatibility/THIRD-PARTY-NOTICES.html` | Optional Slay the Spire 2 OpenGL ES to Direct3D 11 compatibility renderer. DLLs are hash-pinned, app-owned resources generated from the official archive; no game files or Chrome executable are packaged |
| Valve's Steam client | Valve Corporation | Proprietary, not included | Downloaded on the headset from Valve's own CDN with sizes and hashes verified; this project distributes no Valve binary |
| [BepInExPack 5.4.2121](https://thunderstore.io/package/bbepis/BepInExPack/) | bbepis, the BepInEx team and component authors | Component-specific upstream licenses; see the downloaded package and [BepInEx source](https://github.com/BepInEx/BepInEx) | Downloaded on the headset for the Risk of Rain 2 health-bar repair; no package binaries are bundled |
| [MacosHealthbarsFix 1.0.27 / MetalSafeBars](https://thunderstore.io/package/LevTeam/MacosHealthbarsFix/) | LevTeam | Upstream package terms; no redistribution license assumed | Downloaded on the headset as the verified Risk of Rain 2 material repair; no plugin binary or source is bundled |
| [Newtonsoft.Json 13.0.4](https://www.nuget.org/packages/Newtonsoft.Json/13.0.4) | James Newton-King and contributors | MIT | Downloaded from NuGet on the headset as MetalSafeBars' dependency; no DLL is bundled |
| [SDL Steam Controller protocol definitions](https://github.com/libsdl-org/SDL/tree/bd9f6ca9ff0e9509f49980fc1b70837f54b6f244/src/joystick/hidapi) and [Valve's SDL iOS BLE backend](https://github.com/libsdl-org/SDL/blob/bd9f6ca9ff0e9509f49980fc1b70837f54b6f244/src/hidapi/ios/hid.m) | Valve Corporation, Sam Lantinga and SDL contributors | zlib | Protocol reference for the independently implemented Swift 2026 Steam Controller BLE transport and decoder; no SDL source or binary is embedded |

Games used for testing, Moss: Book II (Polyarc) and BONEWORKS (Stress Level Zero), belong to their publishers.
No game content is distributed, and no purchase check is bypassed.

**Contribution policies.** Madeira's README asks that changes from its forks are not sent upstream, because
FEX-Emu does not accept AI-generated code, and DXMT's `AGENTS.md` says that AI must not be used to generate code
for contributions to that project. The patches in `windows-vr-openxr/patches/` and
`windows-runtime-plugin/patches/` are local integration changes made with AI assistance. They are kept here as
patch files against the pinned sources and are not offered to those upstream projects.

**Corresponding source.** If you distribute a built Windows VR app, you must meet the obligations of the licences
above, including GPL-3.0-or-later and LGPL-2.1 for the Madeira, Wine, OpenComposite and Steam client parts:
provide the complete corresponding source, including this repository's patches, and keep the notices.


## Inspiration (no code from these is shipped)

| Project | Credit | What it meant for this project |
|---|---|---|
| [AVP Play](https://github.com/myMartek/avp-play) | myMartek (MIT) | This project began as a fork of it. It showed that PC-class VR games can be brought to a Vision Pro, and a few conventions carried over: the bilingual `L("English", "Deutsch")` helper pattern, the MIT license and the repository layout. None of its Mac app, recipes or toolchain packages are included |
| [Klepton](https://github.com/shinyquagsire23/Klepton) | Max Thomas and contributors (MIT) | The toolchain behind AVP Play; a precedent for relinking and running games natively on visionOS. Not used |
| [Glovebox](https://github.com/glovebox-vr/glovebox) | The Glovebox contributors (MIT) | Brought Half-Life: Alyx to the Vision Pro; its approach to shader preparation and free-account memory was instructive. Not used |
| [xrizer](https://github.com/Supreeeme/xrizer) | Supreeeme and contributors (GPL-3.0) | Considered for OpenVR to OpenXR; OpenComposite was chosen because it runs as a Windows DLL inside Wine. Not used |
| [Steam Frame documentation](https://partner.steamgames.com/doc/steamhardware/steamframe/compatibility) | Valve | The split between native ARM64 libraries and translated game code is the model followed here |
