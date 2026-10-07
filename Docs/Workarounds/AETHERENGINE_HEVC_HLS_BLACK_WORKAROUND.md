# AetherEngine HEVC MPEG-TS HLS VOD temporary workaround

Status: removed; superseded by AetherEngine 6.4.2

Upstream tracker: https://github.com/superuser404notfound/AetherEngine/issues/246

Baseline: AetherEngine `5.29.0` (`38c480e2c64ec6911a0c2a9246e50ae63856bd77`)

Resolution: AetherEngine `6.4.2`
(`996d8d3b616039f8ce17ebd527df14a9b2cd6a21`) provides the upstream finite
HEVC-in-MPEG-TS HLS ingest and timeline behavior required by this workaround.
Physical-device acceptance on 2026-08-06 proved the Syncnext AVKit proxy path
with four fast-forward seeks and four long-distance forward seeks. Patch 0003
is therefore no longer part of the applied series.

## Historical problem and boundary

For a finite HLS VOD whose MPEG-TS PMT declares HEVC (`stream_type 0x24`),
AetherEngine 5.29.0 changed an explicit `nativeRemoteHLS=false` decision back to
the native remote-HLS path after recognizing the playlist. On the affected tvOS
device that path reached `readyToPlay` but rendered black.

SyncnextHybrid had to choose the route before its single `engine.load()` call.
It therefore inspected the finite media playlist and the first TS PMT. Only a
confirmed HEVC MPEG-TS VOD disabled native remote HLS and forced the AVKit UI
proxy. Live playlists remained on the existing native route; this workaround
did not use HLSLive.

## Former Patch responsibility

`Patches/AetherEngine/0003-hevc-mpegts-hls-vod-remux-workaround.patch` added:

- a bounded, header-preserving finite HLS MPEG-TS ingest reader;
- a time-seekable custom-reader seam used by AetherEngine's demuxer;
- an AetherEngine #246 branch that preserved the host's explicit
  `nativeRemoteHLS=false` choice and fed that reader to the existing MPEG-TS
  to fMP4 loopback remux path.

The reader resolved a master playlist to the highest-bandwidth variant,
required `#EXT-X-ENDLIST`, downloaded at most four segments concurrently,
committed them in playlist order, and restarted from the segment containing a
requested seek time. AES-128 clear-key segments were supported through the
existing decryptor.

Unsupported inputs failed explicitly. The patch did not silently redirect:

- live or DVR playlists;
- fMP4 HLS containing `#EXT-X-MAP`;
- demuxed alternate-audio playlists;
- encryption methods other than the supported AES-128 form.

Signed media URLs and header values are intentionally absent from this file.

## Associated Hybrid and AVKit proxy changes at the time

The Hybrid layer kept the Aether video surface attached even though the remux
backend exposed an internal loopback `AVPlayer`. Its separate AVKit proxy owned
transport UI only. Proxy changes made delayed rate observations order-safe,
deferred clock correction across the pause-before-navigation window, avoided
exact clock corrections while both clocks were already playing at the same
rate, and waited for the proxy item to become ready before accepting playback
rates. The bundled black proxy was a 30 fps H.264 clip with silent AAC, so tvOS
reported fast-forward support and retained the audio-capable transport
contract.

## Acceptance evidence

Physical device: study-room Apple TV (`AppleTV6,2`).

Fixture: original private signed MDD HEVC MPEG-TS HLS VOD.

- Direct AetherEngine remux: 4K HEVC video plus AAC audio, finite duration
  `2698.760`, startup progress, exact seek to `122.000`, and post-seek progress.
- Hybrid AVKit proxy at 1.0x: route `avKitProxy`, startup progress, exact seek to
  `122.000`, and post-seek progress.
- Hybrid AVKit proxy at 2.0x: requested rate `2.000`, startup progress, exact
  seek to `122.000`, and post-seek progress while the requested rate remained
  `2.000`.

The smoke logs identify the source only by SHA-256 and list header names without
values.

## Completed removal

The removal gate was completed against AetherEngine 6.4.2 on 2026-08-06.

1. The 6.4.2 release was reconstructed in an isolated worktree against the
   original private source.
2. Direct and AVKit-proxy startup, seek landing, and post-seek progress passed
   without downstream patch 0003.
3. Patch 0003 was removed from `series` and `manifest.sha256`.
4. Hybrid-owned admission and generic proxy ordering remain at the integration
   layer; upstream-owned ingest is no longer duplicated downstream.
5. Patch replay, Hybrid tests/builds, and the real Syncnext device integration
   were rerun before promotion.

The known backward-restart behavior remains outside this workaround and is
tracked independently; it was explicitly excluded from the 6.4.2 promotion
decision.
