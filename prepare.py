"""Generate a separate, narrowly pinned iOS 1.0.7/TMG3 edition from upstream."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path
from audit_firmware import audit, require, UPSTREAM, BUNDLE, MARKER, CANDIDATE_SHA

def replace_once(text, old, new, label):
    require(text.count(old)==1, 'unexpected_source_shape_'+label)
    return text.replace(old,new,1)

def prepare(root, stock, firmware, edition_name='ios107-tmg3-edition'):
    root=Path(root).resolve()
    command=['git','-c','safe.directory='+root.as_posix(),'-C',str(root)]
    head=subprocess.check_output(command+['rev-parse','HEAD'],text=True).strip()
    require(head==UPSTREAM,'upstream_commit_mismatch')
    source=root/'official-addon/ios107-edition'
    dirty=subprocess.check_output(command+['diff','--name-only','HEAD','--','official-addon/ios107-edition'],text=True)
    require(not dirty.strip(),'upstream_edition_has_changes')
    candidate=audit(stock,firmware)
    require(re.fullmatch(r'ios107-tmg3-edition(?:-v[0-9]+)?',edition_name) is not None,'invalid_edition_name')
    target=root/'official-addon'/edition_name
    require(not target.exists(),'generated_edition_already_exists')
    shutil.copytree(source,target,ignore=shutil.ignore_patterns('build','__pycache__','.DS_Store'))
    # Normalise text sources for Xcode/bash; no original firmware bytes are edited.
    for file in target.rglob('*'):
        if file.is_file() and file.suffix in ('.sh','.m','.h','.c','.py','.mjs','.json','.md'):
            text=file.read_text(encoding='utf-8')
            file.write_text(text,encoding='utf-8',newline='\n')
    changed=[]
    patches={
        '6ae710233feec65e23816f4c89e75584de5f1abdde1f0aa8d74c4a3535ca8473':CANDIDATE_SHA,
        '8842896':'8869710','7408584':'7515400',
        'd7e88db2e1ad22651c775ec8f4740d0e':candidate['apMD5'],
        '0100050005':'0100050012','100050005':'100050012',
        '1.0.5.5':'1.0.5.12','APP107-OTA-PHONE-01':MARKER,
        'APP107-OTA-PUBLIC-SOURCE-01':'APP107-TMG3-LOCAL-DEV01',
        'TMG2':'TMG3','tmg2':'tmg3',
    }
    selected=[p for p in target.rglob('*') if p.is_file() and p.suffix in ('.m','.h','.py','.mjs')]
    for file in selected:
        before=file.read_text(encoding='utf-8');text=before
        for old,new in patches.items(): text=text.replace(old,new)
        if text!=before:
            file.write_text(text,encoding='utf-8',newline='\n');changed.append(file.relative_to(target).as_posix())
    file=target/'ExperimentalOTA.m';text=file.read_text(encoding='utf-8')
    pin_text='static NSDictionary *PayloadPins(void){return @{\n'+',\n'.join(
        '    @"'+name+'":@[@'+str(values[0])+',@"'+values[1]+'"]' for name,values in candidate['payloadPins'].items())+'};}'
    text,n=re.subn(r'static NSDictionary \*PayloadPins\(void\)\{return @\{.*?\};\}',lambda _:pin_text,text,flags=re.S)
    require(n==1,'payload_pin_table_shape')
    file.write_text(text,encoding='utf-8',newline='\n')
    file=target/'ExperimentalOTAFlash.m';text=file.read_text(encoding='utf-8')
    text=replace_once(text,'@[@"Strix OS 1.0.4.12",@"Strix OS 1.0.5.12"]','@[@"Strix OS 1.0.5.12"]','device_version_gate')
    text=text.replace('1.0.4.12 或 1.0.5.12 有效回读','1.0.5.12 有效回读')
    file.write_text(text,encoding='utf-8',newline='\n')
    # A separate bundle prevents replacing the user's installed App Store app.
    # Preserve inspected version/build/UUID and exact route checks.
    for name in ('OTAHost.h','OTAHostTests.m'):
        file=target/name;text=file.read_text(encoding='utf-8')
        require('com.rayneo.venus.pub' in text,'missing_original_host_id')
        file.write_text(text.replace('com.rayneo.venus.pub',BUNDLE),encoding='utf-8',newline='\n')
    file=target/'ExperimentalOTAFlashTests.m';text=file.read_text(encoding='utf-8')
    text=replace_once(text,'slices==340&&total==17024077',
                      f"slices=={candidate['completePayloadSlices']}&&total=={candidate['completePayloadBytes']}",'slice_inventory')
    text=replace_once(text,'    NSUInteger slices=0,total=0;', '''    for(NSString *wrongVersion in @[@"Strix OS 1.0.5.5",@"Strix OS 1.0.4.12",@"Strix OS 1.0.6.0"]) {
        TIOOTAFlashGate *wrong=Ready(dir);
        assert([wrong allows:start device:@"TEST_DEVICE" uptime:11]);
        assert(![wrong allows:F(5,@{@"OtaVersion":wrongVersion},nil) device:@"TEST_DEVICE" uptime:12]);
        assert([wrong.status[@"stage"] intValue]==3);
    }
    NSUInteger slices=0,total=0;''','wrong_target_versions')
    file.write_text(text,encoding='utf-8',newline='\n')
    file=target/'test.py';text=file.read_text(encoding='utf-8')
    text=replace_once(text,"args=parser.parse_args()","parser.add_argument('--stock',type=Path,required=True)\nargs=parser.parse_args()",'stock_argument')
    begin=text.index('ROOT=P.parents[1]');end=text.index("out=P/'build/tests'",begin)
    auditor=Path(__file__).resolve().with_name('audit_firmware.py')
    text=text[:begin]+f"stock=args.stock\nsubprocess.run(['python3',{str(auditor)!r},'--stock',stock,'--candidate',args.firmware],check=True)\n"+text[end:]
    text=replace_once(text,"test('host',['HostCompatibilityTests.m'])", """test('host',['HostCompatibilityTests.m'])
# Synthetic route records exercise the runtime check without uploading an IPA.
with tempfile.TemporaryDirectory(prefix='turbo-host-test-') as tmp:
    import struct
    original=Path(tmp)/'original';patched=Path(tmp)/'patched'
    data=bytearray(41206400)
    original.write_bytes(data)
    for offset,url,hashed in [(41206352,b'http://127.0.0.1:18794/g/xxxxxxxA78p2M',352684455),
                              (32115728,b'http://127.0.0.1:18794/g/xxxxxxxxxxCCXhB',555237387)]:
        struct.pack_into('<IQ',data,offset-12,hashed,len(url)*2)
        data[offset:offset+len(url)]=url
    patched.write_bytes(data)
    test('ota-host',['OTAHostTests.m'],[original,patched])""",'host_route_tests')
    file.write_text(text,encoding='utf-8',newline='\n')
    # Original signed packager is retained for reference but disabled here;
    # the separately audited Windows exporter produces an unsigned IPA.
    for name in ('package.mjs',):
        file=target/name
        file.write_text("throw new Error('Use the separate unsigned Windows exporter for this edition');\n",encoding='utf-8')
    (target/'README.md').write_text(
        '# Local iOS 1.0.7 / Strix 1.0.5.12 TMG3 development edition\n\n'
        'Generated from pinned upstream. This phone/firmware combination has not been device-tested.\n'
        'The stock 1.0.11 app is retained; this edition uses a different bundle ID.\n'
        'Exact firmware checks and manual, device-bound one-shot OTA remain enabled.\n'
        'No recovery or compatibility guarantee is implied.\n',encoding='utf-8')
    manifest=dict(upstream=UPSTREAM,hostVersion='1.0.7',hostBuild='230',bundle=BUNDLE,marker=MARKER,
                  firmwareSHA256=CANDIDATE_SHA,deviceSourceVersions=['Strix OS 1.0.5.12'],
                  modifiedFiles=sorted(set(changed+['test.py','README.md'])),
                  deviceIO=False,runtimeValidated=False,sideBySide=True,
                  sourceHashes={p.relative_to(target).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in target.rglob('*') if p.is_file() and p.suffix in ('.m','.h','.c','.sh')})
    (target/'local-build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in manifest.items() if k!='sourceHashes'},indent=2))
    return target

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source-root',required=True);p.add_argument('--stock',required=True);p.add_argument('--firmware',required=True)
    p.add_argument('--edition-name',default='ios107-tmg3-edition')
    a=p.parse_args();prepare(a.source_root,a.stock,a.firmware,a.edition_name)
