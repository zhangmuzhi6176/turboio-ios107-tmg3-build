"""Collect only public compiled code and verification evidence, never an IPA."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path
from audit_firmware import require, BUNDLE, MARKER

p=argparse.ArgumentParser();p.add_argument('--edition',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();src=a.edition;out=a.output
manifest=json.loads((src/'local-build-manifest.json').read_text())
tests=json.loads((src/'build/tests/report.json').read_text())
require(tests['passed'] and 'ota-host' in tests['groups'] and 'flash' in tests['groups'],'native_tests_required')
dylib=src/'build/image-rx-lab/TurboIOPrivateAddon.dylib';data=dylib.read_bytes()
require((BUNDLE+'\0').encode() in data and ('display extension='+MARKER+';').encode() in data,'compiled_identity_mismatch')
for name,expected in manifest['sourceHashes'].items():
    require(hashlib.sha256((src/name).read_bytes()).hexdigest()==expected,'compiled_source_changed_'+name)
manifest.update(addonSHA256=hashlib.sha256(data).hexdigest(),addonBytes=len(data),
    buildRecipeCommit=os.environ.get('GITHUB_SHA'),runId=os.environ.get('GITHUB_RUN_ID'),
    nativeTestsPassed=True,amapEnabled=False,appleCredentialsUsed=False,ipaUploaded=False,
    signature='ad-hoc only; requires local device provisioning',
    xcode=subprocess.check_output(['xcodebuild','-version'],text=True).strip())
out.mkdir(exist_ok=False)
shutil.copyfile(dylib,out/dylib.name)
shutil.copyfile(src/'build/tests/report.json',out/'native-test-report.json')
for name in ('LICENSE','NOTICE'):
    shutil.copyfile(src.parents[1]/name,out/name)
(out/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({k:v for k,v in manifest.items() if k!='sourceHashes'},indent=2))
