#!/usr/bin/env python3
"""Test the patched host's presence policy and inspect the pinned client ABI; no Steam login."""
from pathlib import Path
import argparse, hashlib, re, shutil, struct, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--client', type=Path)
args = p.parse_args()
with tempfile.TemporaryDirectory(prefix='wvr-steam-presence-') as temp:
    work = Path(temp)
    source = ROOT / 'third-party/madeira/madeira-dock'
    shutil.copytree(source / 'src', work / 'src')
    (work / 'docs').mkdir()
    shutil.copy2(source / 'README.md', work / 'README.md')
    shutil.copy2(source / 'docs/HANDOFF.md', work / 'docs/HANDOFF.md')
    for patch in sorted((ROOT / 'windows-vr-tools/patches/madeira-dock').glob('*.patch')):
        subprocess.run(['git','-C',str(work),'apply',str(patch)],check=True)
    exe = work / 'presence-test'
    subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',
        '-I',str(work/'src'),str(work/'src/presence.c'),
        str(ROOT/'visionos-windows-vr/Tests/SteamServices/PresenceProbe.c'),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
    subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',
        '-I',str(work/'src'),str(work/'src/frame.c'),
        str(ROOT/'visionos-windows-vr/Tests/SteamServices/FrameProbe.c'),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
    if not args.client: raise SystemExit()
    raw = args.client.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == '71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640'
    pe = struct.unpack_from('<I',raw,0x3c)[0]; opt=pe+24
    assert struct.unpack_from('<H',raw,pe+4)[0] == 0x8664
    base = struct.unpack_from('<Q',raw,opt+24)[0]
    size,headers = struct.unpack_from('<II',raw,opt+56)
    image = bytearray(size); image[:headers]=raw[:headers]
    sh = opt+struct.unpack_from('<H',raw,pe+20)[0]
    for i in range(struct.unpack_from('<H',raw,pe+6)[0]):
        va,n,off = struct.unpack_from('<III',raw,sh+40*i+12); image[va:va+n]=raw[off:off+n]
    def table(name):
        td=image.index(b'.?AV'+name.encode()+b'@@\0')-16; candidates=[]
        for ref in re.finditer(re.escape(struct.pack('<I',td)),image):
            col=ref.start()-12
            if col<0:continue
            signature,offset,_,_,_,own=struct.unpack_from('<6I',image,col)
            if signature==1 and offset==0 and own==col:
                candidates += [m.start()+8 for m in re.finditer(re.escape(struct.pack('<Q',base+col)),image)]
        assert len(candidates)==1; return candidates[0]
    engine=table('CSteamClient'); social=table('IClientFriendsMap'); utils=table('IClientUtilsMap')
    assert struct.unpack_from('<Q',image,engine+13*8)[0]-base==0x943510
    assert b'\x48\x8b\x43\x20' in image[0x943510:0x9435ad] # returns CUserContext+0x20
    assert image[0x9ed414:0x9ed41f] == b'\xe8\x17\xb3\xd3\xff\x8b\xd6\x48\x89\x43\x20' # stores friends constructor result there
    assert struct.unpack_from('<Q',image,engine+14*8)[0]-base==0x945220
    assert struct.unpack_from('<Q',image,engine+19*8)[0]-base==0x945e30
    assert image[0x945e30:0x945e34] == b'\x48\x83\xec\x38' # no explicit arguments
    # The frame's two profiler names identify the engine UI frame path.
    assert image[0x12ece78:0x12ece78+23].startswith(b'CSteamClient::RunFrame\0')
    # Explicit hidden return pointer saved from RDX; index/flags are R8D/R9D.
    assert image[0x7526fe:0x752707] == b'\x41\x8b\xf9\x41\x8b\xd8\x48\x8b\xf2'
    assert image[0x752891:0x752894] == b'\x48\x8b\xc6' # returns that buffer
    assert image[0x753384:0x75338d] == b'\x41\xb8\x18\x00\x00\x00\x48\x8b\xd5' # 24-byte output

    for slot,rva,name,method in [(4,0x768a20,'GetPersonaState',0x534bc194),
                               (5,0x848460,'SetPersonaState',0xe333cf87),
                               (7,0x752d60,'GetFriendCount',0x1e61eaea),
                               (10,0x7526f0,'GetFriendByIndex',0x272df28d),
                               (23,0x753250,'GetFriendGamePlayed',0xe0ce182e),
                               (32,0x82e020,'RequestUserInformation',0xbc9a7cbb),
                               (5,0x76f3b0,'GetSecondsSinceComputerActive',0xb0a5e101),
                               (6,0x83a060,'SetComputerActive',0xf0bc0b28)]:
        assert struct.unpack_from('<Q',image,(utils if name in ('GetSecondsSinceComputerActive','SetComputerActive') else social)+8*slot)[0]-base==rva
        code=image[rva:rva+0x200]; found=False
        for j in range(len(code)-7):
            if code[j] in (0x48,0x4c) and code[j+1]==0x8d and code[j+2]&0xc7==0x05:
                target=rva+j+7+struct.unpack_from('<i',code,j+3)[0]
                if image[target:target+len(name)+1] == name.encode()+b'\0':found=True
        assert found and struct.pack('<I',method) in code
    assert image[0x82e028:0x82e02f] == b'\x41\x0f\xb6\xf8\x48\x8b\xda' # ID in RDX, bool in R8B
    # The read-only friends-UI mode helper is called with no explicit args by
    # CUserFriends::SetPersonaStateInternal. True routes the change to UI events;
    # false continues in the client. Its explicit -nofriendsui branch returns false.
    assert image[0x9e61e1:0x9e61ee] == b'\xe8\x6a\x93\xca\xff\x84\xc0\x0f\x84\x95\x00\x00\x00'
    assert image[0x68f660:0x68f667] == b'\x48\x8b\x15\x51\xe2\x0b\x01'
    assert image[0x68f6a8:0x68f6af] == b'\x32\xc0\x48\x83\xc4\x28\xc3'
    assert image[0x1285b30:0x1285b3d] == b'-nofriendsui\0'
    assert struct.unpack_from('<Q',image,social+13*8)[0]-base == 0x7542b0
    assert struct.unpack_from('<Q',image,social+14*8)[0]-base == 0x753c20
    user_table = table('IClientUserMap')
    assert struct.unpack_from('<Q',image,user_table+27*8)[0]-base == 0x84c300
    assert struct.unpack_from('<Q',image,user_table+28*8)[0]-base == 0x8166f0
    assert image[0x84c30f:0x84c312] == b'\x0f\xb6\xda' # one bool in DL
    client_table = table('CAdapterSteamClient021')
    for slot, rva in [(0,0x4e5d30),(2,0x6f20a0),(5,0x6f2140),(8,0x6f21f0)]:
        assert struct.unpack_from('<Q',image,client_table+slot*8)[0]-base == rva
    assert struct.unpack_from('<Q',image,table('CAdapterSteamFriends017')+8*8)[0]-base == 0x6f5820
    assert image[0x6f5820:0x6f582e] == b'\x48\x8b\x49\x08\x48\x8b\x01\x48\xff\xa0\xb8\x00\x00\x00' # forwards same arguments to private slot 23
    storage = table('IClientRemoteStorageMap')
    unified = table('IClientUnifiedMessagesMap')
    assert struct.unpack_from('<Q',image,engine+52*8)[0]-base == 0x945040
    assert image[0x9450aa:0x9450b1] == b'\x48\x8b\x83\xc8\x00\x00\x00' # returns CUserContext+0xc8
    assert image[0x9ed5ec:0x9ed5fa] == b'\xe8\x1f\xd1\xd3\xff\x8b\xd6\x48\x89\x83\xc8\x00\x00\x00' # unified constructor result
    for slot,rva,name in [(0,0x832ff0,'SendMethod'),(1,0x762330,'GetMethodResponseInfo'),(3,0x827170,'ReleaseMethod')]:
        assert struct.unpack_from('<Q',image,unified+slot*8)[0]-base == rva
        code=image[rva:rva+0x200]; found=False
        for j in range(len(code)-7):
            if code[j] in (0x48,0x4c) and code[j+1]==0x8d and code[j+2]&0xc7==5:
                target=rva+j+7+struct.unpack_from('<i',code,j+3)[0]
                if image[target:target+len(name)+1] == name.encode()+b'\0': found=True
        assert found, name
    assert struct.pack('<I',0x3a827c3a) in image[0x832ff0:0x8331a7] # SendMethod IPC identity
    assert image[0x833005:0x833011] == b'\x41\x8b\xf9\x49\x8b\xf0\x48\x8b\xda\x4c\x8b\xf1' # length32, payload pointer, method string
    assert struct.unpack_from('<Q',image,engine+24*8)[0]-base == 0x9445f0
    assert image[0x94465a:0x94465e] == b'\x48\x8b\x43\x68'
    assert struct.unpack_from('<Q',image,storage+24*8)[0]-base == 0x814250
    assert struct.unpack_from('<Q',image,storage+25*8)[0]-base == 0x839830
    assert image[0x83983f:0x839845] == b'\x41\x0f\xb6\xf8\x8b\xda' # app32 plus bool
    assert image[0x83a06f:0x83a071] == b'\x8b\xda' # uint32 source in EDX
    vr_label = 0x9621b3 + 7 + struct.unpack_from('<i', image, 0x9621b6)[0]
    assert struct.unpack_from('<I', image, 0x962238 + 2 * 4)[0] == 0x9621b3
    assert image[vr_label:vr_label+3] == b'VR\0'
    print('PASS exact SHA-256, friends factory/context mapping, vtable methods and IPC identities')
