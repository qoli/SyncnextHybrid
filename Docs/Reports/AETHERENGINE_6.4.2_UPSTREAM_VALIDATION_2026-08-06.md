# AetherEngine 6.4.2 upstream validation

Date: 2026-08-06

Decision: accepted for SyncnextHybrid integration with the known backward
restart issue explicitly excluded.

## Candidate identity

- AetherEngine release: `6.4.2`
- AetherEngine commit: `996d8d3b616039f8ce17ebd527df14a9b2cd6a21`
- FFmpegBuild release: `2.4.0`
- FFmpegBuild commit: `87a5655979b9d6fa9f4b8db69e0a7e8df9075639`
- Syncnext validation baseline: `9f6b7ae238ad801e558dc1c6cb4c475fac9ed92e`

Both upstream submodules retain their official remotes. AetherEngine's
unpatched package requires FFmpegBuild 2.4.0 and the downstream dependency
patch resolves that exact checkout through the sibling local path.

## Patch reconstruction

- `0001-local-ffmpegbuild.patch` was rebuilt with its original one-line local
  dependency responsibility.
- `0002-independent-audio-source.patch` was rebuilt without expanding its
  independent-reader responsibility.
- `0003-hevc-mpegts-hls-vod-remux-workaround.patch` was removed because 6.4.2
  owns the finite HEVC-in-MPEG-TS HLS ingest upstream.
- The patch series replayed twice from clean official commits with identical
  HEADs and diffs.

## Automated validation

- SyncnextHybrid tests: 39 passed.
- Aether segment-plan tests: 7 passed.
- Aether issue-268 ingest tests: 15 passed.
- Generic Hybrid tvOS builds passed.
- Signed HybridSmokePlayer and Syncnext device builds passed.

## Formal integration

The accepted candidate was transferred into the primary `SyncnextHybrid`
checkout. Its patch series was reapplied twice from the exact upstream pins;
both replays passed all 39 package tests and the generic tvOS build. The
primary HybridSmokePlayer then resolved LibDovi 2.0.0 and passed a generic
tvOS Simulator build.

The primary Syncnext checkout also resolved the local SyncnextHybrid package,
AetherEngine 6.4.2, FFmpegBuild 2.4.0, and LibDovi 2.0.0. Its full generic
tvOS Simulator build remains blocked by an unrelated pre-existing OpenList
consumer provenance mismatch: the committed consumer provenance is dated
2026-08-02 while the canonical adjacent artifact is dated 2026-08-06. The
OpenList verification phase rejected that mismatch as designed; it was not
modified or bypassed for this promotion.

## Physical Syncnext integration

Device class: authorized study-room Apple TV (`AppleTV6,2`).

Source shape: private finite HLS VOD, 270 MPEG-TS segments, HEVC video
(`stream_type 0x24`), AAC audio, duration `2698.760` seconds.

The production Syncnext history resolver mounted the source through
`avKitProxy`. Every navigation was submitted through the AVKit delegate,
acknowledged by the Hybrid HLS proxy, resolved to source segments, landed on
the requested media-time axis, and demonstrated post-seek progress.

Fast-forward seeks:

1. `1089.012` seconds
2. `1119.012` seconds
3. `1149.012` seconds
4. `1179.012` seconds

Long-distance forward seeks:

1. `1546.234` seconds
2. `1910.409` seconds
3. `2274.585` seconds
4. `2638.760` seconds

The four long-distance intervals were at least `364.175` seconds. Proxy seek
generation advanced monotonically from 2 through 9. The structured acceptance
stream contained four dispatched, four landed, and four UI-evidence events for
each seek group, one terminal pass, and zero failed events.

## Accepted boundary

Backward restart is a known behavior shared by the earlier 5.29.0 plus 0003
baseline and AetherEngine 6.4.2. It was not introduced by this promotion and
was explicitly excluded from this acceptance decision. It remains separate
follow-up work.

The device UI captures prove AVKit timeline positions but do not contain the
hardware AVPlayer video plane. They are not presented-frame evidence by
themselves; route, segment, landing, and continued authoritative media-time
evidence form the automated integration gate used here.
