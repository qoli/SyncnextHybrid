# AetherEngine HEVC MPEG-TS HLS VOD temporary workaround

Status: approved temporary downstream patch

Upstream tracker: https://github.com/superuser404notfound/AetherEngine/issues/246

Baseline: AetherEngine `5.29.0` (`38c480e2c64ec6911a0c2a9246e50ae63856bd77`)

## Problem and boundary

For a finite HLS VOD whose MPEG-TS PMT declares HEVC (`stream_type 0x24`),
AetherEngine 5.29.0 changes an explicit `nativeRemoteHLS=false` decision back to
the native remote-HLS path after recognizing the playlist. On the affected tvOS
device that path reaches `readyToPlay` but renders black.

SyncnextHybrid must choose the route before its single `engine.load()` call.
It therefore inspects the finite media playlist and the first TS PMT. Only a
confirmed HEVC MPEG-TS VOD disables native remote HLS and forces the AVKit UI
proxy. Live playlists remain on the existing native route; this workaround does
not use HLSLive.

## Patch responsibility

`Patches/AetherEngine/0003-hevc-mpegts-hls-vod-remux-workaround.patch` adds:

- a bounded, header-preserving finite HLS MPEG-TS ingest reader;
- a time-seekable custom-reader seam used by AetherEngine's demuxer;
- an AetherEngine #246 branch that preserves the host's explicit
  `nativeRemoteHLS=false` choice and feeds that reader to the existing MPEG-TS
  to fMP4 loopback remux path.

The reader resolves a master playlist to the highest-bandwidth variant,
requires `#EXT-X-ENDLIST`, downloads at most four segments concurrently, commits
them in playlist order, and restarts from the segment containing a requested
seek time. AES-128 clear-key segments are supported through the existing
decryptor.

Unsupported inputs fail explicitly. The patch does not silently redirect:

- live or DVR playlists;
- fMP4 HLS containing `#EXT-X-MAP`;
- demuxed alternate-audio playlists;
- encryption methods other than the supported AES-128 form.

Signed media URLs and header values are intentionally absent from this file.

## Hybrid and AVKit proxy changes

The Hybrid layer keeps the Aether video surface attached even though the remux
backend exposes an internal loopback `AVPlayer`. Its separate AVKit proxy owns
transport UI only. Proxy changes make delayed rate observations order-safe,
defer clock correction across the pause-before-navigation window, avoid exact
clock corrections while both clocks are already playing at the same rate, and
wait for the proxy item to become ready before accepting playback rates. The
bundled black proxy is a 30 fps H.264 clip with silent AAC, so tvOS reports
fast-forward support and retains the audio-capable transport contract.

## Acceptance evidence

Physical device: study-room Apple TV (`AppleTV6,2`).

Fixture: `鹿鼎记修复版(粤)`, episode 01, signed MDD HEVC MPEG-TS HLS VOD.

- Direct AetherEngine remux: 4K HEVC video plus AAC audio, finite duration
  `2698.760`, startup progress, exact seek to `122.000`, and post-seek progress.
- Hybrid AVKit proxy at 1.0x: route `avKitProxy`, startup progress, exact seek to
  `122.000`, and post-seek progress.
- Hybrid AVKit proxy at 2.0x: requested rate `2.000`, startup progress, exact
  seek to `122.000`, and post-seek progress while the requested rate remained
  `2.000`.

The smoke logs identify the source only by SHA-256 and list header names without
values.

## Removal procedure

Remove this workaround when an AetherEngine release linked from issue #246
provides an upstream-supported, seekable finite-HLS non-native route.

1. Validate that release in an isolated worktree against the same title.
2. Prove startup, a long seek, post-seek progress, and 2.0x playback on the
   physical Apple TV with no downstream patch 0003.
3. Remove patch 0003 from `series` and `manifest.sha256`.
4. Remove the HEVC TS admission case and forced-proxy branch only if the upstream
   API now owns those decisions; keep generic proxy race fixes if they remain
   independently required.
5. Run `Scripts/apply-patches.sh` twice and rebuild the real Syncnext app.

Do not remove the workaround merely because a newer tag exists; removal requires
the physical acceptance evidence above.
