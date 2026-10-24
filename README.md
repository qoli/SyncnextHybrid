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
解碼後的內封／外掛字幕由
[HybridSubtitleOverlayView](Sources/SyncnextHybrid/HybridSubtitleOverlayView.swift)
依 source PTS 顯示，兩種 route 共用相同字幕層。
字幕字形與描邊可用 [SubtitleStyleProbe](Examples/SubtitleStyleProbe/README.md)
直接比較固定 cue，不需經過訂閱、片源與播放流程。
時間軸權責與手工驗收見 [AVKit proxy 模型](Docs/AVKIT_UI_PROXY_TIMELINE_MODEL.md)。

有限 HLS 的既有 target-duration 修正由
[HybridHLSManifestFallback.swift](Sources/SyncnextHybrid/HybridHLSManifestFallback.swift)
擁有；只修正已 admitted 的直接 VOD media playlist，保留原始資源、headers 與
來源身份。錯誤、取消與 listener 清理由同一 session 處理。

Fingerprint V2 的 bounded PCM、明確 source／coverage 失敗下的既有 AAC extraction
與 matcher 入口，由 session 與
[RepeatedSegmentFingerprint.swift](Sources/SyncnextHybrid/RepeatedSegmentFingerprint.swift)
定義。分析失敗不改變播放 route 或音軌；失敗分類與 coverage 以當前測試為準。
Session 的 `fingerprintAudioPlan(for:)` 依已確認的媒體能力提供 provider 與取樣時機：
一般 HLS VOD 用獨立 bounded HLS reader，片頭完成後即可取得片尾；HEVC MPEG-TS HLS
保留片頭 cache／片尾獨立 reader。直播明確不支援固定片尾分析。
已確認的有限 EBML 來源使用主播放的 SegmentCache 取得片頭與片尾音訊，
不另外開啟原來源。片尾等播放進入其來源時間範圍且 seek 完成後才開始 cache material demand；
片頭的後續 batch 同樣等已觸發的 seek 完成，避免前綴比對跳過改變正在取樣的時間軸。
等待時間不消耗素材取得的 deadline。這條路徑的 cache 失敗明確回報，
不觸發重新讀源的 AAC extractor。
progress 以 `waitingForPlayback` 區分等待素材，實際取樣時才進入 `preparing`／`decoding`；
App 等待時收起分析進度並保留片頭結果，取樣與比對完成後才標記完成。
Session stop、呼叫方取消與音軌變更會撤銷
分析；獨立 reader 的取消會關閉自己擁有的 HTTP producer。

DoH 等 process DNS policy 由 App 設定；播放 request 可明確指定
`heldSourceConnection: true`，將上游的持續 HTTP/1.1 選項傳入 Aether 7.45.0。
HLS VOD 的同源分片由官方 transport 持有連線，FIFO、framing、背壓與取消
仍由上游實作。DoH 不再要求另外一套全 HLS HTTP/1.1 relay，清單可以使用
HTTP/2；DNS provider 與 preferences 留在 App。原生分片沒有可用的 host DNS
metrics 時保持未確認，AVKit 與 Hybrid 字幕層維持原有呈現責任。

## 驗證

```sh
swift test
```

tvOS 播放與 UI 的獨立驗證工具是
[HybridSmokePlayer](Examples/HybridSmokePlayer/README.md)，具有明確選擇的
`aetherEngine` 與 `hybridAVKit` 模式。其直接 Aether link 僅供診斷。
package tests、Simulator 與「書房電視」實機驗收分別記錄；舊版本報告不作為目前
pin 的通過證據。
