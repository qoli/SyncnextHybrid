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

Aether remains the owner of rendered video, audible audio, and the
authoritative media clock. The proxy player is only an AVKit UI endpoint.

`HybridAudioAnalysisStream` opens a separate FFmpeg cursor for the audible
selection captured when the request is made. It never reads the playback
demuxer or a playback tap. Output is mono, non-interleaved Float32 PCM at
48 kHz with a zero-based source sample position and explicit discontinuity.
Only one stream and one consumer are admitted per playback session.

Seekable HLS VOD is prepared as a bounded local cursor for the requested
range. The original headers and current native HLS audible selection are
preserved; Live/DVR playlists fail explicitly. V1 does not analyze protected,
SAMPLE-AES, or other encrypted HLS.

V1 is tvOS-only. Pure-audio sessions and proxy-route PiP/AirPlay are explicit
unsupported states. An analysis failure never changes playback route, audio
selection, or playback state.

## tvOS smoke player

[`Examples/HybridSmokePlayer`](Examples/HybridSmokePlayer) is a standalone
tvOS app that imports only SyncnextHybrid. It attaches Hybrid to a native
`AVPlayerViewController` and verifies real startup media progress, an explicit
seek, post-seek progress, route invariance, and current AVKit player binding.
It emits privacy-safe structured terminal evidence and never switches source,
route, or player after failure.

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

Latest validation:

- [AetherEngine 5.20.6 — blocked, pin not promoted](Docs/Reports/AETHERENGINE_5.20.6_UPSTREAM_VALIDATION_2026-07-25.md)
