# SyncnextHybrid 維護 SOP

更新日期：2026-07-25  
狀態：Active  
Owner：SyncnextHybrid

## 1. 目的

本 SOP 定義 SyncnextHybrid 的日常開發、AetherEngine 上游更新與 Patch
維護邊界。最高優先級是：

1. SyncnextHybrid 必須能安全吸收 AetherEngine 上游 release。
2. Hybrid 開發不得把產品需求轉嫁成 AetherEngine／FFmpegBuild 的長期
   維護負擔。
3. 所有上游例外修改都必須可見、可重播、可審核及可撤回。

## 2. 不可違反的責任邊界

### 2.1 一般開發不得修改上游 owner code

任何一般功能、錯誤處理、UI、route、recovery、日誌、automation 或
Syncnext-specific 行為，都必須實作在：

- `Sources/SyncnextHybrid/`；
- Syncnext App；
- SyncnextHybrid 自己的測試與文件。

不得直接在 `AetherEngine/` 或 `FFmpegBuild/` submodule 內完成需求，也不得：

- 在 submodule 建立產品分支或提交 patched commit；
- 把 patched commit 推到官方 repo、遠端 fork 或臨時 fork；
- 將沒有對應正式 `.patch` 的 dirty worktree 當作實作成果；
- 為了方便整合而更換 `.gitmodules` 的官方 remote；
- 把 Syncnext 判定、AVKit proxy、播放 recovery 或 log forwarding 放入上游
  source；
- 使用模糊 fallback、另一個播放器或未記錄的替代路徑掩蓋 Patch／播放失敗。

`Scripts/apply-patches.sh` 套用後出現在 submodule 的 modified files 只是
可丟棄的本地建置狀態，不是可提交的上游開發工作。

### 2.2 現有 Patch 是凍結例外，不是擴張先例

目前已批准的 AetherEngine Patch 是：

1. `0001-local-ffmpegbuild.patch`
   - 將 AetherEngine 的 FFmpegBuild dependency 改為 sibling local path。
2. `0002-independent-audio-source.patch`
   - 暴露獨立音訊 reader 所需的最小 source、timeline 與 selected-track
     interface。
3. `0003-hevc-mpegts-hls-vod-remux-workaround.patch`
   - 臨時修補 AetherEngine #246：僅在 Hybrid 已確認為有限 HEVC
     MPEG-TS HLS 且明確設定 `nativeRemoteHLS=false` 時，提供可按時間 seek
     的 TS ingest，再沿 AetherEngine fMP4 remux 路徑播放。
   - 此項是可拋棄的下游 workaround；移除條件與驗收證據記錄於
     `Docs/Workarounds/AETHERENGINE_HEVC_HLS_BLACK_WORKAROUND.md`。
4. `0004-cache-backed-fingerprint-audio.patch`
   - 為 fingerprint v2 暴露最小、有限、可取消的 loopback VOD cache PCM
     batch；一次性 material demand 不改寫 AVPlayer consumer target。
   - 非 loopback route、音軌缺失、cache 不完整或 session 改變均明確失敗，
     不回退至獨立來源下載。

FFmpegBuild 的 `series` 目前為空。這些例外只能維持已批准的責任，不得順便加入：

- 一般播放缺陷修復；
- 額外 route 或 recovery；
- Syncnext 片頭判定；
- AVKit proxy 行為；
- 日誌、telemetry 或 diagnostics forwarding；
- 與獨立音訊 reader 無關的 access-level 擴張。

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

```text
一般 Hybrid 需求
  └─ 能在 Hybrid／Syncnext 完成 → 正常開發
  └─ 需要修改 upstream owner code → 停止並深度討論

AetherEngine 新 release
  └─ 現有 Patch 完整通過 → 驗證 Hybrid／Syncnext 後更新 pin
  └─ Patch 失效或語意漂移 → 保留舊 pin 並深度討論
                                  └─ 明確批准後才建立 Patch 改進任務
```
