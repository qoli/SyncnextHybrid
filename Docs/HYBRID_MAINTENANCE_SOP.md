# SyncnextHybrid 維護 SOP

更新日期：2026-10-24
狀態：Active  
Owner：SyncnextHybrid

## 1. 目的

本 SOP 定義 SyncnextHybrid 的日常開發、AetherEngine 上游更新與 Patch
維護邊界。最高優先級是：

1. SyncnextHybrid 必須能安全吸收 AetherEngine 上游 release。
2. Hybrid 開發不得把產品需求轉嫁成 AetherEngine／FFmpegBuild 的長期
   維護負擔。
3. 所有上游例外修改都必須可見、可重播、可審核及可撤回。

### 1.1 現況權威順序

文件描述與 repository 現況不一致時，以可執行 contract 為權威：

1. `Versions.env` 與 root gitlinks 定義正式 AetherEngine／FFmpegBuild pins；
2. `Patches/<repo>/series` 定義實際套用的 Patch，`Patches/manifest.sha256`
   驗證其內容；
3. `Package.swift` 與 checked-in project configuration 定義支援平台下限；
4. production source 與 tests 定義現行 API、ownership 與失敗行為；
5. 舊驗收快照由 Git 歷史查閱，不得反向覆寫以上現況或代表目前 pin 已驗收。

目前正式 pins 與平台下限不在本 SOP 重複抄錄；應直接讀取上述檔案。第 2.2
節只為 active Patch identities 說明已批准責任，必須與 `series` 同步；
`series` 仍是 Patch 是否實際套用的唯一權威。

## 2. 不可違反的責任邊界

### 2.1 一般開發不得修改上游 owner code

任何一般功能、錯誤處理、UI、Syncnext-specific admission／AVKit presentation
route、recovery、日誌、automation 或其他產品行為，都必須實作在：

- `Sources/SyncnextHybrid/`；
- Syncnext App；
- SyncnextHybrid 自己的測試與文件。

不得直接在 `AetherEngine/` 或 `FFmpegBuild/` submodule 內完成需求，也不得：

- 在 submodule 建立產品分支或提交 patched commit；
- 把 patched commit 推到官方 repo、遠端 fork 或臨時 fork；
- 將沒有對應正式 `.patch` 的 dirty worktree 當作實作成果；
- 為了方便整合而更換 `.gitmodules` 的官方 remote；
- 把 Syncnext-specific admission、AVKit presentation、產品 recovery 或 log
  forwarding 放入上游 source；
- 使用模糊 fallback、另一個播放器或未記錄的替代路徑掩蓋 Patch／播放失敗。

AetherEngine 仍擁有 host options 之後基於 codec、carriage、能力與媒體正確性的
effective media-pipeline routing。Hybrid 不得複製該判斷；以上限制只禁止把
Syncnext-specific admission、AVKit presentation 或產品 recovery 下沉至上游。

點播由既有 URL 路徑交給 AetherEngine 取流，保留 4 秒前向緩衝偏好與漸進分片
交付。Hybrid 的單路／雙路 Range 實驗 reader、專用 telemetry 與公開測試介面已
移除；較早的 Debug 緩衝四組實驗仍保留。來源供應商的分塊併發由貓源實作負責，
來源純讀與 upstream／記憶體觀測留在 App／SyncnextCatSource 的測試路徑。

`Scripts/apply-patches.sh` 套用後出現在 submodule 的 modified files 只是
可丟棄的本地建置狀態，不是可提交的上游開發工作。

### 2.2 現有 Patch 是凍結例外，不是擴張先例

目前已批准的 AetherEngine Patch 是：

1. `0001-local-ffmpegbuild.patch`
   - 將 AetherEngine 的 FFmpegBuild dependency 改為 sibling local path。
2. `0002-independent-audio-source.patch`
   - 暴露獨立音訊 reader 所需的最小 source、timeline 與 selected-track
     interface。
3. `0004-cache-backed-fingerprint-audio.patch`
   - 為 fingerprint v2 暴露最小、有限、可取消的 loopback VOD cache PCM
     batch；一次性 material demand 不改寫 AVPlayer consumer target。
   - 非 loopback route、音軌缺失、cache 不完整或 session 改變均明確失敗，
     不回退至獨立來源下載。
4. `0007-media-request-diagnostics.patch`
   - 依使用者本次要求，提供 opt-in 的實際媒體請求生命週期與 body 位元組摘要，
     讓停止播放後的晚到資料仍可追蹤；不記錄原始 URL、headers 或媒體內容。
   - App 日誌轉送與 session 停止事件留在 Hybrid；不改變 transport、route、
     取消、背壓、重試或既有 drain 行為。範圍與退出條件見第 8 節。
5. `0008-http-disc-mime-recognition.patch`
   - 依使用者 2026-10-24 明確要求，修復無副檔名 HTTP ISO 被當成一般媒體的缺陷；
     上游 issue：[AetherEngine #860](https://github.com/superuser404notfound/AetherEngine/issues/860)。
   - 從既有取流回應或相容的 prewarm 保存／取得 `Content-Type`，以 ISO MIME
     啟動既有 DiscReader 結構辨識；一般媒體不新增 HEAD／Range 探測。
   - MIME 不作為有效光碟的證明；不改變 live、宣告 sequential origin、其他
     媒體格式或 Hybrid presentation。範圍與退出條件見第 8 節。

`0005-query-wrapped-hls-segment-ingest.patch` 已由 AetherEngine 7.45.0 原生
`LoadOptions.heldSourceConnection` 的持續 HTTP/1.1 HLS transport 取代並退出。
`0006-hls-http1-networking.patch` 亦已退出；使用者接受上游 held-source 路徑，
將 DoH 責任收斂至 App 的 process privacy context，不再要求另外一套全 HLS
HTTP/1.1 transport。當時退出的觀測 Patch 不恢復；本次媒體取消觀測例外另見第 8 節。

FFmpegBuild 的 `series` 目前為空。這些例外只能維持已批准的責任，不得順便加入：

- 一般播放缺陷修復；
- 額外 route 或 recovery；
- Syncnext 片頭判定；
- AVKit proxy 行為；
- 超出 `0007` 位元組摘要範圍的一般日誌、telemetry 或 diagnostics forwarding；
- 與獨立音訊 reader 無關的 access-level 擴張。

原 `0003-hevc-mpegts-hls-vod-remux-workaround.patch` 已被上游正式能力取代並移除；
不得把它重新加入現行 `series`。退出紀錄見 Git 歷史。

## 3. 新需求的上游侵入 Gate

如果任何需求被判定為「只有修改 AetherEngine／FFmpegBuild 才能完成」，必須
立刻停止實作。可以進行 read-only 調查，但在與開發者完成深度討論並取得明確
決定前，不得修改 submodule source、Patch、`series` 或 manifest。

討論必須至少回答：

1. **需求與缺口**：Hybrid 現有 public API 缺少甚麼？
2. **邊界證據**：為何無法只在 SyncnextHybrid／Syncnext 實作？
3. **替代方案**：等待上游、調整 Hybrid 設計、降低功能範圍是否可行？
4. **侵入範圍**：預計修改哪個 repo、哪些檔案、API 與行為？
5. **長期成本**：每次上游 release 可能產生甚麼 conflict 或語意漂移？
6. **最小化與退出條件**：Patch 如何保持最小？上游何時可取代並移除它？
7. **失敗行為**：若不批准 Patch，功能應明確 unsupported、deferred 還是
   unavailable？

討論結果必須明確分類為：

- `Approved minimal Patch`
- `Hybrid-only redesign`
- `Upstream-first`
- `Deferred`
- `Rejected`

沒有明確結論即視為 `Rejected`；不得先改完再請開發者接受。

## 4. AetherEngine release 更新流程

### 4.1 確認更新候選

以官方
[AetherEngine Releases](https://github.com/superuser404notfound/AetherEngine/releases)
頁面作為更新指標：

1. 讀取最新 release 及 release notes。
2. 預設只選擇標示為 Latest 的正式 release；pre-release、draft 或只存在於
   default branch 的 commit 不會自動成為更新候選。
3. release 頁面只負責決定 tag；實際 pin 必須從官方 remote 將該 tag 解析為
   完整 40 字元 commit SHA。
4. 記錄 release URL、tag、完整 SHA 與檢查日期。

範例只表示解析方法，不代表批准更新：

```sh
git -C AetherEngine fetch origin --tags --prune
git -C AetherEngine rev-parse 'refs/tags/<release-tag>^{commit}'
```

不得以本地快取 tag、GitHub 顯示的短 SHA 或 `origin/main` HEAD 直接更新
`Versions.env`。

### 4.2 確認 FFmpegBuild 對應版本

先查看新 AetherEngine commit 的**未套 Patch** `Package.swift`：

- 若 AetherEngine 的 FFmpegBuild requirement 沒有改變，保留目前
  FFmpegBuild pin。
- 若 requirement 改變，從 FFmpegBuild 官方 remote 將對應 tag 解析為完整
  SHA，再更新 `FFMPEGBUILD_VERSION`／`FFMPEGBUILD_COMMIT`。
- 不得因為 FFmpegBuild 自己有更新就獨立追最新版；它必須服務所選
  AetherEngine release。
- 若 AetherEngine 的 requirement 無法唯一決定應使用的 FFmpegBuild
  commit，停止更新並與開發者討論。

### 4.3 準備 root repo 更新

更新工作只能由 SyncnextHybrid root repo 管理：

1. 確認 root repo 沒有未保存的其他工作。
2. 確認 submodule remote 仍是 `.gitmodules` 登記的官方 URL。
3. 確認目前 submodule dirty diff 完全來自現有 `series`；未知 diff 必須先
   處理，不能讓腳本清掉後假裝不存在。
4. 修改 `Versions.env` 的 release version 與完整 SHA。
5. 讓 submodule gitlink 指向同一個官方 commit；保持 detached HEAD。
6. 暫時不要修改 Patch。

`Scripts/apply-patches.sh` 會刻意 reset／clean 兩個 submodule。執行它代表
接受丟棄 submodule 內所有未保存檔案；root repo 與其他路徑不在此授權範圍。

### 4.4 驗證既有 Patch

在新 pin 上執行：

```sh
./Scripts/apply-patches.sh
```

成功的定義不只是 `git apply` 沒有報錯，還必須同時滿足：

- `0001` 仍只建立 sibling local FFmpegBuild dependency；
- dependency graph 沒有第二份 remote FFmpegBuild；
- `0002` 的 source、seekability、duration 與 selected audio identity
  語意仍正確；
- AetherEngine／FFmpegBuild HEAD 等於 `Versions.env` 的官方完整 SHA；
- Patch hash、`series` 與 manifest 一致；
- SyncnextHybrid Swift resolve、build、tests 與 generic tvOS build 通過；
- 從已 patched 狀態再執行一次腳本，仍得到相同 HEAD 與相同 diff；
- Syncnext App 仍只 link／import SyncnextHybrid，且 tvOS build 通過；
- 至少完成 native AVPlayer route、AVKit proxy route 與獨立音訊分析的
  bounded smoke validation。

Patch 能套用但責任範圍擴大、API 語意改變或功能已被上游取代，都不算通過。

## 5. Patch 失效時的處理

如果 `git apply --check`、build、tests 或語意驗證任一項失敗：

1. 立即停止 upstream update。
2. 保留上一個已驗證 pin；不得提交「先升級、稍後修 Patch」的中間狀態。
3. 不得使用 `git apply --3way`、忽略 whitespace/error、手動在 submodule
   解 conflict，或擴大 Patch 直到測試碰巧通過。
4. 不得將失敗改造成 fallback、跳過測試或降低既有 contract。
5. 建立 Patch 改進討論資料，至少包含：
   - 舊版與候選 release/tag/full SHA；
   - 失敗的 Patch 名稱與原始錯誤；
   - 對應 upstream 變更；
   - Patch 原始責任是否仍必要；
   - Hybrid-only、移除 Patch、等待 upstream 與最小重寫等選項；
   - 每個選項的上游吸收成本與驗證需求。
6. 與開發者完成第 3 節的深度討論。

只有在結果是 `Approved minimal Patch` 後，才可以建立獨立 Patch 改進任務。

## 6. 已批准的 Patch 改進任務

Patch 改進必須：

1. 從候選官方 commit 的乾淨狀態重新產生，不以舊 dirty diff 繼續堆疊。
2. 一個 Patch 只承擔一個已批准責任，並保留穩定套用順序。
3. 優先縮小或刪除 Patch；不得藉 rebase 增加未討論能力。
4. 正式修改只保存於 `Patches/<repo>/*.patch`。
5. 同步更新 `series` 與 `Patches/manifest.sha256`。
6. 重新執行第 4.4 節全部驗證。
7. 在 root repo 提交 release pin、gitlink、Patch 與驗證文件；不得在
   submodule 建立或推送 patched commit。

## 7. 提交前檢查

每個 upstream update commit 必須能回答：

- 選擇的是哪個 AetherEngine release、tag 與完整 SHA？
- FFmpegBuild pin 如何由該 Aether release 決定？
- 現有 Patch 是否原封不動通過？
- 若 Patch 有變更，對應的開發者決定在哪裡？
- `apply-patches.sh` 是否可重播兩次並得到相同結果？
- Hybrid tests、tvOS build 與 Syncnext smoke validation 結果是甚麼？
- submodule 是否維持官方 remote、detached HEAD 且沒有 patched commit？

root commit 只允許包含：

- `Versions.env`；
- AetherEngine／FFmpegBuild gitlink；
- 經批准的 Patch、`series` 與 manifest；
- 必要的 Hybrid compatibility change；
- 測試及驗證文件。

任何問題沒有證據即不得更新 pin。

## 8. 決策摘要

### 無副檔名 HTTP ISO 辨識（2026-10-24）

決定：`Approved minimal Patch`。使用者在確認副檔名判斷缺口後要求先向 Aether
上游提交 issue，再編寫 Patch 修復。上游已建立
[AetherEngine #860](https://github.com/superuser404notfound/AetherEngine/issues/860)。

- 缺口：`Demuxer.openHTTP` 以副檔名作光碟路徑入口，忽略回應已宣告的
  `application/x-iso9660-image`。T4 opaque URL 因此把 ISO filesystem 直接交給
  libavformat，回報 `AVERROR_INVALIDDATA`。
- 邊界：HTTP transport、光碟 reader 與有效內容路由由 Aether 擁有。此修復留在
  該 owner，不在 Hybrid 複製 DiscReader，也不以改寫代理 URL 作產品依賴。
- 侵入：`0008` 只觸及 Aether 的 Demuxer、AVIO response metadata、prewarm
  metadata 與相應測試；不新增 public API，不變更官方 pin、remote 或 FFmpegBuild。
- 行為：以現有成功 HTTP 回應的 MIME 或相容 prewarm metadata 作探測線索，再由
  既有 ISO9660／UDF／DVD／BDMV 結構確認。誤標 MIME 沿用既有 non-disc 行為，
  不新增 provider、重試或另一套播放路徑；光碟結構／Range 錯誤照常向上拋出。
- 替代方案：只保留副檔名會留下上游辨識缺陷；等待上游暫不修復當前失敗。
  使用者已選擇上游 issue 加最小本地 Patch。
- 成本與退出：之後每次更新需重新檢查 Demuxer open、response 與 prewarm metadata
  邊界。當正式 release 原生支援此辨識、且同組回歸通過時，移除 `0008` 並同步
  更新 `series`／manifest，不保留重複路由判斷。

focused 回歸入口：`swift test --package-path AetherEngine --filter HTTPDiscMIMERecognitionTests`。
使用本機 Range origin 與可開啟 MPEG-2 影片的 DVD
ISO fixture，覆蓋兩種 HTTP transport、MIME 大小寫／參數、prewarm、一般與誤標
媒體、既有副檔名、seekable extraction、取消交接及 sequential origin。
原始遠端 ISO 與 tvOS 實際播放仍是獨立驗收，不以 fixture 開啟或編譯成功代替。

### 使用者要求的媒體取消觀測（2026-10-23）

使用者要求「先修復這三個已確認的問題，並補上底層媒體請求的日誌，方便確認
關閉播放器後是否還在下載影片」，並要求 `git commit` 保存本次結果。
本次決策為 `Approved minimal Patch`，僅涵蓋 `0007-media-request-diagnostics.patch`。

- **需求與邊界**：既有 public API 沒有引擎原始來源請求的 body 位元組與實際
  結束回呼；`stop()` 返回、App 封面請求或 loopback AVPlayer access log 均不能
  單獨證明上游來源已停止。系統網絡追蹤仍可另行驗證，等待上游 API 則無法提供
  本次要求的 App 日誌觀測。
- **範圍**：只在 AVIO 與 HLS ingest transport 的開始、回應、body 交付、取消及
  完成處插入可選 observer，新增 `MediaRequestDiagnostics` 與 focused tests。
  source／resource URL 只輸出 SHA-256；錯誤只輸出數字碼。Hybrid 擁有 sink
  安裝、App 轉送與 `MEDIA_SESSION` 停止事件，不將產品日誌 policy 下沉至上游。
- **成本與退出條件**：上游 transport 的 delegate、initializer 或 body completion
  語意變動時須重驗 hook；不接管 framing、排程、socket、背壓或 recovery。
  上游提供同等 per-request 位元組及實際完成觀測後，改用公開 API 並移除 `0007`。
- **失敗與限制**：未安裝 sink 時不建立 trace；Patch／API 不匹配明確失敗，不加
  替代 transport。AVPlayer 直接讀取遠端 HLS 不在此覆蓋；取消後單筆 body 回呼
  可能是在途資料，必須對齊 `sourceID`、時間與後續增量，不能把 stop 返回當成
  網絡完成。既有 `0001`／`0002`／`0004` 的責任及正式 pins 不變。
- **驗證**：以隔離 index 從官方 pin 重播兩次，比對完整 tree 與實作檔案，保留
  現有工作。focused transport cancellation／keep-alive／drain 測試、Hybrid
  tests、App lifecycle harness 與 generic tvOS Simulator build 分開驗證；
  這些結果不代表已完成書房電視的實機播放驗收。

### 已接受的原生 held-source 與 App DoH（2026-10-22）

使用者接受 AetherEngine 7.45.0 的原生 `heldSourceConnection` 播放路徑，並明確
要求保留 Hybrid 字幕能力、讓 DoH 由 App 正常啟用；若 `0006` 只剩觀測則退出。
這取代先前全 HLS 自訂 HTTP/1.1 networking 的要求。

- **責任邊界**：Hybrid 將 per-load `heldSourceConnection` 傳入上游 `LoadOptions`；
  持續連線、framing、FIFO admission、背壓、seek／cancel／drain 均由官方
  `PersistentHTTP1Transport` 與 `HLSVODIngestReader` 擁有，不以 Patch 重寫。
- **DoH**：供應商、設定 UI、UserDefaults 與
  `NWParameters.PrivacyContext.default.requireEncryptedNameResolution` 留在 App，
  在 process 初始化套用。所選 HTTPS resolver 是 Apple API 的 fallback resolver；
  系統既有加密 resolver／Private Relay 仍可優先使用，不能聲稱每次必定命中所選服務。
- **觀測**：只保留 App／Hybrid 自己 URLSession 的既有 metrics。上游 stream task
  的 DNS 協議未有直接證據時保持 unavailable，不為了補齊日誌而建立新 Patch 或
  更換實際承載媒體的 socket。清單可以使用 HTTP/2；HTTP 版本與 DNS 加密分開判讀。
- **字幕**：維持既有 overlay、source-clock cue 選取、掛載／移除與選單能力，
  不因網絡整合移除。字幕回歸測試與 tvOS build 需驗證。
- **驗收**：分開記錄編譯、測試、Simulator 與書房電視的實機證據。卡頓／恢復、
  無 key 請求、分片 DNS 與實際供應商未確認均獨立保留，使用者接受採用版本
  不等於將未覆蓋項目改記通過。

`0001`／`0002`／`0004` 只維持原已批准責任。Patch 重播可使用獨立
`GIT_INDEX_FILE` 從官方 pin 依序重播兩次，比對完整 tree 與 owning files，保留
現有 generated resolution 差異。這不等於執行過整支會 reset／clean 的
`apply-patches.sh`，也不取代其他尚未執行的整合驗收。

### 已授權的有限 VOD 清單 fallback（2026-10-03）

使用者已明確授權在 Hybrid source preparation 修正過小的
`EXT-X-TARGETDURATION`。僅直接 media playlist、`ENDLIST`、既有 admission
確認有限 native HLS VOD 時觸發：若最長 `EXTINF` 四捨五入後超過宣告值，
將宣告值提高至最長分片時長的 ceiling。此修正不硬編碼站點或數值。

Hybrid session 擁有僅綁定 loopback 的清單 listener；保留原分片時長、順序、
tags、headers，並以有效 response URL 將相對資源引用轉為絕對 URL。分片仍由
原站下載。診斷必須包含觸發原因、原／新 target duration、原／實際 source ID。
清單準備失敗不回退至原始不合法清單；初始化失敗、取消、stop、owner release
均釋放 listener。Live/DVR、master 的 ABR／音訊／字幕關係、HEVC remux 及既有
加密 admission 不擴張；獨立音訊分析仍讀原 request。

驗收使用原始 URL、原 headers、fresh HybridSmokePlayer `hybridAVKit` run，
要求 `nativeAVPlayer`、startup progress、seek landing、post-seek progress
及 terminal PASS，再於唯一授權的「書房電視」複驗。Direct `aetherEngine` baseline
不套用此 Hybrid-owned fallback，應獨立記錄其真實結果。

```text
一般 Hybrid 需求
  └─ 能在 Hybrid／Syncnext 完成 → 正常開發
  └─ 需要修改 upstream owner code → 停止並深度討論

AetherEngine 新 release
  └─ 現有 Patch 完整通過 → 驗證 Hybrid／Syncnext 後更新 pin
  └─ Patch 失效或語意漂移 → 保留舊 pin 並深度討論
                                  └─ 明確批准後才建立 Patch 改進任務
```
