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
原生純音訊綁定 Aether `audioNowPlayingSession.players` 中既有的 AVPlayer；
播放、暫停、seek、媒體時鐘與 stop 仍由同一 Aether session 擁有。播放器綁定
與前景恢復共用這個選取邊界。沒有 engine-owned AVPlayer 的純音訊解碼路徑
維持明確不支援，不另建播放器或重開來源。
解碼後的內封／外掛字幕由
[HybridSubtitleOverlayView](Sources/SyncnextHybrid/HybridSubtitleOverlayView.swift)
依 source PTS 顯示，兩種 route 共用相同字幕層。
字幕字形與描邊可用 [SubtitleStyleProbe](Examples/SubtitleStyleProbe/README.md)
直接比較固定 cue，不需經過訂閱、片源與播放流程。
時間軸權責與手工驗收見 [AVKit proxy 模型](Docs/AVKIT_UI_PROXY_TIMELINE_MODEL.md)。

`HybridPlaybackSession.playbackClockDiagnosticFields()` 只讀取既有快照、engine／
source／AVPlayer 時鐘、generation、音軌、player／item identity 及 publisher
觀察時間，供 App 的既有進度、狀態與換址 checkpoint 寫入 HTTP log。
音軌選擇另以 Task-local session／origin operation 串起 SDK 已有的重建日誌；
`HybridAudioReloadDiagnostics` 只轉送已知事件與數值，其他 handler 仍沿用。
欄位不重新定義播放位置，也不改變 SDK 重建或時鐘觀察的生命週期。

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

## Aether 可選組件

Hybrid 編入 `TrueHDObjectAudio`、`DTSXObjectAudio`、`DualLayerDolbyVision` 與
`DolbyVisionStillReshaping` 四個 package traits；`TrueHDReferenceRender` 是量測用
組件，不啟用。App 可透過 `HybridOptionalComponent.allCases` 的 `isBuiltIn`
查詢編譯能力，不需要直接 import AetherEngine。

音訊與 FEL 由每次播放明確選擇，既有呼叫預設為 `.off`／`false`：

```swift
let request = try HybridPlaybackRequest(
    url: url,
    objectAudioRendering: .apac(.l714),
    preferDualLayerDolbyVision: true
)
```

Syncnext 在「設定 → 播放器」提供空間音訊與 Dolby Vision FEL 兩個獨立開關，
皆預設關閉且下次播放生效。正式入口依設定分別選用 `.apac(.l714)`／`.off`
與 FEL `true`／`false`；Hybrid request 的預設值與獨立 probe 保持不變。

APAC 需要 OS 26 以上；喇叭配置必須對應接收器實際配置，音訊會經過有損重新編碼。
來源、解碼能力與有效路由仍由 Aether 決定；傳入選項不代表該來源已使用該能力。
`session.supportsCacheBackedStills` 與 `session.scrubThumbnail(atSeconds:)` 暴露
播放快取縮圖，包含 DV 靜態圖 reshaping；未支援或尚無素材時回傳 nil，查詢本身不讀源。
7.51.0 起上游可在來源閒置時，以同一 request budget 預取 keyframe still ladder；
此排程與連線上限由上游擁有。

這些選項不更換既有 fingerprint／音樂辨識 provider。正式 release 的 FEL 路徑
沒有 native SegmentCache，APAC 也不是 FFmpeg 音訊分析可解碼的格式，因此不能
把一般 HLS 的 PCM 驗收當作 FEL／APAC 的分析相容證據。HDMI 輸出與實際 FEL
畫面仍需書房電視驗收。7.50.0 的 `.render`／`.lpcm` 與 7.52.0 的 audio shaping
尚未暴露為 Hybrid 產品選項；現有 App 空間音訊開關仍明確選擇 `.apac(.l714)`。

## 來源地址更新的宿主邊界

`HybridMediaResponse` 將既有 privacy-safe media response 轉為型別化通知，
保留 source/resource SHA-256 與 HTTP status；不新增探測或變更 Aether 重試。
原插件、episode input、使用者恢復政策及 session 替換由 App 擁有。
`HybridPlaybackRequest.replacingSource` 保留原播放選項與外掛字幕，更新來源、
headers 及起始位置；`initialAudioTrackID` 經 Aether 公開 load 參數在首次載入指定
原音軌，實際選軌不符時明確失敗。沒有原 resolver 的來源不自行猜測新地址；
App 的恢復與書房驗收契約見 `Syncnext/Docs/Reference/app_logging.md`。

## 驗證

```sh
swift test
```

tvOS 播放與 UI 的獨立驗證工具是
[HybridSmokePlayer](Examples/HybridSmokePlayer/README.md)，具有明確選擇的
`aetherEngine` 與 `hybridAVKit` 模式。其直接 Aether link 僅供診斷。
package tests、Simulator 與「書房電視」實機驗收分別記錄；舊版本報告不作為目前
pin 的通過證據。
