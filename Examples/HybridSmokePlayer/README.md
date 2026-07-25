# SyncnextHybrid tvOS Smoke Player

This standalone tvOS app tests SyncnextHybrid through the same public interface
used by Syncnext:

```text
HybridPlaybackRequest
  -> HybridPlaybackSession
  -> attach(to: AVPlayerViewController)
  -> authoritative snapshot and events
```

The app target imports only `SyncnextHybrid`. It does not import or edit
AetherEngine or FFmpegBuild, inspect Aether diagnostics, start another player,
switch source, or recover through another route.

## Smoke contract

One run uses one explicit seekable VOD URL:

1. Create and attach one `HybridPlaybackSession`.
2. Within 30 seconds, require a paused snapshot with finite duration and valid
   initial media time.
3. Require the authoritative Hybrid media time to advance by at least two
   seconds within 60.5 seconds.
4. Pause and seek to the explicit target, with a one-second landing tolerance.
5. Resume and require another two seconds of authoritative media progress
   within 60.5 seconds.
6. Require the Hybrid route to remain unchanged and
   `AVPlayerViewController.player === session.avPlayer` throughout.

`PASS` leaves playback active for visual and native AVKit interaction.
Configuration errors, typed Hybrid failure, early EOS, route drift, AVKit
binding drift, invalid time, seek mismatch, or zero progress produce one
terminal `FAIL`.

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
SyncnextHybrid package. Xcode cannot load that package into two independent
workspace documents concurrently. When this happens, Xcode first reports
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

- one absolute `http`, `https`, or sandbox-accessible `file` URL;
- optional HTTP headers as a JSON object with string values;
- one seek target in seconds.

The test-only app permits HTTP sources so it can reach an explicit LAN fixture.
It must not be distributed as a production application.

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
    "HYBRID_SMOKE_URL":
      "http://<fixture-host>:<port>/<fixture-path>",
    "HYBRID_SMOKE_SEEK_SECONDS": "150",
    "HYBRID_SMOKE_EXPECTED_ROUTE": "avKitProxy"
  }' \
  com.qoli.SyncnextHybridSmoke
```

Supported environment values:

| Name | Contract |
| --- | --- |
| `HYBRID_SMOKE_URL` | Required when any `HYBRID_SMOKE_*` automation value is present |
| `HYBRID_SMOKE_HEADERS_JSON` | Optional JSON object whose values must all be strings |
| `HYBRID_SMOKE_SEEK_SECONDS` | Optional; fixed contract default is `10` |
| `HYBRID_SMOKE_EXPECTED_ROUTE` | Optional `nativeAVPlayer` or `avKitProxy` assertion |

Set the expected route only when the fixture and target-device contract are
known. A mismatch is terminal; the app does not rerun on the observed route.

The console emits one-line, sorted JSON records prefixed with
`HYBRID_SMOKE_EVENT`. Records include a SHA-256 source identity, route, phase,
media time, duration, checkpoints, and the terminal result. They do not include
the source URL, query, or HTTP header values.

Examples of required terminal events:

```text
HYBRID_SMOKE_EVENT {"event":"run_passed",...}
HYBRID_SMOKE_EVENT {"event":"run_failed",...}
```

The dated implementation and Simulator results are recorded in
[`Docs/Reports/HYBRID_SMOKE_PLAYER_IMPLEMENTATION_2026-07-25.md`](../../Docs/Reports/HYBRID_SMOKE_PLAYER_IMPLEMENTATION_2026-07-25.md).
