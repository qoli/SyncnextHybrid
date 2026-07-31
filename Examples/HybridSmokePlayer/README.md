# Hybrid / Aether tvOS Smoke Player

This standalone diagnostic app has two explicit playback modes:

| Mode | Playback path |
| --- | --- |
| `aetherEngine` | A fresh `AetherEngine` rendered directly by `AetherPlayerSurface(engine:)` |
| `hybridAVKit` | `HybridPlaybackSession` attached to a native `AVPlayerViewController` |

The interactive page defaults to `aetherEngine`, so AetherEngine playback can
be verified independently of the AVKit proxy. The mode is fixed before the
player is created. A failed run never switches mode, source, route, or player.

The smoke target directly links the local `../../AetherEngine` product only as
a diagnostic exception. This does not change the production boundary:
Syncnext still links and imports only `SyncnextHybrid`. The app does not edit
SyncnextHybrid's public interface, AetherEngine, FFmpegBuild, or any Patch.

## Smoke contract

Every run uses one explicit seekable VOD URL and the same bounded contract:

1. Create exactly one player for the selected mode.
2. Within 30 seconds, require a paused snapshot with finite duration and valid
   initial media time.
3. Require authoritative media time to advance by at least two seconds within
   60.5 seconds.
4. Pause and seek to the explicit target, with a one-second landing tolerance.
   The Aether and native Hybrid routes use their direct session operation. The
   proxy route moves the proxy player and enters Hybrid through
   `AVPlayerViewControllerDelegate`'s user-navigation callback.
5. Resume and require another two seconds of media progress within 60.5
   seconds.

`aetherEngine` additionally requires a non-zero video size and a public
`playbackBackend` of `native` or `software`. It records
`currentAVPlayer` presence but does not use it for routing. Its `route` metric
is always `not_applicable`.

`hybridAVKit` additionally requires the Hybrid route to remain unchanged and
`AVPlayerViewController.player === session.avPlayer` throughout.
For `avKitProxy`, automation does not call `HybridPlaybackSession.seek(to:)`
or `play()` after the navigation. This prevents a direct session command from
masking a broken AVKit proxy path. The structured `seek_input` metric is
`avkit_user_navigation`; `seek_distance_seconds` records the exercised
distance. A representative regression uses an initial time near 2 seconds and
a target of 122 seconds.

`PASS` leaves playback active for visual inspection. Reset calls `stop()` and
releases the active engine or session. Configuration errors, Aether
initialization/load/backend/video/phase failure, typed Hybrid failure, early
EOS, presentation or route drift, AVKit binding drift, invalid time, seek
mismatch, or zero progress produce one terminal `FAIL`.

This is a bounded smoke test. It does not prove playback to EOS, presented
frames, HDR panel mode, audio/subtitle selection, independent audio analysis,
PiP, or AirPlay.

## Generate and build

From the SyncnextHybrid repository root:

```sh
./Scripts/apply-patches.sh
xcodegen generate --spec Examples/HybridSmokePlayer/project.yml
xcodebuild \
  -project Examples/HybridSmokePlayer/HybridSmokePlayer.xcodeproj \
  -scheme HybridSmokePlayer \
  -configuration Debug \
  -destination 'generic/platform=tvOS' \
  -derivedDataPath .build/HybridSmokePlayerDevice \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The generated Xcode project is checked in. Regenerate it whenever
`project.yml` changes.

### Xcode local-package ownership

Open `HybridSmokePlayer.xcodeproj` as the only Xcode project or workspace that
owns this local SyncnextHybrid checkout. Do not keep `SyncNext.xcodeproj`, the
SyncnextHybrid package, AetherEngine, or FFmpegBuild open in another Xcode
workspace at the same time.

Both SyncNext and HybridSmokePlayer intentionally resolve the same local
SyncnextHybrid checkout; the smoke project also resolves that checkout's one
local AetherEngine package. Xcode cannot load those packages into two
independent workspace documents concurrently. When this happens, Xcode first reports
`Couldn't load ... because it is already opened from another project or
workspace` and then reports the downstream error
`Missing package product 'SyncnextHybrid'`.

Close the other project or workspace and reopen only
`HybridSmokePlayer.xcodeproj`. This condition does not require deleting
DerivedData, resetting package caches, reapplying patches, or changing
AetherEngine or FFmpegBuild.

## Interactive run

Open `HybridSmokePlayer.xcodeproj`, select an Apple TV simulator or device,
configure signing if needed, and run. Enter:

- one explicit playback mode; `AetherEngine baseline` is selected by default;
- one absolute `http`, `https`, or sandbox-accessible `file` URL;
- optional HTTP headers as a JSON object with string values;
- one seek target in seconds.

The test-only app permits HTTP sources so it can reach an explicit LAN fixture.
It must not be distributed as a production application.

While an Aether presentation is active and its finite duration admits the
configured target, the overlay exposes `Seek → HH:MM:SS`. This diagnostic
operation first cancels the bounded automation so the manual time jump cannot
be misreported as natural startup progress. It pauses, seeks through
`AetherEngine.seek(to:)`, verifies the one-second landing tolerance, and
resumes only when playback had already been requested. The operation emits
`manual_seek_requested`, `manual_seek_landed`, `manual_seek_failed`, or
`manual_seek_cancelled`; it never switches to Hybrid.

Progressive HTTP fixtures must come from an origin with correct single-byte
Range support (`206`, `Accept-Ranges`, and `Content-Range`). Python's basic
`http.server` is not a valid progressive-media origin for this test. An origin
failure remains a source-load failure; the app does not download or substitute
another copy.

## Automated device launch

Build and install a signed app, then launch it with an explicit environment:

```sh
xcrun devicectl device process launch \
  --device <CoreDevice-ID> \
  --console \
  --environment-variables \
  '{
    "HYBRID_SMOKE_MODE": "aetherEngine",
    "HYBRID_SMOKE_URL":
      "http://<fixture-host>:<port>/<fixture-path>",
    "HYBRID_SMOKE_SEEK_SECONDS": "150"
  }' \
  com.qoli.SyncnextHybridSmoke
```

Supported environment values:

| Name | Contract |
| --- | --- |
| `HYBRID_SMOKE_MODE` | Required for automation; exactly `aetherEngine` or `hybridAVKit` |
| `HYBRID_SMOKE_URL` | Required when any `HYBRID_SMOKE_*` automation value is present |
| `HYBRID_SMOKE_HEADERS_JSON` | Optional JSON object whose values must all be strings |
| `HYBRID_SMOKE_SEEK_SECONDS` | Optional; fixed contract default is `10` |
| `HYBRID_SMOKE_RATE` | Optional playback rate in `(0, 4]`; fixed contract default is `1` |
| `HYBRID_SMOKE_EXPECTED_ROUTE` | Optional `nativeAVPlayer` or `avKitProxy` assertion; valid only in `hybridAVKit` mode |

Missing/unknown mode and `aetherEngine` combined with an expected Hybrid route
are configuration failures. Set the expected route only when the Hybrid
fixture and target-device contract are known. A mismatch is terminal; the app
does not rerun on the observed route.

The console emits one-line, sorted JSON records prefixed with
`HYBRID_SMOKE_EVENT`. Records include a SHA-256 source identity, mode, route,
phase, media time, duration, checkpoints, and the terminal result. Aether
records also include `aether_backend` and `aether_current_avplayer`. Records do
not include the source URL, query, or HTTP header values.

Examples of required terminal events:

```text
HYBRID_SMOKE_EVENT {"event":"run_passed",...}
HYBRID_SMOKE_EVENT {"event":"run_failed",...}
```

The dated implementation and Simulator results are recorded in
[`Docs/Reports/HYBRID_SMOKE_PLAYER_IMPLEMENTATION_2026-07-25.md`](../../Docs/Reports/HYBRID_SMOKE_PLAYER_IMPLEMENTATION_2026-07-25.md).
