# HybridSmokePlayer 實作驗證

日期：2026-07-25  
狀態：Smoke app implementation **PASS**  
播放器結果：Aether native **PASS**；Aether software **PASS**；
Hybrid native **PASS**；Hybrid proxy post-seek **FAIL**

## 邊界

Smoke app 的實作與本次 baseline 擴充都只發生在 SyncnextHybrid root
repo：

```text
Examples/HybridSmokePlayer/
```

App target 現在 link／import `SyncnextHybrid`，並以診斷例外直接 link 本地
`AetherEngine` product，提供不經 AVKit proxy 的 baseline。這個例外不
改變正式整合邊界：Syncnext App 仍只 link／import
`SyncnextHybrid`。

沒有修改 SyncnextHybrid library interface，也沒有新增或修改
AetherEngine／FFmpegBuild Patch、owner code、log forwarding、
recovery、替代 source、替代 route 或替代 player。

本報告只驗證 bounded smoke，不宣稱完整播放至 EOS、presented frame、HDR
panel mode、音軌／字幕選擇、獨立音訊分析、PiP 或 AirPlay 通過。

## 建置與 tests

```text
XcodeGen project regeneration:
  deterministic project.pbxproj SHA-256
  34d385ac19c65f8ccfffcb406649747534ed5faedc96f30030868bc7af8d4156

tvOS Simulator app build:
  BUILD SUCCEEDED

tvOS 26.5 Simulator tests:
  19 passed
  0 failed
  0 skipped

generic tvOS device build:
  BUILD SUCCEEDED

SyncnextHybrid package tests:
  8 passed
  0 failed
```

Smoke unit tests 涵蓋：

- `aetherEngine`／`hybridAVKit` mode 解析與互動預設；
- automation 必填 mode、非法 mode 與 Aether／expected-route 衝突；
- 既有 Hybrid expected-route 行為；
- 缺 URL、relative URL、非字串 headers 與無效 seek 的明確失敗；
- URL query 與 header value 的 log redaction；
- Aether phase/backend 映射、source/native presentation video size gate；
- Aether video/backend error code 與 `route=not_applicable` metrics；
- native `-0.083s` preroll admission；
- finite VOD／seek duration gate；
- seek landing tolerance；
- authoritative media-time progress。

Package graph 在 Simulator 與 generic device build 都只解析同一份：

```text
AetherEngine:
  /Volumes/Data/Github/SyncnextProjects/SyncnextHybrid/AetherEngine

FFmpegBuild:
  /Volumes/Data/Github/SyncnextProjects/SyncnextHybrid/FFmpegBuild
```

## Simulator AetherEngine baseline

### Native HLS

Fixture：

```text
06-seek-5min/hls-fmp4-h264-aac-5min/index.m3u8
mode:        aetherEngine
seek target: 150.000s
run id:      c2af98a1-c9f9-401d-8151-e441f5d7aec1
```

結果：

```text
readiness:
  loading / duration=0 / video=0x0
  -> paused / duration=300.000 / video=640x360

backend:
  native
  currentAVPlayer=present

startup:
  0.000 -> 2.000

seek:
  target=150.000
  landed=150.000
  error=0.000

post-seek:
  150.000 -> 152.000

route:
  not_applicable

terminal:
  run_passed
```

### Software MPEG-2

Fixture：

```text
06-seek-5min/progressive-hybrid-mpeg2-interlaced-ac3-5min.mkv
mode:        aetherEngine
seek target: 150.000s
run id:      c9ce16d5-ee13-4486-86fc-262bb71b019a
```

結果：

```text
readiness:
  paused / duration=300.000 / video=640x360

backend:
  software
  currentAVPlayer=absent
  audio tracks=1

startup:
  0.000 -> 2.103

seek:
  target=150.000
  landed=150.000
  error=0.000

post-seek:
  150.000 -> 152.124

route:
  not_applicable

terminal:
  run_passed
```

這兩次 run 都只建立 `AetherEngine` 與
`AetherPlayerSurface(engine:)`；沒有建立 `HybridPlaybackSession`、
`AVPlayerViewController` 或 black-frame proxy，也沒有在失敗後改跑
Hybrid。

### Manual Aether seek control

Simulator 以同一個 software MPEG-2 fixture 驗證 overlay
`Seek → 00:00:10`：

```text
run id:
  5bd40176-83f1-4955-bf22-3c56706ff2cd

manual seek requested:
  current=157.118
  target=10.000
  phase=paused
  resume_after_seek=true

manual seek landed:
  current=10.000
  error=0.000
  phase=playing
  resumed=true
```

Button action 產生 `manual_seek_requested` 與
`manual_seek_landed`。若在 bounded smoke 尚未完成時操作，會先取消
automation，避免人工 clock jump 被誤判為自然播放進度；沒有切換到
Hybrid 或另一個 source。

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
7. Aether baseline 的第一輪 HLS run
   `aa9010a7-fbdc-49ca-9afe-8f523904ad0d` 在
   `loading / duration=0 / video=0x0` 時過早套用 video gate，產生
   `aether_video_required`。這是 smoke harness 的 readiness 時序錯誤，
   不是 Aether 播放結果。修正為只在 paused finite VOD readiness 成立時
   驗證 backend 與 video。
8. 第二輪 HLS run
   `1f57f265-667f-4ebb-bf3c-51d582f19e0a` 顯示 native route 已 paused、
   duration 已為 300 秒，但 Aether 的 `sourceVideoWidth/Height` 仍為
   `0x0`。Smoke app 改以公開 source dimensions 為優先，native source
   缺值時讀取公開 `currentAVPlayer.currentItem.presentationSize`；同一
   source 隨後得到 `640x360` 並通過。沒有為此修改 AetherEngine 或
   Patch。

## 結論

HybridSmokePlayer 現在能在 tvOS 上分別驗證：

- 直接 `AetherPlayerSurface` baseline；
- 以獨立按鈕手動測試 Aether seek，並先取消 automation 避免假 PASS；
- Hybrid 原生 `AVPlayerViewController`；
- 驗證 session readiness；
- 驗證真實播放時間前進；
- 驗證 pause／seek／resume；
- Aether video/backend gate；
- Hybrid route invariance 與目前 AVKit player binding；
- 輸出 privacy-safe structured terminal；
- 對 mode 缺失／衝突、缺資料、backend/video failure、route mismatch
  與無進度明確失敗。

本次依範圍只執行兩個代表 fixture 的 Simulator baseline，沒有執行
書房 Apple TV 或全部八個 fixture。generic device build 通過不等同於
physical-device playback pass。
