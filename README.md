# IO Companion independent iPhone app and legacy Turbo IO build recipes

This repository contains public build instructions and source transformations only.
It does not contain an IPA, Apple credentials, signing certificates, private settings,
or device identifiers. The independent-app workflow produces an unsigned IPA as a
temporary Actions artifact; the older workflow produces an addon for the host app.

## Independent app: IO伴侣 0.1.0 / IO-COMPANION-DEV01

`standalone.yml` exports pinned upstream source into an isolated build directory,
verifies dependency hashes, applies `companion-overrides`, runs the dashboard logic
checks and simulator unit tests, then builds an unsigned arm64 device app. Its
separate bundle identifier is `com.leo.iocompanion`; the Swift module remains
`RayNeoCompanion`. There is no original IPA or firmware input in this pipeline.

The first build provides five phone tabs, local text notes with import/export and
an explicit teleprompter handoff, phone dashboard data with freshness indicators,
connection controls and manually enabled AI voice service configuration. Navigation
is explicitly pending. The ambient conversation feature currently contains only a
text model and tests: timestamped ASR text, optional anonymous speaker labels and
uncertainty markers. Capture, transcription and transcript storage are not connected.

Simulator tests and screenshots are not evidence of compatibility with real glasses.
Pairing, teleprompter controls, glasses dashboard updates, navigation, ambient speech
transcription and background behavior require separate physical acceptance. Opening
the new root UI does not automatically scan, pair or start voice standby.

The app retains upstream and third-party notices. Device communications reuse the
vendor frameworks described in the pinned source; this is not a clean-room SDK.
Unsigned output must be locally signed before installation. No installation or
firmware operation is performed by the build workflow.

## Legacy Turbo IO iOS 1.0.7 / TMG3 addon recipe

Inputs are pinned to Turbo1123/Turbo-IO commit
`f983669a2db1c2a658f7d4c50285b81aa074345a` and the public Strix OS 1.0.5.12
TMG3 release from Fnckerpoi/Cheater-IO. Firmware archive hashes, all payloads,
and changes against the stock archive are verified before any build.

This phone-app feature update needs device acceptance for its new dashboard diagnostics
and AMap navigation. Compilation and offline tests do not establish on-glasses behavior.
The local edition uses `com.turboio.rayneo.tmg3.local` to retain the App Store app.
Only observed Strix OS 1.0.5.12 is admitted. Exact payload validation and manual,
device-bound, one-shot flash permission remain enforced. No rollback guarantee.

The earlier flash build rejected every unscoped `rayneonet_sendFile`, including the
official teleprompter's normal manuscript transfer, even when no OTA was active.
This edition adds a narrow, short-lived manuscript permission following a business-20
prepare request. It validates the device, task/DID, announced UTF-8 byte length,
optional checksum and a regular text file inside the app container, and consumes
the permission once. OTA stages other than zero still reject these transfers.
Generic files and business-9 OTA writes retain their previous checks. Disconnects
and stop/new preparation events invalidate the old manuscript permission.
The 1 MiB validation cap is a local resource limit, not a claimed firmware limit.
The compiled repair is marked `TELE-FILE-FIX01`; physical transmission and lens
display must still be tested after installing this phone update.

The workflow runs native offline tests with AddressSanitizer/UndefinedBehaviorSanitizer,
including the required `dashboard-config-diagnostics` and `teleprompter-file-gate`
groups, then compiles with the
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
