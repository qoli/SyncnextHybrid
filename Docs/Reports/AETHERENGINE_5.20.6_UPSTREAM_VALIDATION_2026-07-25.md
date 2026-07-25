# AetherEngine 5.20.6 上游更新驗證

驗證日期：2026-07-25  
SOP：[`HYBRID_MAINTENANCE_SOP.md`](../HYBRID_MAINTENANCE_SOP.md)  
狀態：**Blocked — 不得更新正式 pin**

## 1. 結論

AetherEngine `5.20.6` 通過 Patch、dependency graph、Hybrid tests、generic
tvOS build 與 Syncnext App build 驗證；現有兩個 AetherEngine Patch 可以在
候選 commit 上原封不動重播，沒有 Patch 失效或責任漂移。

但書房電視的 bounded device smoke 沒有取得可接受的播放通過證據：

- `nativeAVPlayer` 的 H.264/AAC 在啟播階段 60.5 秒沒有媒體時間進度；
- `avKitProxy` 的 MPEG-2/AC3 正確 seek 到 150 秒後，60.5 秒沒有媒體
  時間進度。

因此本次答案是：

```text
Patch／SPM compatibility: PASS
Hybrid／Syncnext build:   PASS
Device playback gate:     FAIL
Overall promotion:        BLOCKED
```

正式工作區繼續保留：

```text
AetherEngine  5.20.2  e2dcbb9711439867eca13ba30fc45f70d7631162
FFmpegBuild   2.2.0   e832f22c89909297b7abe3a94c05b2816414b054
```

沒有修改正式 `Versions.env`、submodule gitlink、Patch、AetherEngine 或
FFmpegBuild owner code。這次也沒有新增 log Patch、fallback、recovery
或替代播放器。

## 2. Release 與 commit 證據

官方 release：

```text
release:       5.20.6
release name:  5.20.6 - PGS seek-landing reconstruction through clear-only successors
published:     2026-07-24T16:14:21Z
release URL:   https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.6
tag object:    cf1dfc2a0c90875fc75c1b4649fc0f3837635e28
tag commit:    4775d53ced6a6fb523e0e167efb19092115f25cc
```

候選 commit 的未套 Patch `Package.swift` 仍要求 FFmpegBuild `2.2.0`。
官方 `2.2.0` tag 解析為現有 pin
`e832f22c89909297b7abe3a94c05b2816414b054`，所以沒有追逐另一個
FFmpegBuild 版本。

本次亦查看 `5.20.3` 至 `5.20.6` release notes。與現有 Patch 接觸的
upstream 檔案中，`Package.swift` 與 `Demuxer.swift` 沒有 upstream
變更；`AetherEngine.swift` 只有 deinterlace hardware warmup 初始化
變更。沒有發現 Patch 責任被上游取代或擴張。

## 3. 隔離方式

驗證使用由 SyncnextHybrid commit
`693cbf81c44eda1e857b4bbcfa3c3a7b6c78a629` 建立的隔離 checkout：

```text
/tmp/syncnexthybrid-upstream-verify.vdKnP3/
```

只在隔離 root repo 內將：

```text
AETHERENGINE_VERSION=5.20.6
AETHERENGINE_COMMIT=4775d53ced6a6fb523e0e167efb19092115f25cc
```

與 AetherEngine gitlink 一起暫存後執行驗證。正式 SyncnextHybrid
工作區沒有切換候選 pin。

第一次準備第二輪 replay 時，隔離 root gitlink 尚未與候選
`Versions.env` 一起更新，`git submodule update` 因拒絕覆蓋候選
submodule 而停止。這是 SOP 的 root pin 一致性防護生效，不是 Patch
失敗。將隔離 gitlink 指向同一官方 commit 後，兩輪完整 replay 均通過。

## 4. Patch 與建置結果

| 驗證項目 | 結果 | 證據 |
| --- | --- | --- |
| 官方 release tag 解析為 full SHA | PASS | `5.20.6` → `4775d53ced6a6fb523e0e167efb19092115f25cc` |
| FFmpegBuild requirement | PASS | 未套 Patch manifest 仍為 `2.2.0` |
| submodule official remote／detached HEAD | PASS | 隔離 checkout 使用官方 repo 與指定 SHA |
| `0001-local-ffmpegbuild.patch` | PASS | 未修改 Patch 即套用 |
| `0002-independent-audio-source.patch` | PASS | 未修改 Patch 即套用 |
| `apply-patches.sh` 完整 replay 兩次 | PASS | HEAD、manifest、diff 均一致 |
| local-only dependency graph | PASS | AetherEngine 與 FFmpegBuild 都解析到隔離 sibling path，沒有 remote duplicate |
| `swift build --target SyncnextHybrid` | PASS | build completed |
| `swift test` | PASS | 8 tests，0 failures |
| SyncnextHybrid generic tvOS build | PASS | `BUILD SUCCEEDED` |
| Syncnext generic tvOS App build | PASS | `BUILD SUCCEEDED`，App target 只 link Hybrid |

隔離 Syncnext clone 第一次 build 缺少 repo 原本 gitignored 的
`libs/Openlistlib.xcframework`，因此在進入候選編譯前停止。供應正式工作區
已有的 framework／provenance，並以
`OPENLIST_TVOS_FRAMEWORK_ROOT=/Volumes/Data/Github/SyncnextProjects/OpenList-tvOS-Framework`
指向既有本地 framework source 後，完整 generic tvOS App build 通過。
這是隔離 checkout 的 local build-input 缺口，不是 AetherEngine `5.20.6`
的 compile failure；沒有為此修改 Syncnext source。

兩次 replay 後的 patched 檔案 SHA-256 完全相同：

```text
AetherEngine/Package.swift
  a9833835ec860db800b4c084eb4a3204fdeb722e027f690ca63e4326af00f94c
AetherEngine/Sources/AetherEngine/AetherEngine.swift
  e8c80c96814cbe94fe2fe68a227d121fbc8b6e7a61a3f2e1440b064e7a44bc81
AetherEngine/Sources/AetherEngine/Demuxer/Demuxer.swift
  ce5ad519faf4ea0a5b070419ad5372d327f5b0e1bad107b4b4975ff06eb637b3
AetherEngine/Sources/AetherEngine/AetherEngine+IndependentAudioSource.swift
  abe70be0a9677ef54c89d67b033772925b865fa7cc4ab61feb26355cb8d0e4d1
```

八個 Swift tests 包含實際獨立 FFmpeg demux／decode／resample、seekable
HLS VOD 獨立 cursor、Live／DVR 明確失敗、單 consumer、背壓取消與固定
PCM contract。

唯一新增觀察是既有 `0002` 產生的
`mediaSelectionGroup(forMediaCharacteristic:)` macOS 13 deprecation
warning；它沒有造成 build failure。本次不以處理 warning 為由修改或
擴張 Patch。

## 5. 書房電視 bounded smoke

環境：

```text
device:             書房電視
device label:       study-room-apple-tv
CoreDeviceID:       4F403AE1-B129-5248-BC6E-31DFDD75B422
Xcode destination:  771d28ce0d2fe7b0ac1a9fa5d73424b89b54c8a2
signed app SHA-256: 120afe2bcb1797b4a600c58b52a3dac59bf14bdc0f35ce05966608ff7cc74376
```

本輪刻意只執行一個 native route 與一個 proxy route，且沒有用 retry
覆蓋第一次失敗：

| Case | Route | 結果 | 關鍵觀察 |
| --- | --- | --- | --- |
| progressive native H.264/AAC | `nativeAVPlayer` | `failed_aether` | 初始 `-0.083s`；phase 進入 `playing`，但 60.5 秒仍停在 `-0.083s` |
| progressive MPEG-2 interlaced/AC3 | `avKitProxy` | `failed_aether` | startup 前進 `0.398s`；seek 落在 `150.000s`，其後停在 `150.051s / paused` 達 60.5 秒 |

結構化結果：

```text
passed:          0
failed_aether:   2
failed_syncnext: 0
pending:         0

native:
  error_code:    no_media_progress
  failure_stage: playback_health
  run_id:        d2cab7c5-3238-406b-8814-312a20bf101e

proxy:
  error_code:    no_media_progress
  failure_stage: post_seek_progress
  run_id:        b98569fd-c4e3-42a7-9a1d-3af2d84a8dd4
```

這兩種 signature 都已在 `5.20.2` 的
[`06-seek-5min` 報告](../../../Syncnext/Docs/Reports/SYNCNEXTHYBRID_PLAYER_TEST_06_SEEK_5MIN_2026-07-24.md)
中出現：native H.264/AAC 曾以同一 `-0.083s / playing` 型態間歇性停住；
MPEG-2/AC3 proxy 亦持續在 150 秒 seek 後回到 `paused`。因此本次選定的
兩個 smoke case 沒有提供新的 failure signature 證據，但「與既有失敗
相同」不等於候選已通過，不能用 baseline parity 取代 SOP 的 clean pass。

## 6. Evidence hash

結構化 device evidence 已保留在 Syncnext 既有的 ignored artifact root：

```text
Tests/AetherIntegration/.artifacts/
  syncnexthybrid-upstream-aetherengine-5.20.6-20260725/
```

```text
format catalog
  788c06308a109117dbab8c05d2f30eb57ccc47b9959575b5472383c8a51fddba
matrix
  1373e554bf13e0cdf884a47a7204849adcbf834fe1c5eb87e2d7de4dbf8f93fb
summary.json
  ae3220636760c4101c584331d0cf4fee1671781c40290d1a2111a6f142a53c46
runner metadata
  dd630e4fbe7fffc3d76562012965b8e662fbde701f923eb8079c7d3bc4ec8b00
native events
  bdfc1dfdeb04a917ce1d014cb3c59de68f5a2d63ea6f850112bac90228cd22b3
proxy events
  53e81cf19ba9a05674ebd785a37710ecb2c63bf0cfc608bdf4e090004b723a28
signed device xcodebuild.log
  57541a636404a53618c82c3e435797559d1d82d634d2ae0f383fb7f11c48000b
```

複核 hash 後，約 11.6 GB 的隔離 checkout 與 DerivedData 已移至系統
垃圾桶；上述 1.4 MB 結構化 evidence 與 build log 仍保留，可獨立檢查。

## 7. 決策與下一個 Gate

本輪不是 Patch 改進 Gate：

- Patch 沒有失效；
- Patch 語意沒有漂移；
- 不需要修改 AetherEngine／FFmpegBuild owner code；
- 不需要建立或討論新的上游侵入能力。

它是 runtime acceptance 未通過。候選 `5.20.6` 可以保留為下一輪同一
candidate 的驗證對象，但在 native／proxy bounded smoke 取得 clean pass
且其餘 SOP device acceptance 閉合前，不得提交 `Versions.env` 或
submodule gitlink 更新。
