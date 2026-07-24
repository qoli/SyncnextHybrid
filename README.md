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

## Upstream update

1. Update the submodule gitlinks and `Versions.env`.
2. Regenerate the smallest Aether patch on the new official commit.
3. Update `Patches/manifest.sha256`.
4. Run `./Scripts/apply-patches.sh` from a dirty, already-patched checkout.
5. Commit only the root repo's submodule SHA, patch files, manifest, and
   Hybrid changes. Do not commit or push the patched submodule worktree.
