"""Collect only public compiled code and verification evidence, never an IPA."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path
from audit_firmware import require, BUNDLE, MARKER
from amap_support import sdk_evidence, copy_resources, LINKED_SYMBOLS, VERSIONS

p=argparse.ArgumentParser();p.add_argument('--edition',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--amap-sdk-root',type=Path,required=True)
a=p.parse_args();src=a.edition;out=a.output
manifest=json.loads((src/'local-build-manifest.json').read_text())
tests=json.loads((src/'build/tests/report.json').read_text())
required_groups={'ota-host','archive','directory','flash','feed','dashboard-config-diagnostics'}
require(tests['passed'] and required_groups.issubset(tests['groups']),'native_tests_required')
dylib=src/'build/image-rx-lab/TurboIOPrivateAddon.dylib';data=dylib.read_bytes()
require((BUNDLE+'\0').encode() in data and ('display extension='+MARKER+';').encode() in data,'compiled_identity_mismatch')
amap=sdk_evidence(a.amap_sdk_root)
symbols=subprocess.check_output(['xcrun','nm','-gU',str(dylib)],text=True)
defined={line.split()[-1] for line in symbols.splitlines() if line.split()}
require(set(LINKED_SYMBOLS).issubset(defined),'amap_and_native_navigation_not_linked')
dependencies=subprocess.check_output(['xcrun','otool','-L',str(dylib)],text=True)
require(not any('AMap' in line for line in dependencies.splitlines()[1:]),'amap_requires_unpackaged_dynamic_framework')
amap['linkedSymbols']=list(LINKED_SYMBOLS)
amap['linkage']='static SDK code in addon; resource bundles packaged separately'
for name,expected in manifest['sourceHashes'].items():
    require(hashlib.sha256((src/name).read_bytes()).hexdigest()==expected,'compiled_source_changed_'+name)
manifest.update(addonSHA256=hashlib.sha256(data).hexdigest(),addonBytes=len(data),
    buildRecipeCommit=os.environ.get('GITHUB_SHA'),runId=os.environ.get('GITHUB_RUN_ID'),
    nativeTestsPassed=True,amapEnabled=bool(amap['linkedSymbols']),amap=amap,
    navigationRuntimeValidated=False,appleCredentialsUsed=False,ipaUploaded=False,
    signature='ad-hoc only; requires local device provisioning',
    xcode=subprocess.check_output(['xcodebuild','-version'],text=True).strip())
out.mkdir(exist_ok=False)
shutil.copyfile(dylib,out/dylib.name)
shutil.copyfile(src/'build/tests/report.json',out/'native-test-report.json')
resource_root=out/'AMapResources';resource_root.mkdir()
copy_resources(a.amap_sdk_root,resource_root,amap,sdk_layout=True)
(out/'AMap-SDK-NOTICE.txt').write_text(
    'AMap SDK dependencies are separate from the Turbo IO license.\n'
    'Reviewed SDK versions: '+json.dumps(VERSIONS,sort_keys=True)+'\n'
    'Terms: https://lbs.amap.com/pages/terms/\n'
    'Privacy: https://lbs.amap.com/pages/privacy/\n'
    'Downloads: https://lbs.amap.com/api/ios-navi-sdk/download\n'
    'The fixed archive hashes, header versions and file hashes are in build-manifest.json.\n'
    'No AMap account or API key was supplied during this build.\n'
    'SDK compilation does not establish navigation service authorization or device acceptance.\n',encoding='utf-8')
for name in ('LICENSE','NOTICE'):
    shutil.copyfile(src.parents[1]/name,out/name)
(out/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({k:v for k,v in manifest.items() if k not in ('sourceHashes','amap')},indent=2))
print(json.dumps({'amapVersions':amap['versions'],'linkedSymbols':amap['linkedSymbols'],
    'resourceTreeSHA256':{k:v['treeSHA256'] for k,v in amap['resources'].items()}},indent=2))
