# HybridSmokePlayer 實作驗證

日期：2026-07-25  
狀態：Smoke app implementation **PASS**  
播放器結果：native smoke **PASS**；proxy post-seek smoke **FAIL**

## 邊界

本次只在 SyncnextHybrid root repo 新增：

```text
Examples/HybridSmokePlayer/
```

App target 只 link／import `SyncnextHybrid`。沒有修改 SyncnextHybrid library
interface，也沒有新增或修改 AetherEngine／FFmpegBuild Patch、owner code、
log forwarding、recovery、替代 source、替代 route 或替代 player。

本報告只驗證 bounded smoke，不宣稱完整播放至 EOS、presented frame、HDR
panel mode、音軌／字幕選擇、獨立音訊分析、PiP 或 AirPlay 通過。

## 建置與 tests

```text
XcodeGen project regeneration:
  deterministic project.pbxproj SHA-256
  c74cf09049ca7e69efe6172eb79ffae2ec73f0496efdc9a55394d2de4abaa26b

tvOS Simulator app build:
  BUILD SUCCEEDED

tvOS 26.4 Simulator tests:
  10 passed
  0 failed
  0 skipped

generic tvOS device build:
  BUILD SUCCEEDED

SyncnextHybrid package tests:
  8 passed
  0 failed
```

Smoke unit tests 涵蓋：

- automation／interactive configuration mode；
- 缺 URL、relative URL、非字串 headers 與無效 seek 的明確失敗；
- URL query 與 header value 的 log redaction；
- native `-0.083s` preroll admission；
- finite VOD／seek duration gate；
- seek landing tolerance；
- authoritative media-time progress。

## Simulator native route

Fixture：

```text
06-seek-5min/hls-fmp4-h264-aac-5min/index.m3u8
expected route: nativeAVPlayer
seek target:    150.000s
run id:         442e3795-fe31-400c-8c3f-2ed6397ee33f
```

結果：

```text
readiness:
  loading / duration=0
  -> paused / duration=300.000

startup:
  0.000 -> 2.000

seek:
  target=150.000
  landed=150.000
  error=0.000

post-seek:
  150.000 -> 152.000

route:
  nativeAVPlayer throughout

controller binding:
  matched throughout

terminal:
  run_passed
```

初版 harness 曾在 attach 後的第一個 `loading / duration=0` snapshot
立即報 `non_finite_duration`。實際 Hybrid event 證明 native AVPlayer
稍後才公開 duration，因此 smoke contract 改為：在固定 30 秒內等待
`paused + finite duration + valid media time`。逾時仍是明確
`session_readiness_timeout`；沒有加入另一條播放器路徑。

## Simulator proxy route

Fixture：

```text
06-seek-5min/progressive-native-h264-aac-5min.mp4
observed route: avKitProxy
seek target:    150.000s
run id:         1fcd7ad3-835c-405e-b193-7244afeb1bd1
```

Simulator 對此 fixture 實際選擇 `avKitProxy`。先前明確指定
`nativeAVPlayer` 的獨立 run
`0a933ddb-933c-4749-9b35-a8e0de6b1aaf` 正確以
`unexpected_route` terminal 失敗；app 沒有在同一 run 內接受或切換成
觀察到的 route。

其後以 Simulator 已知的 `avKitProxy` contract 建立全新 run：

```text
startup:
  0.000 -> 2.230

seek:
  target=150.000
  landed=150.000
  error=0.000

post-seek:
  stopped at 150.011
  phase=paused
  requested_rate=1.000
  elapsed=60.500

route:
  avKitProxy throughout

terminal:
  error_code=no_media_progress
  stage=post_seek
```

這證明 smoke app 能保留並終止既有 proxy seek failure，而不是證明 proxy
播放通過。

## 過程錯誤

1. 第一版 source 使用 Python basic `http.server` 提供 progressive MP4。
   Origin 沒有正確滿足播放器的 byte-range contract，持續 full-body
   `200` 並產生 broken pipe；該次在 session attach 前人工終止，不計入
   播放結果。
2. 換成 Range-aware origin 後，progressive session 立即建立並正常輸出
   route／duration／typed terminal。
3. 第一輪 compile 使用了 tvOS 不提供的
   `entersFullScreenWhenPlaybackBegins`，已直接移除；沒有用另一個
   full-screen 行為替代。
4. native HLS 第一輪發現前述 readiness 時序缺口；修正 harness 後，同一
   source／expected route／seek contract 產生 `run_passed`。
5. SyncnextHybrid package build 仍顯示既有
   `mediaSelectionGroup(forMediaCharacteristic:)` deprecation warning。
   它來自已批准的 `0002` Patch，本任務沒有為消除 warning 而修改或擴張
   上游 Patch。
6. Xcode 同時開啟 `SyncNext.xcodeproj` 與
   `HybridSmokePlayer.xcodeproj` 時，兩個獨立 workspace document 都會
   嘗試持有同一份本地 SyncnextHybrid package。Xcode 先回報
   `already opened from another project or workspace`，再衍生
   `Missing package product 'SyncnextHybrid'`。關閉另一個 project 並單獨
   重開 HybridSmokePlayer 後 package graph 與 tvOS Simulator build 均
   通過；不需要清除 package cache、重套 Patch 或修改上游。

## 結論

HybridSmokePlayer 已能在 tvOS 上以 Hybrid 公開 interface：

- 顯示原生 `AVPlayerViewController`；
- 驗證 session readiness；
- 驗證真實播放時間前進；
- 驗證 pause／seek／resume；
- 驗證 route invariance 與目前 AVKit player binding；
- 輸出 privacy-safe structured terminal；
- 對缺資料、route mismatch 與無進度明確失敗。

實體 Apple TV 尚未在本次 app 實作任務中執行；generic device build
通過不等同於 physical-device playback pass。
