#!/usr/bin/env python3
"""Rebuild only the standalone audio translation unit in a verified runtime clone.

Reuses byte-verified native/guest/graphics outputs whose source inputs did not
change. Keeps the baseline untouched and records the precise incremental build.
"""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess, sys, tempfile
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'windows-vr-tools'))
import prepare_runtime, resource_receipt
PATCH='windows-runtime-plugin/patches/0023-madeira-audio-output-recovery.patch'
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline',type=Path,required=True);p.add_argument('--resources',type=Path,required=True)
p.add_argument('--output',type=Path,required=True);p.add_argument('--output-resources',type=Path,required=True)
p.add_argument('--patch',default=PATCH,choices=[PATCH,'windows-runtime-plugin/patches/0024-madeira-reinitialize-audio-output.patch'])
a=p.parse_args();base=a.baseline.resolve();oldres=a.resources.resolve();out=a.output.resolve();res=a.output_resources.resolve()
PATCH=a.patch
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def read(p):return json.loads(p.read_text())
def write(p,d):p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n')
if out.exists() or res.exists():raise SystemExit('Use fresh output folders; the baseline is never overwritten.')
current=prepare_runtime.project_patch_hashes();old=read(base/'AVPPLAY_SOURCE_PROVENANCE.json')
expected=dict(current);expected.pop(PATCH)
assert old['integrationPatchSha256']==expected,'Baseline source inputs differ beyond the single audio patch'
# Reconstruct this translation unit from the pinned source and each previously
# recorded audio patch. Reject an unrelated edit before reusing other outputs.
with tempfile.TemporaryDirectory(prefix='wvr-audio-baseline-') as temp:
 check=Path(temp);audio=Path('build/ntdll-unix/audio_null_ios.c');(check/audio).parent.mkdir(parents=True)
 shutil.copy2(ROOT/'third-party/madeira'/audio,check/audio)
 for prior in ['windows-runtime-plugin/patches/0023-madeira-audio-output-recovery.patch',
               'windows-runtime-plugin/patches/0024-madeira-reinitialize-audio-output.patch']:
  if prior in old['integrationPatchSha256']:
   assert sha(ROOT/prior)==old['integrationPatchSha256'][prior],prior
   subprocess.run(['git','-C',str(check),'apply',str(ROOT/prior)],check=True)
 assert sha(base/audio)==sha(check/audio),'Baseline audio source differs from recorded patches'
native=read(base/'AVPPLAY_NATIVE_BUILD_RECEIPT.json')
for name,h in native['native']['artifactsSha256'].items():assert sha(base/name)==h,name
guest=read(base/'app/Madeira/AVPPLAY_GUEST_BUILD_RECEIPT.json')
for name,h in guest['guest']['resourcesSha256'].items():
 assert sha(base/'app/Madeira'/name)==h,name
 assert sha(oldres/'Runtime'/name)==h,name
subprocess.run(['git','-C',str(base),'apply','--check',str(ROOT/PATCH)],check=True)
print('Baseline input/archive/guest hashes verified; cloning without modifying it.',flush=True)
# macOS APFS clone-on-write; fail rather than silently copying a huge source tree.
subprocess.run(['/bin/cp','-cR',str(base),str(out)],check=True)
subprocess.run(['/bin/cp','-cR',str(oldres),str(res)],check=True)
subprocess.run(['git','-C',str(out),'apply',str(ROOT/PATCH)],check=True)
old_base_hash=sha(out/'AVPPLAY_SOURCE_PROVENANCE.json');old['integrationPatchSha256']=current
write(out/'AVPPLAY_SOURCE_PROVENANCE.json',old)
# The graphics source tree/ports and archive bytes are unchanged. Rebind their
# inherited provenance to the extended baseline, retaining the original build
# commands as historical evidence, not claiming a new graphics compilation.
dp=out/'AVPPLAY_D3D12_SOURCE_PROVENANCE.json';d=read(dp);old_d3d_hash=sha(dp)
assert d['madeiraOverlayProvenanceSha256']==old_base_hash
for name,h in d['integrationInputsSha256'].items():assert sha(ROOT/name)==h,name
d['madeiraOverlayProvenanceSha256']=sha(out/'AVPPLAY_SOURCE_PROVENANCE.json');write(dp,d)
ap=out/'AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT.json';ad=read(ap)
assert ad['sourceProvenanceSha256']==old_d3d_hash;ad['sourceProvenanceSha256']=sha(dp);write(ap,ad)
bp=out/'AVPPLAY_D3D12_BUILD_RECEIPT.json';bd=read(bp)
assert bd['sourceProvenanceSha256']==old_d3d_hash
for name,h in bd['artifactsSha256'].items():
 f=out/'app/Madeira'/name.removeprefix('native/') if name.startswith('native/') else res/'Runtime'/name.removeprefix('guest/')
 assert sha(f)==h,name
bd['sourceProvenanceSha256']=sha(dp);bd['nativeAdaptationReceiptSha256']=sha(ap);write(bp,bd)
work=out/'build'/Path(PATCH).stem;work.mkdir()
source=out/'build/ntdll-unix/audio_null_ios.c';obj=work/'audio_null_ios.o'
sdk=subprocess.check_output(['xcrun','--sdk','xros','--show-sdk-path'],text=True).strip()
command=['xcrun','--sdk','xros','clang','-arch','arm64','-isysroot',sdk,'-target','arm64-apple-xros27.0','-O2','-fPIC','-fvisibility=hidden','-fno-stack-protector','-fno-strict-aliasing','-Wno-macro-redefined','-Wno-implicit-function-declaration','-Wno-int-conversion','-DWINE_IOS=1','-c',str(source),'-o',str(obj)]
# audio_null_ios.c is standalone: its Wine ABI mirrors and only conditional
# (__MADEIRA_IOS_WOW_HOST_PTR) are in the source; no generated Wine header used.
with (work/'compile.log').open('w') as log:subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT)
archive=out/'app/Madeira/libntdll_unix.a'
subprocess.run(['xcrun','ar','r',str(archive),str(obj)],check=True)
subprocess.run(['xcrun','ranlib',str(archive)],check=True)
symbols=subprocess.check_output(['xcrun','nm','-g',str(archive)],text=True,stderr=subprocess.DEVNULL)
assert '_wvr_audio_output_reset_v1' in symbols
for name,h in native['native']['artifactsSha256'].items():
 if name!='app/Madeira/libntdll_unix.a':assert sha(out/name)==h,name
subprocess.run([sys.executable,str(ROOT/'windows-vr-tools/resource_receipt.py'),'native','--runtime-source',str(out)],check=True)
subprocess.run([sys.executable,str(ROOT/'windows-vr-tools/resource_receipt.py'),'guest','--runtime-source',str(out),'--resource-source',str(out/'app/Madeira')],check=True)
for f in out.glob('AVPPLAY*.json'):
 if (res/'Runtime'/f.name).is_file():shutil.copy2(f,res/'Runtime'/f.name)
shutil.copy2(out/'AVPPLAY_NATIVE_BUILD_RECEIPT.json',res/'Runtime/AVPPLAY_NATIVE_BUILD_RECEIPT.json')
shutil.copy2(out/'app/Madeira/AVPPLAY_GUEST_BUILD_RECEIPT.json',res/'Runtime/AVPPLAY_GUEST_BUILD_RECEIPT.json')
resource_receipt.validate_receipts(out/'app/Madeira',out,out/'AVPPLAY_NATIVE_BUILD_RECEIPT.json')
write(work/'incremental-build.json',{'schemaVersion':1,'baselineSourceProvenanceSha256':old_base_hash,'audioSourceSha256':sha(source),'audioObjectSha256':sha(obj),'archiveSha256':sha(archive),'compilerCommand':command,'rebuiltArchiveMember':'audio_null_ios.o','unchangedNativeArchivesVerified':len(native['native']['artifactsSha256'])-1,'guestFilesReusedAndVerified':len(guest['guest']['resourcesSha256']),'graphicsArchiveRecompiled':False})
print('Audio object rebuilt; unchanged outputs verified; new native/guest provenance recorded.',flush=True)
