# Turbo IO iOS 1.0.7 / TMG3 local build recipe

This repository contains public build instructions and source transformations only.
It does not contain an IPA, Apple credentials, signing certificates, private settings,
or device identifiers. GitHub Actions builds an ad-hoc addon, not an installable app.

Inputs are pinned to Turbo1123/Turbo-IO commit
`f983669a2db1c2a658f7d4c50285b81aa074345a` and the public Strix OS 1.0.5.12
TMG3 release from Fnckerpoi/Cheater-IO. Firmware archive hashes, all payloads,
and changes against the stock archive are verified before any build.

The iOS 1.0.7/230 host and TMG3 are a new development combination, **not device tested**.
The local edition uses `com.turboio.rayneo.tmg3.local` to retain the App Store app.
Only observed Strix OS 1.0.5.12 is admitted. Exact payload validation and manual,
device-bound, one-shot flash permission remain enforced. No rollback guarantee.

The workflow runs native offline tests with AddressSanitizer/UndefinedBehaviorSanitizer,
then compiles with the iOS SDK on a standard `macos-15` runner. AMap's optional SDK
and local translation models are excluded; no private API keys are needed to build.
Apple-account signing and IPA preparation happen separately on the local Windows PC.

Run manually in Actions. Artifact retention is three days. No scheduled jobs.

Required Notice: Copyright (c) 2026 Turbo IO contributors

Upstream-derived portions retain the PolyForm Noncommercial License 1.0.0;
see LICENSE and NOTICE. This recipe is for personal noncommercial preparation.

Upstream source, attribution and license: https://github.com/Turbo1123/Turbo-IO
TMG3 source: https://github.com/Turbo1123/Turbo-IO/pull/51
Firmware: https://github.com/Fnckerpoi/Cheater-IO/releases/tag/strix-1.0.5.12-tmg3-20261103
