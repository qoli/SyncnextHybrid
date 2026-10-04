# Synthetic HEVC HLS fixture

Six seconds of 32x32 black video with two mono AAC tracks: English/default 440 Hz and Chinese/non-default 880 Hz. Generated locally; contains no downloaded media.

```sh
ffmpeg -f lavfi -i color=c=black:s=32x32:r=25:d=6 \
  -f lavfi -i sine=frequency=440:sample_rate=48000:duration=6 \
  -f lavfi -i sine=frequency=880:sample_rate=48000:duration=6 \
  -map 0:v -map 1:a -map 2:a -c:v libx265 -preset ultrafast \
  -x265-params pools=1:frame-threads=1:keyint=25:min-keyint=25:scenecut=0:log-level=error \
  -c:a aac -b:a 32k -ac 1 -metadata:s:a:0 language=eng \
  -metadata:s:a:1 language=zho -disposition:a:0 default -disposition:a:1 0 \
  -f hls -hls_time 1 -hls_playlist_type vod \
  -hls_segment_filename hevc-%02d.ts hevc.m3u8
```

Tests request only 2.5..<6 seconds, check the global PCM timeline, reject prefix segment requests, and distinguish the selected 880 Hz track from the 440 Hz default. The existing bounded FFmpeg PCM and public AAC extraction/file matcher paths are exercised; the production session fallback orchestration is not runtime-tested. This fixture does not replace same-source or physical Apple TV acceptance.
