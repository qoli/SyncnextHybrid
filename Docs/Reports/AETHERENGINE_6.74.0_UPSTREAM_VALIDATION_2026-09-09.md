# AetherEngine 6.74.0 upstream validation

Date: 2026-09-09

Status: owner approved promotion with a documented waiver for the known
direct-Aether seek issue. Two subsequently discovered 0004 timeline/range
failures were repaired under explicit owner approval. The final Patch passes
focused tests, reproducible clean replays, the non-zero-range study-TV smoke,
and the real EP03 -> EP04 golden flow. The strict machine verdict remains
`unsafe` solely because the evidence schema intentionally has no waiver state
for the known direct-Aether issue.

## Candidate identity

- AetherEngine release: `6.74.0`
- AetherEngine commit: `bb9a1dcd2a1bb9793d37ed8a6e80eaf0f880d8fd`
- FFmpegBuild release: `3.0.0`
- Validation device: authorized study-room Apple TV (`AppleTV6,2`, tvOS 26.6)

## Known issue KI-AE-2026-09-09-01

### Direct-Aether seek can return to seeking after an exact landing

On the HybridSmokePlayer `aetherEngine` mode, a programmatic seek can land at
the exact requested media time and briefly reach `.playing`, then receive a
second producer restart. The playback phase returns to `.seeking` and the
authoritative media clock stops advancing.

The issue is intermittent. It reproduced on both the current `6.46.0` baseline
and the `6.74.0` candidate with the same range-correct H.264/AAC progressive
fixture, `150` second pre-seek, `60` second final seek, device, and launch
contract. It is therefore not attributed as a regression introduced by 6.74.0.
The earliest affected version and the root cause remain unknown.

The issue is accepted as a known issue. On 2026-09-09 the owner explicitly
accepted this same-baseline risk and authorized promotion to 6.74.0. This does
not convert the failed `hybrid_smoke_aether` gate into a pass; it is a recorded
owner waiver outside the strict machine-verdict vocabulary.

Evidence is stored outside the repository under
`.validation/aether-6.74.0-20260909/evidence/`:

- `smoke-aether-candidate-6.74-cold-repro-1-console.log`
- `smoke-aether-baseline-6.46-attempt2-console.log`
- `smoke-fixture-requests.jsonl`

## Remaining acceptance

The following rows were completed independently of the known direct-Aether
issue:

- HybridSmokePlayer `hybridAVKit` native route: PASS;
- HybridSmokePlayer `hybridAVKit` AVKit proxy route: PASS;
- SyncNext tvOS build against the isolated Hybrid candidate: PASS;
- SyncNext native and proxy physical-device seek/EOS acceptance: PASS;
- final evidence-manifest and verdict generation: complete.

## HybridSmokePlayer route acceptance

The two Hybrid routes used the same signed 6.74.0 candidate build and the same
range-correct five-minute fixture family on the authorized study-room Apple TV.

The `nativeAVPlayer` case remained on that route through startup, a forward
seek to `150.000` seconds, a backward seek to `60.000` seconds, and two seconds
of authoritative post-seek media-time progress. The terminal event was
`run_passed`.

The `avKitProxy` case kept the AVKit controller binding and route stable. Both
seeks entered through `avkit_user_navigation`; the final backward seek landed
at `60.040` seconds and advanced to `62.055` seconds. The terminal event was
`run_passed`.

Evidence:

- `smoke-hybrid-native-6.74-console.log`
- `smoke-hybrid-proxy-6.74-console.log`
- `smoke-fixture-requests.jsonl`

## SyncNext build and physical acceptance

An isolated SyncNext worktree resolved `SyncnextHybrid`, `AetherEngine`, and
`FFmpegBuild` from the sibling 6.74.0 candidate worktree. The canonical pinned
OpenList framework qualification passed before the build.

The first signed build attempt omitted the explicit canonical OpenList root and
was rejected by the framework verification phase because an isolated sibling
checkout did not exist. This was classified as build infrastructure. Repeating
the identical build with the already verified
`OPENLIST_TVOS_FRAMEWORK_ROOT` passed and produced the signed app used by the
device runner.

Two five-minute format cases completed on the study-room Apple TV:

| Case | Route | Seeks | Terminal |
| --- | --- | --- | --- |
| H.264/AAC progressive MP4 | `nativeAVPlayer` | `150` then `60` seconds | PASS, clean EOS |
| interlaced MPEG-2/AC-3 Matroska | `avKitProxy` | `150` then `60` seconds | PASS, clean EOS |

Both cases preserved their expected route, produced the required video-output
checkpoints, demonstrated continuous authoritative media-time progress after
each seek, and reached EOS. The runner summary contains `2 passed` and zero
non-passing classifications.

Evidence:

- `syncnext-openlist-prepare.log`
- `syncnext-candidate-device-build-rerun.log`
- `syncnext-device-acceptance/summary.json`
- `syncnext-device-acceptance/cases/`

## Patch compatibility assessment

The 6.74.0 candidate applies three downstream patches. Their manifest hashes,
clean simulations, and two destructive replays were identical.

| Responsibility | Result | Evidence and boundary |
| --- | --- | --- |
| `0001-local-ffmpegbuild` | PASS | The package graph resolves exactly one sibling FFmpegBuild 3.0.0 checkout, uses the renamed `AetherLibav*` products, and contains no remote duplicate. Hybrid tests and macOS/tvOS builds pass. |
| `0002-independent-audio-source` | PASS | Independent demux decode/resample and dedicated finite-HLS audio cursor tests pass in both replays. Invalid/deadline/range behavior remains explicit rather than falling back. |
| `0004-cache-backed-fingerprint-audio` | PASS, including real golden | Hybrid cache-backed PCM/fingerprint tests pass. Patched AetherEngine `SegmentCacheTests` pass 24/24, covering bounded lookahead and per-segment audio timeline metadata lifecycle. Two clean full Patch replays and the final main-checkout replay each pass 71 tests and the tvOS build. The final 0004 passes both the study-TV non-zero-range segment-cache smoke and the real EP03 -> EP04 golden flow. |

The former `0003-hevc-mpegts-hls-vod-remux-workaround` is not an active
downstream patch. It was removed at AetherEngine 6.4.2 after upstream absorbed
the responsibility. The upstream fix commit remains an ancestor of 6.74.0;
the 6.74.0 `Issue268HLSVODIngestTests` pass 15/15 and Hybrid admission tests
still select the Aether remux path for positively identified finite HEVC
MPEG-TS VOD.

Post-promotion revalidation initially found a 0004 compatibility failure on the
HEVC-in-MPEG-TS physical-device fixture. Three clean launches selected
`provider=segmentCache`; a request for source range `20.000...32.000` selected
nominal cache segments `4...7` and decoded 128 PCM buffers covering only
`15.507...31.507`. The reader correctly emitted `incompleteRange` rather than
returning partial PCM. This bounded the broken seam to the last-segment
selection contract under the 6.74.0 presentation-axis shift.

The owner approved a minimal Patch rebuild. The repaired reader preserves the
nominal last index, permits at most one bounded lookahead segment, extends only
the analysis producer demand, and stops as soon as decoded PCM covers the
requested upper bound (within the existing 50 ms tolerance). It does not move
the playback consumer target, change provider selection, or add fallback.

The regenerated Patch was replayed twice from the clean pinned upstream commit;
both runs produced the same patched-source digest. On the authorized study-room
Apple TV, the same `20.000...32.000` request completed from `segmentCache` with
5 decoded segments, 97 buffers, coverage through `32.019`, and zero
discontinuities. The proxy route then completed the `150` to `60` second seek
with `0.006` seconds landing error and emitted `run_passed`.

The later real golden run used 埋堆堆 `陀槍師姐`, EP03 -> EP04, on the same
authorized study-room Apple TV. The saved manual positions were `16.650875`
and `16.568689` seconds, a difference of about `82` ms, so the pair is a valid
cross-episode comparison. Runtime association selected EP04 ordinal 3, loaded
the EP03 fingerprint cache as `ready`, selected `provider=segmentCache`, and
requested the current `0.000...120.000` second front range. Preparation then
terminated with `artifactPreparationFailed`, `discontinuousRange`, and
`fallback=none`; no fingerprint match was produced.

The source media playlist has no `EXT-X-DISCONTINUITY`. Inspection of the
active loopback fragments instead places the first audio decode timestamp at
`3528 / 48000 = 0.0735` seconds. `CachedFingerprintAudioReader` initializes
coverage at the requested lower bound and permits only `0.05` seconds of
leading gap, so the absolute-zero request is rejected by `validateCoverage`.
This does not contradict the earlier `20.000...32.000` smoke: that request
began inside already-decoded audio and completed through its upper bound. The
failure identified a second incomplete 0004 responsibility: decoded fragment
audio was being mapped with the playlist display shift even though the muxer's
audio PTS rebase can differ from that presentation-axis shift.

The owner approved correcting that timeline contract. `HLSSegmentProducer`
now records each adopted fragment's actual audio mux-to-source shift alongside
the exact cached bytes. Replacement, disappearance, eviction, pruning, and
close remove or replace the metadata atomically with those bytes. The reader
still uses playlist display shift only to choose segment indices; each decoded
timestamp is mapped as `decodedPTS + audioSourceShift - sourcePresentationOrigin`.
Missing metadata fails explicitly as `segmentTimelineUnavailable`; there is no
fallback or guessed offset.

The final Patch adds focused coverage for the mapping, same-index epoch
replacement, absent metadata, and eviction. AetherEngine `SegmentCacheTests`
pass 24/24. Two clean isolated Patch replays and one final main-checkout replay
produce the same patched AetherEngine diff digest
`be7126d065e28a0c5c542cb4f32e0365fc2b5027fe79af301830a925d2f04816`;
each replay passes all 71 Hybrid tests (2 fixture-gated skips) and the generic
tvOS build.

On the study-room Apple TV, the corrected non-zero-range smoke remained green:
`20.000...32.000` returned 97 buffers / 582144 frames from five cache segments,
covering `19.936...32.064` with zero discontinuities, followed by a successful
`150` -> `60` seek and `run_passed`. The real `陀槍師姐` EP03 -> EP04 golden
flow then completed both matches with `provider=segmentCache` and
`fallback=none`: front score `0.770676` versus null threshold `0.541637`
(`1.000...77.300`), and back score `0.713699` versus `0.542694`
(`2500.940...2577.640`). Its terminal event was `phase=completed`, episode 4,
previous episode 3, with two matches.

## Formal verdict

All required gates except `hybrid_smoke_aether` now pass. The promotion
contract does not contain an "ignored" or "waived" gate state: any required
failed gate produces `unsafe`. KI-AE-2026-09-09-01 therefore remains visible as
a failed machine gate even though the owner separately accepted that known,
same-baseline risk and authorized promotion.

The machine-readable verdict is stored in
`.validation/aether-6.74.0-20260909/evidence/promotion-verdict.json`.

Supplementary Patch evidence:

- `aetherengine-segment-cache-tests.log` (`19/19` passed)
- `aetherengine-issue268-hls-vod-tests.log` (`15/15` passed)
- `0004-revalidation-console.log` (original uninstrumented FAIL)
- `0004-revalidation-attempt2-console.log` (second uninstrumented FAIL)
- `0004-revalidation-attempt3-console.log` (bounded coverage FAIL)
- `0004-rebuild-patch-verification.json` (read-only Patch verification)
- `0004-rebuild-apply-run1.log` and `0004-rebuild-apply-run2.log`
  (clean replays: 71 tests and tvOS build PASS)
- `0004-rebuild-run1-diff.sha256` and
  `0004-rebuild-run2-diff.sha256` (identical patched-source digest)
- `0004-rebuild-aether-segment-cache-tests.log` (`20/20` passed)
- `0004-rebuild-device-console.log` and `0004-rebuild-device-result.json`
  (range-complete fingerprint and terminal `run_passed`)
- `0004-rebuild-main-apply.log` (integrated main checkout replay PASS)
- `0004-golden-ep03-ep04/device-console.log` (real golden FAIL)
- `0004-golden-ep03-ep04/result.json` (sanitized golden verdict and diagnosis)
- `0004-axis-fix/main-segment-cache-tests.log` (`24/24` passed)
- `0004-axis-fix/main-apply.log` (final integrated replay: 71 tests and tvOS build PASS)
- `0004-axis-fix/smoke-console-rerun.log` (corrected non-zero-range `run_passed`)
- `0004-axis-fix/golden/device-console.log` (real golden completed with two matches)

## Device cleanup

After candidate acceptance, SyncNext was rebuilt from the main workspace
against its current AetherEngine 6.46.0 baseline and reinstalled successfully
on the authorized study-room Apple TV. The television was then sent the
repository-owned `OFF` command. The unsafe 6.74.0 candidate is therefore no
longer the installed SyncNext build.

The later rebuilt-0004 acceptance installed only HybridSmokePlayer on the same
authorized device. After its terminal `run_passed`, that smoke app was
uninstalled, the local fixture server was stopped, and the study-room Apple TV
was sent `OFF` again.

The real golden run temporarily installed the rebuilt-0004 SyncNext candidate.
EP04 playback was returned to `16.568` seconds after evidence collection (about
`0.689` ms from its pre-run saved position), the previously built 6.46.0
baseline App was reinstalled without removing the data container, temporary
device-data copies were deleted, and the study-room Apple TV was sent `OFF`.

The corrected-axis acceptance again used only the study-room Apple TV. After
the terminal golden result, EP04 was returned to `16.568` seconds, the exact
candidate process was terminated, the existing 6.46.0 baseline App was
reinstalled without deleting the data container, and installed-app readback
confirmed Syncnext `1.180` build `529`. The fixture server was stopped and the
television reported power state `Off`.

Cleanup evidence:

- `syncnext-baseline-openlist-prepare.log`
- `syncnext-baseline-6.46-restore-build-rerun.log`
- `0004-rebuild-device-uninstall.json`
- `0004-golden-ep03-ep04/baseline-restore-install.json`
- `0004-golden-ep03-ep04/baseline-restore-app-info.json`
- `0004-axis-fix/baseline-restore-install.json`
- `0004-axis-fix/baseline-restore-app-info.json`
