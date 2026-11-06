# Turbo IO iOS 1.0.7 / TMG3 dashboard diagnostics and AMap build recipe

This repository contains public build instructions and source transformations only.
It does not contain an IPA, Apple credentials, signing certificates, private settings,
or device identifiers. GitHub Actions builds an ad-hoc addon, not an installable app.

Inputs are pinned to Turbo1123/Turbo-IO commit
`f983669a2db1c2a658f7d4c50285b81aa074345a` and the public Strix OS 1.0.5.12
TMG3 release from Fnckerpoi/Cheater-IO. Firmware archive hashes, all payloads,
and changes against the stock archive are verified before any build.

This phone-app feature update needs device acceptance for its new dashboard diagnostics
and AMap navigation. Compilation and offline tests do not establish on-glasses behavior.
The local edition uses `com.turboio.rayneo.tmg3.local` to retain the App Store app.
Only observed Strix OS 1.0.5.12 is admitted. Exact payload validation and manual,
device-bound, one-shot flash permission remain enforced. No rollback guarantee.

The workflow runs native offline tests with AddressSanitizer/UndefinedBehaviorSanitizer,
including the required `dashboard-config-diagnostics` group, then compiles with the
iOS SDK on a standard `macos-15` runner. It includes the explicitly reviewed AMap
Navi **11.3.100**, Foundation **1.9.4**, and Search **9.8.1** static SDKs. Local
translation models are excluded; no private API keys are needed to build.
Apple-account signing and IPA preparation happen separately on the local Windows PC.

`setup_amap_11_3_100.py` is an explicit SDK upgrade from upstream's 11.2.100/1.9.1
fetcher: the generic official navigation archive URL changed, so its old hash no
longer matches. The new script pins the reviewed outer and inner ZIP hashes,
checks SDK version headers, and rejects changed downloads. Framework binary hashes
and independent resource tree hashes are fixed in `amap_support.py`.
The three resource bundles (`AMap.bundle`, `AMapNavi.bundle`, `AMapSearch.bundle`)
are verified in the cloud artifact and again during local IPA preparation.
SDK archives stay in ignored `build/`; the source repository does not contain them.
AMap terms and privacy information are recorded with the build evidence:
https://lbs.amap.com/pages/terms/ and https://lbs.amap.com/pages/privacy/ .

Install this update over the existing custom iPhone app using its same bundle ID
and signing account. The host remains 1.0.7/230 and the bundled TMG3 archive is
unchanged. This feature update does **not** require reflashing glasses already on
TMG3. After installation, reconnect the glasses, inspect the dashboard diagnostic,
and separately configure an authorized AMap iOS Key and validate navigation.

Run manually in Actions. Artifact retention is three days. No scheduled jobs.

Required Notice: Copyright (c) 2026 Turbo IO contributors

Upstream-derived portions retain the PolyForm Noncommercial License 1.0.0;
see LICENSE and NOTICE. This recipe is for personal noncommercial preparation.

Upstream source, attribution and license: https://github.com/Turbo1123/Turbo-IO
TMG3 source: https://github.com/Turbo1123/Turbo-IO/pull/51
Firmware: https://github.com/Fnckerpoi/Cheater-IO/releases/tag/strix-1.0.5.12-tmg3-20261103
