"""Generate a separate, narrowly pinned iOS 1.0.7/TMG3 edition from upstream."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path
from audit_firmware import audit, require, UPSTREAM, BUNDLE, MARKER, CANDIDATE_SHA

FEATURE_BASE_HASHES = {
    'EditorCodec.h': '2045c746721687b1966c57d1897be31025f8b0bf9ed365e06e1001bfca126d5d',
    'EditorCodec.m': '26a8a773395e7754e525bec58df1964dd72fbc05e3225d2ed4da57b93b8c1497',
    'EditorTransport.h': 'da326e0df3bb3eb7ebc9f3d874736d5ab489bddaf859ea18ddaf1870219e4518',
    'EditorTransport.m': 'ab27387793f66efb7ecfd12d7b2ad5e4820c1e1a54f2d1fa66a13320d9e6f463',
    'EditorUI.m': '9f409ba1ef8e236f7cca6f3316a9a9e6b32cd25260f4b791d7c79832cd8f753d',
    'ExperimentalOTAFlash.m': '2092fdca8959d4e545076a58771be4e1e248709c41a511021ff8565cde96b3b1',
    'TodoRuntime.m': '47d9f69af892e36c9592fb7e95a17d007346156da1fee373d3f1d86ac38a6ce2',
}

def apply_feature_overrides(target):
    """Apply reviewed phone-only changes after checking their exact input files."""
    overrides = Path(__file__).resolve().parent / 'addon-overrides'
    additions = {'DashboardConfigDiagnosticsTests.m', 'TeleprompterFileGate.h',
                 'TeleprompterFileGate.m', 'TeleprompterFileGateTests.m'}
    names = set(FEATURE_BASE_HASHES) | additions
    require(overrides.is_dir(), 'missing_feature_overrides')
    require({p.name for p in overrides.iterdir()} == names, 'unexpected_feature_override_inventory')
    for name in sorted(names):
        source = overrides / name
        require(source.is_file() and not source.is_symlink(), 'unsafe_feature_override_' + name)
        destination = target / name
        if name in FEATURE_BASE_HASHES:
            require(hashlib.sha256(destination.read_bytes()).hexdigest() == FEATURE_BASE_HASHES[name],
                    'feature_input_changed_' + name)
        else:
            require(not destination.exists(), 'unexpected_existing_feature_test')
        destination.write_text(source.read_text(encoding='utf-8'), encoding='utf-8', newline='\n')
    return sorted(names)

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
    # Upstream's ios107 export references this shared parser but omits the files.
    # Restore the public implementation directly from the same immutable commit.
    shared=['PrivateBootstrap.h','PrivateBootstrap.m']
    for name in shared:
        require(not (target/name).exists(),'unexpected_shared_file_'+name)
        (target/name).write_bytes(subprocess.check_output(command+['show','HEAD:official-addon/'+name]))
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
    file=target/'ExperimentalOTAFeed.m';text=file.read_text(encoding='utf-8')
    text=replace_once(text,'@[@"01.00.04.0012",@"01.00.05.0005"]','@[@"01.00.05.0012"]','feed_source_version')
    file.write_text(text,encoding='utf-8',newline='\n')
    file=target/'ExperimentalOTAFeedTests.m';text=file.read_text(encoding='utf-8')
    text=text.replace('01.00.04.0012','01.00.05.0012')
    text=replace_once(text,'@"Range: bytes=8842882-\\r\\n"',
        '[NSString stringWithFormat:@"Range: bytes=%lu-\\r\\n",(unsigned long)(zip.length-14)]','feed_range_tail')
    text=replace_once(text,'    NSData *zip=[NSData dataWithContentsOfURL:file];', '''    for(NSString *wrongVersion in @[@"01.00.04.0012",@"01.00.05.0005",@"01.00.06.0000"])
        assert(Query(port,[path stringByReplacingOccurrencesOfString:@"01.00.05.0012" withString:wrongVersion])[@"data"]==NSNull.null);
    NSData *zip=[NSData dataWithContentsOfURL:file];''','feed_rejects_other_versions')
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
    text=replace_once(text,"test('host',['HostCompatibilityTests.m'])",
        "test('host',['HostCompatibilityTests.m'])\n"
        "test('dashboard-config-diagnostics', ['DashboardConfigDiagnosticsTests.m', 'EditorCodec.m'], "
        "extra=['-DTCE_DIAGNOSTIC_TEST=1'])\n"
        "test('teleprompter-file-gate', ['TeleprompterFileGateTests.m', 'TeleprompterFileGate.m', 'TodoProtocol.m'])",'dashboard_diagnostic_tests')
    text=replace_once(text,"gate=['ExperimentalOTA.m','ExperimentalOTAFlash.m','ExperimentalOTAGuard.m']",
        "gate=['ExperimentalOTA.m','ExperimentalOTAFlash.m','ExperimentalOTAGuard.m',"
        "'TeleprompterFileGate.m','TodoProtocol.m']",'teleprompter_gate_test_dependencies')
    file.write_text(text,encoding='utf-8',newline='\n')
    file=target/'build.sh';text=file.read_text(encoding='utf-8')
    text=replace_once(text,'EditorModel.m EditorCodec.m EditorTransport.m',
        'EditorModel.m EditorCodec.m TeleprompterFileGate.m EditorTransport.m','teleprompter_gate_build')
    file.write_text(text,encoding='utf-8',newline='\n');changed.append('build.sh')
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
    changed.extend(apply_feature_overrides(target))
    manifest=dict(upstream=UPSTREAM,hostVersion='1.0.7',hostBuild='230',bundle=BUNDLE,marker=MARKER,
                  firmwareSHA256=CANDIDATE_SHA,deviceSourceVersions=['Strix OS 1.0.5.12'],
                  modifiedFiles=sorted(set(changed+['test.py','README.md'])),
                  restoredSharedFiles=shared,
                  deviceIO=False,runtimeValidated=False,sideBySide=True,
                  dashboardDiagnostics='DASH-CONFIG-DIAG01',
                  teleprompterFileFix='TELE-FILE-FIX01',
                  sourceHashes={p.relative_to(target).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in target.rglob('*') if p.is_file() and p.suffix in ('.m','.h','.c','.sh')})
    (target/'local-build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in manifest.items() if k!='sourceHashes'},indent=2))
    return target

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source-root',required=True);p.add_argument('--stock',required=True);p.add_argument('--firmware',required=True)
    p.add_argument('--edition-name',default='ios107-tmg3-edition')
    a=p.parse_args();prepare(a.source_root,a.stock,a.firmware,a.edition_name)
