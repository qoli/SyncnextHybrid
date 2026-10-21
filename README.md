# SyncnextHybrid

Syncnext 的本地 Swift package 播放整合邊界：App 只 link／import `SyncnextHybrid`；
AetherEngine 與 FFmpegBuild 是固定的官方 submodules。

## 準備

```sh
git clone --recurse-submodules https://github.com/qoli/SyncnextHybrid.git
cd SyncnextHybrid
./Scripts/apply-patches.sh
```

`apply-patches.sh` 會 reset／clean 兩個 submodule 再重播 Patch；先保存不屬於已審核
Patch 的工作。正式變更放在 root repo，不能只保留 dirty upstream source。

| 要查的事 | 唯一來源 |
| --- | --- |
| 正式版本、完整 SHA 與 remote | [Versions.env](Versions.env) 與 root gitlinks |
| 實際 Patch 與順序 | [AetherEngine series](Patches/AetherEngine/series)、[FFmpegBuild series](Patches/FFmpegBuild/series) |
| Patch bytes | [manifest.sha256](Patches/manifest.sha256) |
| 平台、products 與 dependencies | [Package.swift](Package.swift) |
| 上游更新與修改邊界 | [維護 SOP](Docs/HYBRID_MAINTENANCE_SOP.md) |

## 播放與分析

[HybridPlaybackSession](Sources/SyncnextHybrid/HybridPlaybackSession.swift) 對 App
提供 `AVPlayer`。native route 綁定 Aether 公開的 player；proxy route 由本地 HLS
提供 AVKit transport UI，真實影片呈現仍交給 Aether。
時間軸權責與手工驗收見 [AVKit proxy 模型](Docs/AVKIT_UI_PROXY_TIMELINE_MODEL.md)。

有限 HLS 的既有 target-duration 修正由
[HybridHLSManifestFallback.swift](Sources/SyncnextHybrid/HybridHLSManifestFallback.swift)
擁有；只修正已 admitted 的直接 VOD media playlist，保留原始資源、headers 與
來源身份。錯誤、取消與 listener 清理由同一 session 處理。

Fingerprint V2 的 bounded PCM、明確 source／coverage 失敗下的既有 AAC extraction
與 matcher 入口，由 session 與
[RepeatedSegmentFingerprint.swift](Sources/SyncnextHybrid/RepeatedSegmentFingerprint.swift)
定義。分析失敗不改變播放 route 或音軌；失敗分類與 coverage 以當前測試為準。

DoH 等 process DNS policy 由 App 設定；播放 request 可明確指定
`hlsUsesHTTP1: true`，讓清單探測、remote HLS relay、HEVC VOD／直播 ingest、
金鑰、音訊 tap 與 HLS 字幕 rendition 使用 HTTP/1.1。預設 false，Debug／Release
皆可用。Aether 保留媒體 carriage 的分流與 query-wrapped 同源分段持續連線；
不協商 HTTP/2／3，也不以另一協議回退。DNS 以實際 Network connection
establishment report 判讀，快取或 unknown 不當作本次已量到 DoH。
DNS provider 與 preferences 不進入 engine，AVKit 仍負責播放呈現。

## 驗證

```sh
swift test
```

tvOS 播放與 UI 的獨立驗證工具是
[HybridSmokePlayer](Examples/HybridSmokePlayer/README.md)，具有明確選擇的
`aetherEngine` 與 `hybridAVKit` 模式。其直接 Aether link 僅供診斷。
package tests、Simulator 與「書房電視」實機驗收分別記錄；舊版本報告不作為目前
pin 的通過證據。
