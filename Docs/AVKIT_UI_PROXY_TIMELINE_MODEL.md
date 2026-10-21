# AVKit UI Proxy 時間軸模型與微調指南

更新日期：2026-10-17
狀態：Active
Owner：SyncnextHybrid

## 1. 目的

本文定義 SyncnextHybrid `avKitProxy` route 的正式時間軸模型，並記錄 AVKit
UI Proxy 在 seek、pause、buffering、thumbnail 與實機驗收上的微調經驗。

本模型解決的核心問題是：AVKit UI、HLS Proxy Server 與 AetherEngine 都有
自己的時間與狀態，但三者不能同時爭奪播放權威。

以當前 source 與測試為準；本文保留跨時間軸 ownership 與手工驗收約束。
修改前先由事件時間線定位責任，不以補償狀態、延遲或 fallback 掩蓋問題。

## 2. Proxy 的實際組成

在 `avKitProxy` route 下：

- AVKit 綁定由 `HybridHLSTimelineProxy` 提供的有限本地 HLS `AVPlayer`；
- HLS playlist 提供完整 duration、連續 segment 與 AVKit transport UI；
- Proxy video track 在 item ready 後設為 `isEnabled = false`，避免 AVKit 產生
  preview thumbnail；
- AetherEngine 的 surface 安裝在 `AVPlayerViewController.contentOverlayView`，
  負責真正的影像呈現；
- AetherEngine 負責真正的媒體讀取、解碼、音訊與 buffer 材料；
- HLS Proxy Server 負責 AVKit 所看見的權威時間軸與等待狀態。

黑色 Proxy 媒體只是建立 AVKit transport contract 的載體，不是畫面來源，也
不是播放權威本身。

### 2.1 字幕呈現

`AetherPlayerView` 只承載影像；選取字幕後，AetherEngine 經 `subtitleCues`
提供解碼內容，由 Hybrid 的透明 `HybridSubtitleOverlayView` 在
`contentOverlayView` 上呈現。此字幕層同時適用 `nativeAVPlayer` 與
`avKitProxy`，不依賴 video surface 是否掛載。文字、rich-text 的顏色與強調、
ASS alignment／position 及 bitmap 的 canvas geometry 均由 decoded cue 交付。
未指定顏色的文字採用 Probe 的 B 樣式：實心白字，不帶 stroke attributes。
文字 layer 後方加黑色陰影，opacity 0.68、offset (0, 6)、radius 12，確保
淺色背景可讀，同時避免 attributed stroke 讓中文字形呈現空心／浮雕。樣式迭代用
`Examples/SubtitleStyleProbe`，直接編譯同一份正式 renderer 與固定 cue。

字幕比對使用 `engine.clock.sourceTime` 的 source PTS；不得用 AVKit UI／Proxy
timeline 取代。切軌、關閉字幕及 seek 清空的 cue 必須同步移除，暫停則保留當下
有效字幕。detach 移除字幕層。字幕繼續由既有 Subtitles 選單切換，本次不改變
既有語言選擇政策。此層只負責畫面內字幕，不代表已驗收 PiP／AirPlay 字幕。

回歸入口為 `HybridSubtitlePresentationTests`（source PTS、重疊／過期 cue、
letterbox 與 canvas placement）及 tvOS 的 `HybridSubtitleOverlayViewTests`
（文字視圖、白字填色 raster、暫停／關閉、同 ID 切軌和圖像字幕）。兩者均屬
`SyncnextHybridTests`；原生測試須選定可用的 tvOS Simulator 執行。

## 3. 三個時間軸的責任

| 時間軸 | 速度與角色 | 責任 | 不應負責 |
|---|---|---|---|
| AVKit UI | 最快的使用者操作入口 | 接收 seek、play、pause；展示 HLS 狀態 | 自行維護 Aether buffer 或 Proxy authority |
| HLS Proxy Server | 次快、但為權威 | duration、playhead、rate、seek generation、`waitingToPlay`、segment 供應 | 優化、合併或猜測使用者操作 |
| AetherEngine | 被控時間軸 | 執行 transport 命令、渲染、提供 buffer 材料 | 以一般 playing/paused/seeking 狀態覆寫 Server 時間軸 |

### 3.1 權威不等於所有事件都由權威層開始

HLS Proxy Server 是權威，表示它定義 AVKit 最終可觀察的時間、rate、generation
與等待狀態；不表示每次使用者操作都必須等待 Server 事件再向下游轉發。

AVKit UI 比 HLS request/response 更早知道使用者最終選定的 seek target。為了
保持 UI 跟手，AVKit seek 使用一條明確且受限的快速通道，但仍共用 Server
建立的同一個 generation。

### 3.2 Aether 可以反向影響 Server 的例外

AetherEngine 只有下列材料或終止狀態可以反向影響 HLS Proxy：

- loading、rebuffering、stalled：停止供應材料並投影為 `waitingToPlay`；
- ended：投影為 ended；
- error：投影為 failed。

Aether 的一般 playing、paused、seeking 只是 Server 命令的結果，不能反向改寫
Server 的 rate、playhead 或 seek generation。

## 4. AVKit Seek 快速通道

### 4.1 正式流程

```text
使用者在 AVKit UI 選定目標
  -> timeToSeekAfterUserNavigatedFrom
       -> HLS Proxy 建立權威 generation 與 waitingToPlay
       -> 同一個 AVKit callback 直接把 seek 發送給 AetherEngine
  -> AVKit 對 Proxy AVPlayer 執行 client seek
  -> HLS Proxy 暫扣目標 segment，等待相同 generation 的 Aether 回應
  -> AetherEngine seek 返回
  -> HLS Proxy acknowledge generation 並恢復 segment 供應
  -> HLS Proxy 依權威 rate 決定 Aether 應恢復 Play 或維持 Pause
  -> AVKit 自動離開 waitingToPlay
```

### 4.2 為何使用 `timeToSeekAfterUserNavigatedFrom`

`AVPlayerViewControllerDelegate` 的
`timeToSeekAfterUserNavigatedFrom:to:` 是 AVKit 在真正執行 client seek 前，同步
詢問最終 target 的入口。此時：

- 使用者意圖已確定；
- AVKit 尚未開始請求目的地 HLS segment；
- Hybrid 可以先建立 Server generation；
- Aether 可以立即開始相同 target 的 seek。

這比 `willResumePlaybackAfterUserNavigatedFrom:to:` 更早，也不需要從 HLS segment
demand 反推使用者意圖。

### 4.3 特殊快速通道的限制

AVKit UI seek 呼叫 `prepareSeek(..., emitsSeekRequest: false)`：

1. Server 仍建立 generation、移動權威 demand window 並發布
   `waitingToPlay`；
2. 但不再產生 `.seekRequested` 事件反射回 `HybridPlaybackSession`；
3. `HybridPlaybackSession` 直接以同一 generation 呼叫 Aether seek；
4. Aether 回應仍必須由 Server acknowledge，不能繞過權威 gate。

這條路徑只縮短操作轉發時間，不改變 Server authority。

程式式 `HybridPlaybackSession.seek(to:)` 仍可走正常的 Server
`.seekRequested` 搬運路徑。兩條入口必須產生相同的 generation／acknowledge
語意。

### 4.4 `willResumePlaybackAfterUserNavigatedFrom` 的責任

此 callback 只作為 AVKit client seek 已完成的觀測點，主要服務 diagnostics 與
UI 截圖驗收。它不得：

- 再建立一次 Server seek；
- 再向 Aether 發送 seek；
- 強制 Play；
- 清除或偽造 `waitingToPlay`。

### 4.5 片尾 seek、完成與重播

`seek(to:intent:)` 的預設 `.position` 表示定位；`.automaticSkip` 表示跳過
已辨識片段。兩者共用 generation、Aether 回應與 Server acknowledge，不從
相同的 target 猜測使用者意圖。App 的 fingerprint 自動跳過傳入
`.automaticSkip`；一般定位與歷史進度保持 `.position`。

AetherEngine #164 將有限 VOD 結尾前 0.5 秒視為片尾，該位置的 `play()`
會自行 seek 到 0。Hybrid 以相同既有容差集中判定，回歸測試直接比對 pinned
Aether 的判定；不把 seek target 任意往前挪動。

恢復播放前也檢查 Aether 實際落點；當請求位置尚未進入片尾、實際落點已進入
片尾時，一樣暫停兩端，但不把原先的中段跳過升格為播放完成。

- 手動定位到片尾：實際暫停 Aether 與 Proxy，Server rate 歸零，維持可回拖的
  `.paused`；seek 返回後不發送 `engine.play()`。
- 自動跳過到片尾：將 target 正規化為已知 duration，暫停兩端，Server 在同一
  generation 完成並發布 `.ended`，由 App 既有播畢流程決定下一集或退出。
- 明確 `replay()` 或片尾的 Play：先由 Server 建立回到 0 的新 navigation，
  再接受 Aether 落點並按 Server 當下 rate 恢復。Aether 已 organic `.ended`
  時，先以既有 API 重開同一 session；失敗明確回報，不另換來源或重試。
- 導航期間的 Play／速度只更新當下意圖；Pause 可覆寫重播。後來的 seek 或
  Pause 會取消尚未開始的 queued replay，舊 generation 不可完成新操作。

實機 AVPlayer 在 seek 中也可能回寫 `rate=1`，不能當作新的 Play／重播意圖。
Hybrid 分開追蹤 renderer navigation 與 AVPlayer client seek；client seek 完成
前的 rate observation 不改寫 Server。當前 generation 的 client completion
再把 Server 的既有 rate 套回 AVPlayer，避免 seek 內部延遲回寫覆蓋片尾暫停。

正常 seek 回應後恢復播放與明確重播分開處理。`setRate` 在 paused renderer
只記住速度，因此中段恢復先設定速度再 Play；片尾落點不執行 Play。Aether
的一般時鐘讀值仍不能反向覆寫 Server playhead。

Native route 同樣套用片尾意圖與完成投影，保留 Aether 原生 seek 的中段
transport 行為；播放錯誤優先於片尾狀態。

## 5. `waitingToPlay` 與視覺一致性

AVKit 的 transport UI 只能從它自己的 `AVPlayer`／HLS 狀態推導。Proxy 應透過
真實的 HLS 供應 gate 表達等待：

- seek 建立 pending generation；
- 目的地 segment 在 Aether 回應前不釋放；
- AVPlayer 自然進入 `waitingToPlayAtSpecifiedRate`；
- AVKit 自然顯示等待指示；
- segment 可用後，AVKit 自然恢復播放。

不得在 App layer 偽造一套與 AVPlayer 不一致的 waiting state。

## 6. 已證明錯誤的方案

### 6.1 等到 `willResume` 才通知 Aether

此時 AVKit 已開始向 HLS Proxy 請求目標 segment，但 Aether 尚未收到 seek。
Server 等 Aether、AVKit 等 Server，會形成循環等待或數秒延遲。

### 6.2 Seek 前先 Pause Aether

Pause 會混淆「使用者暫停」與「seek 過渡」兩種 transport intent，也可能使
Aether 不再產生預期的恢復事件，最終造成無限 `waitingToPlay`。

Seek 必須保持 Server 的權威 rate，不應插入額外 Pause。Aether 返回後，由
Server 當前 rate 決定恢復 Play 或維持 Pause。

### 6.3 建立凍結畫面

凍結畫面只是在掩蓋事件從錯誤層開始造成的延遲。快速通道建立後，AVKit 自己
會保持畫面並展示 waiting UI，不需要額外 overlay、snapshot 生命周期或解除
邏輯。

### 6.4 在 Server 做 latest-wins、coalescing 或節流

HLS Proxy Server 是透明的權威狀態／操作搬運層，不是互動優化器。它不應：

- 合併 seek；
- 丟棄中間操作；
- 猜測最新操作才有效；
- 為等待 Aether 建立長窗口；
- 根據 segment demand 自動創造 seek。

如需 UI 操作策略，應在操作入口明確處理；不能藏在 Server transport contract
內。Server 只允許維持完成同一 generation 所需的最小等待 gate。

### 6.5 從 `timeJumpedNotification` 推導使用者 seek

AVPlayer 自身 seek、clock correction 與 Proxy 同步都可能發出 time-jumped
通知。此通知不能可靠區分使用者意圖，會造成重複 seek 或回授循環。

### 6.6 透過 codec 解決 thumbnail

H.264 與 HEVC 都可能被 AVKit 產生 thumbnail。將 black-proxy 改為 HEVC 並未
消除 thumbnail，反而曾破壞 pause／seek 穩定性。

正確做法是保持已驗證的 Proxy 媒體 contract，並在 item ready 後關閉 video
item track：

```swift
for track in videoTracks {
    track.isEnabled = false
}
```

這會保留 duration、audio-capable transport 與 AVKit 控制器，同時移除可供
thumbnail 分析的 video track。

## 7. Native AVPlayer route 的隔離

`HybridPlaybackSession` 在兩個 route 都會成為 `AVPlayerViewController` 的
delegate，但快速通道只允許 `snapshot.route == .avKitProxy`：

- `.nativeAVPlayer` 直接使用 AetherEngine 發布的同一個 AVPlayer；
- `timeToSeekAfterUserNavigatedFrom` 在 native route 原樣返回 AVKit target；
- 不建立 Proxy generation；
- 不向 Aether 額外發送 Proxy seek；
- 不改變原生 AVPlayer 的 pause、rate 或 seek 行為。

Syncnext App 的視覺 seek automation 另受 `#if DEBUG`、
`SYNCNEXT_HYBRID_HISTORY_ACCEPTANCE=1`、
`SYNCNEXT_HYBRID_VISUAL_SEEK_ACCEPTANCE=1` 與 `.avKitProxy` route gate 限制，
不屬於正式播放路徑。

## 8. 可觀測性契約

調查 Proxy seek 時，至少同時記錄：

- operation origin；
- seek generation；
- old/target time；
- Proxy phase、time、rate；
- Aether phase、time、bufferedThrough；
- HLS request segment 與 resolved outcome；
- Aether seek dispatch／return；
- Server acknowledge 結果。

AVKit UI 快速通道的預期事件順序為：

```text
navigation-target-received
seek-prepared
avkit-seek-projected
navigation-forwarded-to-aether origin=avKit transport=seek-without-pause
navigation-seek-dispatched
seek-response acknowledged=true
navigation-landed intent=position endDisposition=none
navigation-will-resume
```

裝置 console 與 AppLogger 可能令同一事件出現兩次；判斷操作數量時應以
generation，而不是原始行數計算。

以下訊號代表模型可能回歸：

- `origin=avKit` 同時出現 `server-seek-projected`；
- `transport=pause-then-seek`；
- Aether 已返回但 generation 沒有 acknowledge；
- AVKit 請求遠端 segment，但沒有新 generation；
- 舊 generation 的回應恢復了新 generation 後的播放。

## 9. 驗收方法

Proxy transport 不能只靠 unit test 或 AVPlayer callback 驗收。最低要求是：

1. 使用真正會選擇 `avKitProxy` 的長影片；
2. 從 HLS Proxy Server observation 判斷 target、generation 與 resolved
   segments；
3. 驗證啟動、Pause、恢復與 seek 後繼續前進；
4. 執行至少五次連續前後 seek；
5. 執行至少向前 15 分鐘與向後 10 分鐘的 seek；
6. 每次 seek 後截取 AVKit UI，核對時間軸位置與 waiting indicator；
7. 確認沒有 `pause-then-seek`，也沒有 AVKit seek 經 Server event 重複回送；
8. 執行 `swift test`、HybridSmokePlayer tvOS build 與 Syncnext 實體裝置 build。

驗收結果只適用於當時的 exact App／package／來源與裝置；歷史紀錄由 Git 查閱。
日誌與截圖可能包含本地裝置／路徑資訊，不應提交到公開 repository。

## 10. 修改前檢查表

修改 AVKit UI Proxy 前必須回答：

1. 這是 AVKit 操作、Server authority，還是 Aether material event？
2. 是否改變了 HLS Proxy 對 duration、rate、playhead 或 generation 的權威？
3. 是否錯誤地讓 Aether playing/paused/seeking 反向控制 Server？
4. 是否加入 Pause、Play、freeze、coalescing 或 fallback 來掩蓋事件延遲？
5. AVKit 是否仍能從真實 HLS 狀態推導 `waitingToPlay`？
6. 同一使用者 seek 是否只向 Aether 發送一次？
7. stale generation 是否可能恢復新操作後的播放？
8. native AVPlayer route 是否仍原樣通過？
9. 是否有實體裝置的連續、遠距離、前後 seek 與 UI 截圖證據？

若任何答案不明確，先增加 generation／phase／segment 日誌並重建完整事件時間
線，不應先加入新的 transport 狀態。
