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
AetherEngine, FFmpegBuild, or any Patch. Hybrid's read-only `SmokeTesting`
SPI supplies independent renderer-clock evidence for the tail acceptance;
production callers continue to use the normal playback interface.

## Smoke contract

Every run uses one explicit seekable VOD URL. The default `playbackSeek`
scenario follows this bounded contract:

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
For `avKitProxy` in the default scenario, automation does not call `HybridPlaybackSession.seek(to:)`
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

### Tail seek and replay acceptance

Set `HYBRID_SMOKE_SCENARIO=tailSeekReplay` with `hybridAVKit` and
`HYBRID_SMOKE_EXPECTED_ROUTE=avKitProxy` to exercise the automatic-skip
regression. Use the original source with `HYBRID_SMOKE_PRESEEK_SECONDS=1314`
and `HYBRID_SMOKE_SEEK_SECONDS=1343.34` (duration 1343.44 seconds).
The normal startup and optional preseek checks still run. The final seek has
a separate contract because remaining paused at the tail is the expected result:

1. While playing, call the same `session.seek(to:intent: .automaticSkip)` entry
   as the App's fingerprint skip. Require `.ended`, zero Server/client rate,
   and renderer, Server, and AVKit client clocks at the tail for ten seconds.
2. Explicitly call `session.replay()`, wait for the real AVKit client seek
   completion, and require all three clocks to land within one second of zero
   and then each advance by at least two seconds.
3. Repeat with `.position`, requiring `.paused` at the tail, then explicit replay.

The harness never pauses before either tail seek. It reads the renderer clock
through read-only `SmokeTesting` SPI; a Proxy snapshot alone would miss the
original renderer-at-zero/UI-at-end failure. `tail_hold_started`,
`tail_hold_passed`, `replay_landed`, and `replay_progress_passed` include the
independent renderer/client clocks, renderer phase, client rate, and Server
generation. No implicit rewind, route change, reload, or substituted source is
used to make a failed assertion pass. This scenario verifies the Hybrid skip
entry and clocks; fingerprint detection and audible output remain separate
acceptance surfaces.

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
| `HYBRID_SMOKE_SCENARIO` | Optional `playbackSeek` (default) or `tailSeekReplay`; the latter requires Hybrid and asserts the Proxy route |
| `HYBRID_SMOKE_URL` | Required when any `HYBRID_SMOKE_*` automation value is present |
| `HYBRID_SMOKE_HEADERS_JSON` | Optional JSON object whose values must all be strings |
| `HYBRID_SMOKE_SEEK_SECONDS` | Optional; fixed contract default is `10` |
| `HYBRID_SMOKE_PRESEEK_SECONDS` | Optional first seek target; when present, the configured final seek can prove a real backward seek |
| `HYBRID_SMOKE_RATE` | Optional playback rate in `(0, 4]`; fixed contract default is `1` |
| `HYBRID_SMOKE_HELD_SOURCE_CONNECTION` | Optional explicit `true` or `false` (default); forwards the source-scoped persistent HTTP/1.1 policy to both modes |
| `HYBRID_SMOKE_OBSERVATION_SECONDS` | Optional positive finite media progress required after seek recovery, before terminal PASS; emits 15-second checkpoints, fails on player error, early EOS, or failure to reach that progress within the requested duration at the selected rate plus the existing 60.5-second progress allowance |
| `HYBRID_SMOKE_EXPECTED_ROUTE` | Optional `nativeAVPlayer` or `avKitProxy` assertion; valid only in `hybridAVKit` mode |
| `HYBRID_SMOKE_OBJECT_AUDIO` | Optional `off` (default), `5.1.2`, `5.1.4`, `7.1.2`, `7.1.4`, or `9.1.6`; explicitly forwards the APAC speaker layout to both modes |
| `HYBRID_SMOKE_DUAL_LAYER_DOLBY_VISION` | Optional `true` or `false` (default); explicitly forwards the FEL preference to both modes |
| `HYBRID_SMOKE_THUMBNAIL_SECONDS` | Optional finite non-negative cache timestamp, Hybrid only; requires an available cache-backed thumbnail, displays it, and emits its actual dimensions |
| `HYBRID_SMOKE_FINGERPRINT_START_SECONDS` | Optional fingerprint PCM range start; requires the end and expected provider values |
| `HYBRID_SMOKE_FINGERPRINT_END_SECONDS` | Optional fingerprint PCM range end; the range must be no longer than 180 seconds |
| `HYBRID_SMOKE_EXPECTED_FINGERPRINT_PROVIDER` | Required with a fingerprint range; exactly `segmentCache`, `independentRemoteHLS`, or `independentDemuxer` |

Missing/unknown mode and `aetherEngine` combined with an expected Hybrid route
are configuration failures. Set the expected route only when the Hybrid
fixture and target-device contract are known. A mismatch is terminal; the app
does not rerun on the observed route.

When the three fingerprint values are supplied in `hybridAVKit` mode, the app
requests PCM from the active `HybridPlaybackSession` during playback. It
requires the expected provider, mono Float32 48 kHz non-interleaved buffers,
continuous source time, requested-range coverage, and non-zero frames before
continuing to seek. The terminal `run_passed` record includes the provider,
frame and buffer counts, coverage, discontinuities, segment count, and timing.

The console emits one-line, sorted JSON records prefixed with
`HYBRID_SMOKE_EVENT`. Records include a SHA-256 source identity, mode, route,
phase, media time, duration, checkpoints, and the terminal result. Aether
records also include `aether_backend` and `aether_current_avplayer`. Records do
not include the source URL, query, or HTTP header values.

Every Hybrid run asserts that all four optional components are built and emits
`optional_components` with the compiled traits and requested playback options.
That event proves compilation and forwarding; ordinary H.264/AAC playback does
not prove TrueHD Atmos, DTS:X, or FEL presentation. The hosted test target also
runs the pinned upstream APAC encoder, object renderer, TrueHD/DTS:X metadata,
dual-layer routing, and DV still-colour suites. Its compilation conditions match
the four enabled traits. Tests guarded by `TrueHDReferenceRender` remain absent
from the executable; that measurement component must not ship.

Examples of required terminal events:

```text
HYBRID_SMOKE_EVENT {"event":"run_passed",...}
HYBRID_SMOKE_EVENT {"event":"run_failed",...}
```
