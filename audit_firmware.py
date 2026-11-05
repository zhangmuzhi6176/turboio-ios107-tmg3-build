"""Read-only verification of two pinned public OTA archives; no device operations."""
import argparse
import hashlib
import json
import math
import zipfile
from pathlib import Path

UPSTREAM = 'f983669a2db1c2a658f7d4c50285b81aa074345a'
STOCK_SHA = 'b7bfd3cc73528e3e9995ad227dc877c8334d43dc8051436e2d2ccff2ca0b4133'
CANDIDATE_SHA = 'adf7a6fa6531c6246e0a067343310ac4c662ddd5b76fbe3aba457a8c4ac68c87'
STOCK_AP = 'af701a6525fbf703854b3d63e757734546c20bdb5d50e246867dc6a0565713ae'
CANDIDATE_AP = '20094d589b2453ba97ac764da625e86dcc78b4f76cb00f2a5fd5cba486187f3f'
BUNDLE = 'com.turboio.rayneo.tmg3.local'
MARKER = 'APP107-TMG3-PHONE-DEV01'

def require(condition, reason):
    if not condition:
        raise ValueError(reason)

def load(path, expected_hash, expected_size):
    path = Path(path)
    content = path.read_bytes()
    require(len(content) == expected_size, 'archive_size_mismatch')
    require(hashlib.sha256(content).hexdigest() == expected_hash, 'archive_hash_mismatch')
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        require(len(names) == len(set(names)) == 16, 'archive_members_mismatch')
        require(all(Path(n).name == n and '/' not in n and '\\' not in n for n in names), 'unsafe_archive_path')
        require(sum(i.file_size for i in z.infolist()) < 64 * 1024**2, 'expanded_archive_limit')
        require(z.testzip() is None, 'zip_crc_failed')
        files = {name: z.read(name) for name in names}
    rows = json.loads(files['OtaFileInfo.json'])
    require(isinstance(rows, list) and len(rows) == 15, 'manifest_count')
    require(len({r['Name'] for r in rows}) == 15, 'duplicate_manifest_payload')
    require({r['Name'] for r in rows} == set(files) - {'OtaFileInfo.json'}, 'manifest_members')
    for row in rows:
        data = files[row['Name']]
        require(len(data) == row['Size'], 'payload_size')
        require(hashlib.md5(data).hexdigest() == row['Md5'], 'payload_md5')
    return files, rows

def audit(stock, candidate):
    original, old_rows = load(stock, STOCK_SHA, 8769953)
    files, rows = load(candidate, CANDIDATE_SHA, 8869710)
    require(set(original) == set(files), 'member_set_changed')
    require(hashlib.sha256(original['nuttx_ap.bin']).hexdigest() == STOCK_AP, 'stock_ap_identity')
    require(hashlib.sha256(files['nuttx_ap.bin']).hexdigest() == CANDIDATE_AP, 'candidate_ap_identity')
    require(len(files['nuttx_ap.bin']) == 7515400, 'candidate_ap_size')
    require([n for n in sorted(files) if files[n] != original[n]] == ['OtaFileInfo.json', 'nuttx_ap.bin'], 'unexpected_changed_payload')
    old = {r['Name']: r for r in old_rows}
    for row in rows:
        prior = old[row['Name']]
        if row['Name'] == 'nuttx_ap.bin':
            require({k:v for k,v in row.items() if k not in ('Size','Md5')} ==
                    {k:v for k,v in prior.items() if k not in ('Size','Md5')}, 'ap_write_metadata_changed')
        else:
            require(row == prior, 'companion_manifest_changed')
    return dict(candidate='TMG3-127', version='1.0.5.12', archiveBytes=8869710,
                archiveSHA256=CANDIDATE_SHA, apBytes=7515400,
                apMD5=hashlib.md5(files['nuttx_ap.bin']).hexdigest(),
                unchangedCompanionPayloads=14, manifest=rows,
                payloadPins={n:[len(data),hashlib.sha256(data).hexdigest()] for n,data in sorted(files.items())},
                completePayloadBytes=sum(r['Size'] for r in rows),
                completePayloadSlices=sum(math.ceil(r['Size']/51200) for r in rows),
                archiveCRC='passed', deviceIO=False, runtimeValidated=False)

if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('--stock',required=True);p.add_argument('--candidate',required=True)
    p.add_argument('--out');a=p.parse_args();result=audit(a.stock,a.candidate)
    if a.out: Path(a.out).write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k not in ('manifest','payloadPins')},indent=2))
