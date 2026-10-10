# AetherEngine 7.33.2 upstream validation

Date: 2026-10-10

Status: accepted for promotion to `SyncnextHybrid/main`. Every required gate
passed and the machine verdict is `safe_to_promote`. No Syncnext release,
TestFlight upload, push, or publication is part of this promotion.

## Candidate identity

- AetherEngine release: `7.33.2`
- AetherEngine commit: `e7afcfad3973426a6ffff31fc111f6b1e5078061`
- FFmpegBuild release: `3.7.0`
- FFmpegBuild commit: `9baf6d00611548ddfbbabda19493d9ff36d336c1`
- Physical-device surface: authorized study-room Apple TV, tvOS 26.6, arm64

Evidence is stored outside the tracked tree under
`.validation/aether-7.33.2-20261010/` in the isolated Hybrid and Syncnext
worktrees.

## Patch compatibility

The existing downstream responsibilities were reconstructed against the
7.33.2 source instead of accepting fuzzy patch application. The active series
contains:

| Patch | Preserved responsibility |
| --- | --- |
| `0001-local-ffmpegbuild.patch` | Keeps AetherEngine on the exact sibling FFmpegBuild 3.7.0 checkout and prevents a remote duplicate. |
| `0002-independent-audio-source.patch` | Keeps the independent, seekable VOD audio source contract. |
| `0004-cache-backed-fingerprint-audio.patch` | Keeps bounded, cache-backed fingerprint PCM extraction on the current upstream cache model. |
| `0005-query-wrapped-hls-segment-ingest.patch` | Admits only finite HLS playlists whose query-wrapped MPEG-TS segment has positive HEVC evidence, streams those reads serially in bounded chunks, and keeps live, fMP4, H.264, encrypted, and ambiguous inputs on their existing routes. |

Two clean complete patch replays produced byte-identical patched states. The
manifest, official remotes, exact detached pins, local-only dependency graph,
tests, and generic tvOS build all passed.

## Automated validation

| Surface | Result |
| --- | --- |
| Query-wrapped HLS focused Aether tests | PASS: 22 executed, 0 failures. |
| SyncnextHybrid tests | PASS: 95 executed, 2 fixture-gated skips, 0 failures. |
| Generic Hybrid tvOS build | PASS. |
| HybridSmokePlayer direct Aether | PASS: startup, seek landing, and post-seek progress. |
| HybridSmokePlayer native route | PASS: `nativeAVPlayer` remained stable after seek. |
| HybridSmokePlayer proxy route | PASS: `avKitProxy` reached Aether and progressed after seek. |
| Signed Syncnext tvOS build | PASS against the isolated Hybrid checkout. |
| Independent audio contract | PASS in the replayed Hybrid suite. |

## Syncnext physical-device seek and EOS acceptance

The repository-owned acceptance runner installed the signed candidate only on
the authorized study-room Apple TV. Both selected five-minute fixtures kept
their expected route, completed forward and backward seeks, demonstrated
continuous post-seek media-time progress, and reached natural EOS. The final
summary is `2 passed, 0 non-passing`.

| Case | Route | Seek results | EOS result |
| --- | --- | --- | --- |
| H.264/AAC progressive MP4 | `nativeAVPlayer` | Forward and backward seek applied; 2.017 / 2.000 seconds post-seek progress. | Ended at 299.965 seconds with stable player, session, and source identity. |
| interlaced MPEG-2/AC-3 Matroska | `avKitProxy` | Forward and backward seek applied; 2.048 / 2.056 seconds post-seek progress. | Ended at 299.624 seconds with stable player, session, and source identity. |

Primary evidence:

- `promotion-evidence.json`
- Syncnext `syncnext-minimal-eos-run2/summary.json`
- Syncnext `syncnext-minimal-eos-run2/cases/*/events.jsonl`

## Live ONE boundary

The live ONE URL is supplemental failure evidence, not a replacement for the
fixed-route promotion gates. The observed Syncnext UI still reached only an
initial frame before stalling, so this validation does **not** claim that live
ONE playback is fixed or visually accepted. The temporary experiment that
disabled intro/outro analysis was fully reverted before promotion; no
intro/outro behavior change is included here.

## Formal verdict

All required promotion gates pass. The unpatched upstream baseline was not run
for this focused repair and remains diagnostic rather than a required gate.
The machine verdict is `safe_to_promote`.
