# SyncnextHybrid

`SyncnextHybrid` is the only integration boundary between Syncnext and
[AetherEngine](https://github.com/superuser404notfound/AetherEngine). It keeps
the upstream player intact, presents it through native AVKit UI, and owns an
independent audio-analysis reader for Syncnext's intro detection.

The repository is source-first:

```text
Syncnext -> local SPM SyncnextHybrid
                       |- local SPM AetherEngine/
                       `- local SPM FFmpegBuild/
```

There is no XCFramework packaging step and no patched remote fork. Both
upstream repositories are pinned submodules. The only accepted changes to
those worktrees live in `Patches/`.

## Prepare a checkout

```sh
git clone --recurse-submodules https://github.com/qoli/SyncnextHybrid.git
cd SyncnextHybrid
./Scripts/apply-patches.sh
```

The script intentionally resets and cleans the two submodule worktrees before
reapplying the reviewed patch series. Do not keep formal changes only as dirty
submodule files.

## Integration

Add the local `SyncnextHybrid` directory as a Swift package. The app target
links and imports only `SyncnextHybrid`; AetherEngine and FFmpegBuild remain
implementation details.

`HybridPlaybackSession` always publishes an `AVPlayer`:

- when Aether publishes `currentAVPlayer`, Hybrid binds that exact player;
- otherwise Hybrid publishes a finite silent black AVPlayer for AVKit controls
  and installs Aether's video surface in `contentOverlayView`.

On the native route, Aether's published `AVPlayer` remains the native playback
timeline. On the proxy route, the HLS Proxy Server owns the AVKit-visible
duration, playhead, rate, seek generation, and waiting state; Aether remains
the controlled renderer and media-material provider. AVKit user navigation
uses an explicit fast path to notify Aether immediately while preserving the
same Server generation and acknowledgement gate.

Hybrid has an explicitly authorized manifest fallback for direct finite HLS
VOD media playlists whose `EXT-X-TARGETDURATION` is smaller than the rounded
maximum `EXTINF`. It raises the target to the ceiling of the longest segment
and serves the repaired manifest from a session-owned loopback listener.
Segments, keys and initialization resources remain at their original origins;
relative references use the effective manifest response URL and playback keeps
the original HTTP headers. Diagnostics record the trigger, old/new target,
original source identity and prepared source identity. Preparation and playback
failures remain explicit. Stop, cancellation, initialization failure and owner
release close the listener. Valid playlists, Live/DVR, master rendition graphs,
HEVC remux and existing encrypted-source admission keep their current paths.
Independent audio analysis continues to use the original source request.

On 2026-10-03 the original failing source was validated in HybridSmokePlayer
on tvOS 26.4 Simulator and the allowlisted Study TV running tvOS 26.6. Both
Hybrid runs recorded the `4 -> 12` target-duration fallback, stayed on
`nativeAVPlayer`, advanced two seconds at startup, landed at a ten-second seek,
and advanced two seconds afterward with terminal `run_passed`. The direct
Aether control failed with CoreMedia `-12642` on both surfaces. The package
suite passed 93 tests with two existing external-fixture skips. This is bounded
smoke evidence; Syncnext App acceptance and playback to EOS were not performed.

The same Study TV build then passed six additional movie HLS sources resolved
with `plugin_czzy`'s episode and iframe-player helpers from fresh Arc pages.
Every run advanced two seconds at startup, landed exactly at a programmatic
150-second seek, advanced two seconds afterward, stayed on `nativeAVPlayer`,
and recorded `run_passed`; fresh device captures showed PASS and video frames.
The four new Xiaohongshu sources exercised the authorized manifest fallback:

| Movie catalogue title | Segment host | Target duration | Study TV smoke |
| --- | --- | --- | --- |
| 一个部门的诞生（国语） | `picasso-static.xiaohongshu.com` | 4 → 11 | Passed |
| 大学炸弹客 | `picasso-static.xiaohongshu.com` | 4 → 9 | Passed |
| 坠落2：死点 | `picasso-static.xiaohongshu.com` | 4 → 15 | Passed |
| 逃出绝命街 | `picasso-static.xiaohongshu.com` | 4 → 12 | Passed |
| 仙逆剧场版弑仙之战 | `p3-cargo.ecombdimg.com` | 15, unchanged | Passed |
| 生化危机：爆发夜 | `file.icve.com.cn` | 10, unchanged | Passed |

All four Xiaohongshu originals also failed before progress with CoreMedia
`-12642` in a separate macOS AVPlayer probe using the same source headers;
this is a different validation surface from the repaired tvOS smoke runs.
Playlist host counts cover every listed segment URI. HTTP/FFprobe inspection
sampled three segments per movie (first, 150-second position and midpoint),
all HTTP 200 and H.264/AAC MPEG-TS despite `image/png` response types. This does
not establish reachability of every segment, playback to EOS, remote-control
seeking, or the Syncnext App's full plugin request/JavaScript bridge flow.
The two valid original playlists demonstrate that movie sources use multiple
CDNs and that this failure should not be attributed to the whole category.

The mounted playback presentation reports `.enteredBackground` and
`.becameActive` through `HybridPlaybackSession.handleLifecycle(_:)`. Hybrid
captures the authoritative transport intent before Aether performs its tvOS
background teardown, then calls `reloadAtCurrentPosition()` exactly once for
that background epoch, restores the existing native or Proxy route, and
reapplies playing or paused intent. Duplicate active notifications are no-ops;
stopped sessions reject recovery; rebuild failures publish a typed terminal
snapshot. The App must not replace this contract with source re-resolution, a
new session, or a hidden retry.

See
[`Docs/AVKIT_UI_PROXY_TIMELINE_MODEL.md`](Docs/AVKIT_UI_PROXY_TIMELINE_MODEL.md)
for the authority boundaries, seek event ordering, thumbnail suppression,
known-invalid approaches, observability contract, and physical-device
acceptance procedure.

Bounded fingerprint PCM is mono, non-interleaved Float32 at 48 kHz.
Seekable HLS VOD is prepared as a bounded cursor for the requested range,
with original headers and the captured audible selection. Live/DVR and
unsupported encrypted sources fail explicitly.

Hybrid playback is tvOS-only. Pure-audio sessions and proxy-route PiP/AirPlay
are explicit unsupported states. Analysis failures never change playback route,
audio selection or playback state.

Fingerprint v2 uses `HybridPlaybackSession.fingerprintAudio(request:)` for
bounded timestamped PCM. The request specifies front/back, source-time range and
deadline. HEVC loopback VOD front uses `SegmentCache`; back uses the existing
independent HLS provider. Other admissions retain their providers. Audio selection
is captured for the request; playback audio changes do not invalidate an acquired
batch. Session stop, source replacement, unavailable or incomplete material remain
explicit failures.

`fingerprintArtifact(request:label:onProgress:)` composes the existing PCM and
file matcher entrypoints. Successful default acquisition uses
`RepeatedSegmentFingerprint.compute(audioBatch:)`. Only source/coverage acquisition
failures may invoke the explicitly user-authorized `HybridIntroAudioExtractor.extract(request:)`
once, then `RepeatedSegmentFingerprint.compute(audioFileURL:)`. Invalid input,
unsupported Live/DVR, unbound audio, lifecycle failure, cancellation and expired
budget do not start extraction. Matching errors do not trigger another acquisition.
The extractor retains its existing artifact gate and remux lifecycle, accepts the
captured audible selection, uses the existing bounded HLS window and reports the
actual first packet source time. Source admission may inspect the first segment;
range extraction downloads only its window. The AAC file is temporary and removed
by the caller. Other audio codecs fail explicitly; there is no new decoder, skip
algorithm, Aether API or patch. Existing blocking-I/O timeouts and cooperative
cancellation remain; returning a deadline error is not a new hard-interrupt guarantee.

## tvOS smoke player

[`Examples/HybridSmokePlayer`](Examples/HybridSmokePlayer) is a standalone
tvOS diagnostic app with explicit `aetherEngine` and `hybridAVKit` modes.
The default Aether baseline directly renders `AetherPlayerSurface` so
AetherEngine playback can be tested without the AVKit proxy; the Hybrid mode
retains the production-facing `AVPlayerViewController` path for comparison.
The smoke target's direct local AetherEngine link is a diagnostic exception:
Syncnext production still imports only SyncnextHybrid. Both modes verify real
startup progress, seek, and post-seek progress, emit privacy-safe structured
terminal evidence, and never switch mode, source, route, or player after
failure. The Aether overlay also provides an explicit diagnostic seek button;
using it cancels the bounded automation before moving the engine clock so a
manual jump cannot create a false smoke PASS.

The current smoke contract is defined by the checked-in app source, tests, and
[`Examples/HybridSmokePlayer/README.md`](Examples/HybridSmokePlayer/README.md).
The original implementation evidence is a dated historical report:
[`HYBRID_SMOKE_PLAYER_IMPLEMENTATION_2026-07-25.md`](Docs/Reports/HYBRID_SMOKE_PLAYER_IMPLEMENTATION_2026-07-25.md).

For the proxy route, the automated seek enters Hybrid through
`AVPlayerViewControllerDelegate`'s user-navigation callback. Hybrid does not
interpret `AVPlayerItem.timeJumpedNotification` as user intent because the
proxy's own mirrored seeks and clock corrections emit the same notification.
The regression contract includes an approximately 120-second navigation,
exact landing, and continued authoritative media-time progress.

## Upstream update

Follow [`Docs/HYBRID_MAINTENANCE_SOP.md`](Docs/HYBRID_MAINTENANCE_SOP.md).
The official AetherEngine Releases page determines the update candidate; the
release tag must then be resolved to a full commit SHA from the official
remote.

Existing patches must be validated unchanged first. If a patch no longer
applies or its semantics have drifted, stop the update and discuss the
necessity, alternatives, long-term cost, and exact minimal boundary with the
developer before changing any patch or upstream-owned source. Never commit or
push a patched AetherEngine or FFmpegBuild submodule.

Current code baseline:

- `Versions.env` pins AetherEngine `7.28.3`
  (`3cc256a0c1b9d9ec5302fac3f48b3c04cb9ab3e5`) and FFmpegBuild `3.6.0`
  (`fda08325455bc12c112b5b82d014b98fa0fee0be`).
- `Package.swift` requires tvOS 18 and macOS 15. Playback integration remains
  tvOS-only; macOS supports the non-playback package and test surfaces.
- The active AetherEngine series is exactly `0001`, `0002`, and `0004`.
  Historical `0003` was removed after AetherEngine 6.4.2 superseded it.
- [AetherEngine 7.28.3 — promoted on 2026-10-07](Docs/Reports/AETHERENGINE_7.28.3_UPSTREAM_VALIDATION_2026-10-07.md)

Historical validation reports describe their dated candidates, not the current
repository state:

- [AetherEngine 6.74.0](Docs/Reports/AETHERENGINE_6.74.0_UPSTREAM_VALIDATION_2026-09-09.md)
- [AetherEngine 6.4.2](Docs/Reports/AETHERENGINE_6.4.2_UPSTREAM_VALIDATION_2026-08-06.md)
- [AetherEngine 5.20.6 — blocked, not promoted](Docs/Reports/AETHERENGINE_5.20.6_UPSTREAM_VALIDATION_2026-07-25.md)
