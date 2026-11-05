"""Prepare a fresh local IPA; never authenticates, signs, installs or flashes."""
import argparse
import hashlib
import json
import plistlib
import shutil
import stat
import subprocess
import zipfile
from pathlib import Path, PurePosixPath
from audit_firmware import require, audit, UPSTREAM, BUNDLE, MARKER, CANDIDATE_SHA

IPA_SHA='50df3954845e3bc2e34f9ba6def8c3837e9d1a6c232f36f3a975dd08152a3ff7'
PRIVATE_NAMES={'TurboIOPrivateBootstrap.json','TurboIOKnowledgeConnection.json','TIOAMapPrivate.json',
               'TurboIOPrivateTTS.json','TIOWeReadPrivate.json','TurboMusicCookieImport.txt','TurboWeReadCookieImport.txt'}
BASE=Path(__file__).resolve().parent

def digest(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def extract_ipa(source,destination):
    require(source.stat().st_size==353804631 and digest(source)==IPA_SHA,'input_ipa_identity_mismatch')
    with zipfile.ZipFile(source) as z:
        names=z.namelist();require(len(names)==len(set(names)),'duplicate_zip_paths')
        require(sum(i.file_size for i in z.infolist())<3_000_000_000,'unexpected_unpacked_size')
        for i in z.infolist():
            p=PurePosixPath(i.filename)
            require(not p.is_absolute() and '..' not in p.parts and '\\' not in i.filename and ':' not in i.filename,'unsafe_zip_path')
            require(not stat.S_ISLNK(i.external_attr>>16),'symlink_in_input')
            require(p.name not in PRIVATE_NAMES and 'PlugIns' not in p.parts,'private_settings_or_extensions')
            require('__MACOSX' not in p.parts and not p.name.startswith('._'),'unexpected_archive_metadata')
        require(z.testzip() is None,'input_zip_crc')
        z.extractall(destination)
    apps=list((destination/'Payload').glob('*.app'));require(len(apps)==1,'expected_one_app')
    app=apps[0];info=plistlib.loads((app/'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier')=='com.rayneo.venus.pub' and info.get('CFBundleShortVersionString')=='1.0.7'
            and str(info.get('CFBundleVersion'))=='230' and info.get('CFBundleExecutable')=='Runner','source_app_metadata')
    require(not any(k.startswith('TIO') for k in info),'already_modified_app')
    return app,info,len(names)

def run(a):
    out=a.out.resolve();source=a.ipa.resolve();edition=a.edition.resolve()
    require(not out.exists(),'output_must_be_new')
    profile=audit(a.stock,a.firmware)
    if not a.inspect_only:
        require(a.artifact is not None and a.recipe_commit,'build_artifact_and_commit_required')
        built=json.loads((a.artifact/'build-manifest.json').read_text())
        require(built['upstream']==UPSTREAM and built['bundle']==BUNDLE and built['marker']==MARKER
                and built['firmwareSHA256']==CANDIDATE_SHA and built['nativeTestsPassed']
                and built['buildRecipeCommit']==a.recipe_commit,'build_manifest_mismatch')
        native=json.loads((a.artifact/'native-test-report.json').read_text())
        require(native['passed'] and {'ota-host','archive','directory','flash','feed'}.issubset(native['groups']),'native_tests_missing')
        local=json.loads((edition/'local-build-manifest.json').read_text())
        require(local['sourceHashes']==built['sourceHashes'],'cloud_local_source_differ')
        for name,expected in built['sourceHashes'].items():
            require(digest(edition/name)==expected,'local_source_changed_'+name)
        addon=(a.artifact/'TurboIOPrivateAddon.dylib').resolve()
        require(digest(addon)==built['addonSHA256'],'addon_hash_mismatch')
    out.mkdir(parents=True,exist_ok=False)
    app,info,entries=extract_ipa(source,out/'unpacked')
    binary_report=out/'binary-report.json'
    subprocess.run(['node',str(BASE/'prepare_binaries.mjs'),str(edition),str(app),
                    '-' if a.inspect_only else str(addon),str(binary_report)],check=True)
    if a.inspect_only:
        (out/'inspection.json').write_text(json.dumps(dict(inputSHA256=IPA_SHA,entries=entries,version='1.0.7',build='230',
            binaryAudit=json.loads(binary_report.read_text()),sourcePreserved=True),indent=2)+'\n')
        print('INSPECTED_ONLY_NO_INSTALL_NO_FLASH');return
    info.update(CFBundleIdentifier=BUNDLE,CFBundleDisplayName='Turbo IO TMG3',
                TIOExperimentalOTAQueryRouting='ios107-tmg3-loopback-flash-gated',
                TIOPackagingRevision='APP107-TMG3-LOCAL-DEV01',TIOExperimentalOTABuild='TMG3')
    info['NSCameraUsageDescription']='用户主动开启眼镜遥控拍照时取景。'
    info['NSPhotoLibraryAddUsageDescription']='用户拍摄后保存照片。'
    info.setdefault('NSMicrophoneUsageDescription','用于用户主动开启的语音功能。')
    info.setdefault('NSAppTransportSecurity',{})['NSAllowsLocalNetworking']=True
    modes=info.setdefault('UIBackgroundModes',[])
    if 'audio' not in modes:modes.append('audio')
    if isinstance(info.get('UISupportedDevices'),list) and 'iPhone18,2' not in info['UISupportedDevices']:
        info['UISupportedDevices'].append('iPhone18,2')
    (app/'Info.plist').write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_BINARY,sort_keys=False))
    shutil.copytree(edition/'TurboIOArt',app/'TurboIOArt')
    shutil.copytree(edition/'tests/maps',app/'TurboHUDMaps')
    shutil.copyfile(edition.parent/'music/Beans-MIT-LICENSE.txt',app/'TurboMusic-Beans-MIT-LICENSE.txt')
    for name in ('LICENSE','NOTICE'):
        shutil.copyfile(edition.parents[1]/name,app/('TurboIO-'+name+'.txt'))
    shutil.copyfile(a.firmware,app/'TurboWeReadCandidate.zip')
    require(digest(app/'TurboWeReadCandidate.zip')==CANDIDATE_SHA,'packaged_firmware_mismatch')
    ipa=out/'TurboIO_1.0.7_TMG3_待签名.ipa'
    # Encode POSIX permissions explicitly; Windows extraction loses Unix mode bits.
    with zipfile.ZipFile(ipa,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for f in sorted((out/'unpacked/Payload').rglob('*')):
            if not f.is_file():continue
            name=f.relative_to(out/'unpacked').as_posix();data=f.read_bytes()
            binary=data.startswith(bytes.fromhex('cffaedfe'))
            entry=zipfile.ZipInfo(name);entry.create_system=3
            entry.external_attr=((stat.S_IFREG|(0o755 if binary else 0o644))<<16)
            entry.compress_type=zipfile.ZIP_DEFLATED
            z.writestr(entry,data,compresslevel=6)
    with zipfile.ZipFile(ipa) as z:
        require(z.testzip() is None,'output_zip_crc')
        packed_info=plistlib.loads(z.read(app.relative_to(out/'unpacked').as_posix()+'/Info.plist'))
        require(packed_info['CFBundleIdentifier']==BUNDLE,'packed_bundle_id')
    require(digest(source)==IPA_SHA,'input_source_changed')
    report=dict(status='UNSIGNED_NOT_INSTALLED',ipa=ipa.name,ipaSHA256=digest(ipa),ipaBytes=ipa.stat().st_size,
        inputPreserved=True,officialAppReplaced=False,appleCredentialsUsed=False,sourceUploaded=False,
        originalHost='1.0.7 (230)',bundle=BUNDLE,firmwareSHA256=CANDIDATE_SHA,buildRecipeCommit=a.recipe_commit,
        nativeTestsPassed=True,sideBySideIntent=True,amapEnabled=False,signed=False,
        installed=False,deviceIO=False,runtimeValidated=False,flashAuthorizedInApp=False,
        remaining=['Local Apple account signing with exact bundle ID','iPhone installation and launch',
                   'Glasses pairing and fresh version readback','Manual firmware transfer and hardware acceptance'])
    (out/'package-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for name in ('ipa','edition','stock','firmware','out'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--artifact',type=Path);p.add_argument('--recipe-commit');p.add_argument('--inspect-only',action='store_true')
    run(p.parse_args())
