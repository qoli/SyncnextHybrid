# AetherEngine 7.28.3 upstream validation

Date: 2026-10-07

Status: the isolated candidate satisfies every required promotion gate. The
machine-readable verdict is `safe_to_promote`. Promotion was authorized on
2026-10-07; the accepted root commit is the promotion unit. No Syncnext release
operation was performed.

## Candidate identity

- AetherEngine release: `7.28.3`
- AetherEngine commit: `3cc256a0c1b9d9ec5302fac3f48b3c04cb9ab3e5`
- FFmpegBuild release: `3.6.0`
- FFmpegBuild commit: `fda08325455bc12c112b5b82d014b98fa0fee0be`
- Validation checkout:
  `.codex/worktrees/aether-7.28.3-validation`
- Physical-device surface: authorized study-room Apple TV (`AppleTV6,2`,
  tvOS 26.6)

The candidate was resolved from the official, non-draft, non-prerelease
AetherEngine release whose package requires FFmpegBuild 3.6.0. AetherEngine
7.28.3 also raises its platform floor to tvOS 18 and macOS 15, so the Hybrid
package and HybridSmokePlayer deployment targets were aligned to those floors.

Evidence is stored outside the tracked tree under
`.validation/aether-7.28.3-20261007/evidence/`.

## Patch compatibility

The 6.74-era patches did not apply directly to 7.28.3. Their approved
responsibilities were reconstructed against the new upstream source instead of
accepting fuzzy replay or retaining dead code.

| Patch | Result | Preserved responsibility |
| --- | --- | --- |
| `0001-local-ffmpegbuild.patch` | PASS | Keeps the package graph on the exact sibling FFmpegBuild checkout, using the current upstream product names. |
| `0002-independent-audio-source.patch` | PASS | Exposes the minimum independent, seekable VOD demux surface. Raw stream state is accessed through upstream's lifetime-safe `Demuxer.withStream` closure; Hybrid copies codec parameters and timebase before leaving that scope. |
| `0004-cache-backed-fingerprint-audio.patch` | PASS | Preserves bounded cache-backed PCM extraction with no URL fallback, generation-bound segment/timeline metadata, presentation-axis selection, per-fragment audio source shifts, one-segment bounded lookahead, and analysis demand that does not move the playback consumer target. Missing source-axis or segment metadata fails explicitly. |

The former `0003-hevc-mpegts-hls-vod-remux-workaround.patch` remains
retired. Upstream replaced that responsibility at AetherEngine 6.4.2; the
maintenance SOP now records the historical exit separately instead of listing
the patch as active.

Read-only patch verification replayed the complete AetherEngine and
FFmpegBuild series twice from the pinned commits. Both AetherEngine simulations
produced the same patched diff digest:
`75d1e8507e20de1213e5debdef45e61693e1703123015dfeb1e2a94e51a7114b`.
FFmpegBuild has no downstream patches. A second full destructive replay then
passed the tests and tvOS build from the clean pins.

Key evidence:

- `patch-verification-final.json`
- `apply-patches-run2.log`
- `dependency-graph-summary.json`

## Automated tests and builds

| Surface | Result | Boundary |
| --- | --- | --- |
| Hybrid Swift tests | PASS | 95 executed, 2 explicit fixture-gated skips, 0 failures. |
| AetherEngine SegmentCache focused tests | PASS | 25 of 25 tests passed, including exact-generation shift replacement, eviction, presentation-axis mapping, and analysis-demand behavior. |
| Dependency graph | PASS | Exactly one local FFmpegBuild 3.6.0 path and no remote FFmpegBuild URL. |
| Generic Hybrid tvOS build | PASS | Completed in the second clean Patch replay. |
| Signed HybridSmokePlayer build | PASS | Built against the isolated 7.28.3 candidate. |
| Signed Syncnext tvOS build | PASS | Built against the isolated Hybrid candidate after canonical OpenList requalification. |

The initial Syncnext acceptance runner correctly refused to install when a
separate restoration build had refreshed the shared canonical OpenList
provenance after the candidate build. Re-running the repository-owned OpenList
prepare/verify flow and rebuilding the same candidate produced the signed App
used by the successful runner. This was a build-provenance ordering issue, not
a playback failure, and no unqualified App was installed.

Evidence:

- `aetherengine-segment-cache-tests.log`
- `syncnext-candidate-openlist-prepare-rerun.log`
- `syncnext-candidate-device-build-rerun.log`
- `syncnext-device-acceptance-run2/runner-metadata-20261007-112839.json`

## HybridSmokePlayer physical-device acceptance

The three required modes used one signed candidate, the same SHA-bound local
fixture family, and the authorized study-room Apple TV. Every case emitted
exactly one terminal `run_passed` event.

| Mode | Observed route/authority | Result |
| --- | --- | --- |
| Direct Aether | Aether native backend | PASS; exact `150` then `60` second seek flow and 12.100 seconds post-seek progress. |
| Hybrid native | `nativeAVPlayer` | PASS; controller binding matched and post-seek progress reached 2.000 seconds. |
| Hybrid proxy | `avKitProxy` | PASS; controller binding matched, final landing was 60.046 seconds, and post-seek progress reached 2.041 seconds. |

Evidence:

- `smoke-aether-7.28.3-console.log`
- `smoke-hybrid-native-7.28.3-console.log`
- `smoke-hybrid-proxy-7.28.3-console.log`
- `smoke-terminal-summary.json`

## Syncnext physical-device seek and EOS acceptance

The repository-owned format runner installed the signed candidate and ran the
two exact five-minute fixtures. Both retained their expected route, completed
forward and backward seeks, demonstrated continuous post-seek media-time
progress, and reached EOS. The final summary is `2 passed` with zero failed or
blocked cases.

| Case | Route | Seek results | EOS result |
| --- | --- | --- | --- |
| H.264/AAC progressive MP4 | `nativeAVPlayer` | `150.000`, then `60.000`; both zero landing error with 2.000 seconds progress | Ended at 299.965 seconds after 237.964 healthy media seconds. |
| interlaced MPEG-2/AC-3 Matroska | `avKitProxy` | `150.000`, then `60.000`; both zero landing error with 2.146 / 2.051 seconds progress | Ended at 299.618 seconds after 237.500 healthy media seconds. |

Evidence:

- `syncnext-device-acceptance-run2/summary.json`
- `syncnext-device-acceptance-run2/cases/format-seek-5min-progressive-native-h264-aac/attempt-20261007-112849-e0767165/events.jsonl`
- `syncnext-device-acceptance-run2/cases/format-seek-5min-progressive-hybrid-mpeg2-interlaced-ac3/attempt-20261007-113307-36b56a23/events.jsonl`

## Supplemental segment-cache device smoke

An additional physical-device check attempted to request source range
`20...32` seconds from the cache-backed fingerprint path. It did not reach PCM
extraction: the HLS fixture failed during source loading on the native route
with CoreMedia error `-12927`.

The exact current-product AetherEngine 6.74 baseline was then built and run on
the same device with the same fixture and contract. It failed at the same
source-loading stage with the same error, before segment-cache analysis began.
This supplemental check is therefore recorded as `blocked` with attribution
`fixture_or_platform`, not as a 7.28.3 regression and not as a pass. The
required independent-audio gate remains supported by the passing focused
Hybrid and AetherEngine suites.

Evidence:

- `smoke-fingerprint-segment-cache-7.28.3-console.log`
- `smoke-fingerprint-segment-cache-baseline-6.74-console.log`
- `smoke-terminal-summary.json`

## Formal verdict

All twelve required gates pass:

- candidate identity;
- reproducible patch replay;
- local-only dependency graph;
- Hybrid tests;
- generic Hybrid tvOS build;
- direct-Aether, Hybrid native, and Hybrid proxy smoke modes;
- signed Syncnext tvOS build;
- Syncnext native and proxy seek/EOS acceptance;
- focused independent-audio behavior.

The machine verdict is `safe_to_promote`. The supplemental segment-cache
device smoke remains explicitly visible as blocked outside the required gate
set. Promotion still requires separate owner authorization.

Machine-readable evidence:

- `promotion-evidence.json`
- `promotion-verdict.json`

## Device restoration and cleanup

Only the authorized study-room Apple TV was targeted. After validation:

- Syncnext was restored to the pre-validation installed release `1.187`
  (`536`), with the existing data container preserved;
- installed-app readback confirmed that exact version/build;
- the restored App was launched and its normal UI was captured;
- HybridSmokePlayer was uninstalled and readback returned no matching App;
- the local fixture server was stopped; and
- the study-room Apple TV reported power state `Off` after the repository-owned
  power-control command.

No installation, launch, or other test mutation targeted the living-room Apple
TV.

A later, discarded downstream experiment for upstream issue #718 subsequently
reinstalled HybridSmokePlayer on the study-room Apple TV and left that device
awake. That experiment is not part of the promoted candidate. Its fixture
server was stopped, and it did not change the installed Syncnext version.

Cleanup evidence:

- `syncnext-installed-after-restore.json`
- `study-tv-after-restore.png`
- `hybrid-smoke-after-uninstall.json`
