# 0008 退役回歸

此目錄保留 #860 的 downstream 對等案例與 fixture helpers，由 Hybrid root 擁有。
它不屬於任何生產 target，不透過 `.patch` 修改 Aether source。

```sh
python3 Scripts/verify-disc-retirement.py --output-dir /tmp/syncnext-disc-retirement
```

runner 以 `Versions.env` 的官方完整 SHA 和目前 `series` 產生來源快照，重播兩次比對
tree，再把此處三份測試檔覆蓋到臨時 Aether 測試 target。它會執行既有上游光碟／
load cancellation tests、本目錄的辨識及取消案例，以及 committed Hybrid 全套測試。
同來源重跑可加 `--resume`，保留該快照的 build cache。現有 submodules 和其他任務的
dirty source 都不會被 reset／clean。

取消的判定為：取消確實發出、開啟失敗、取消後沒有新增請求，或實際 HTTP transfer
完成。`sourceOpened` 可以發生在光碟已識別之後；其之前已完成的合法探測不能算作
取消後的新工作。共用 URLSession 的 idle keep-alive socket 也不代表請求仍在執行。

模擬器播放 fixtures：

```sh
python3 Scripts/prepare-disc-retirement-fixtures.py --output-dir /tmp/syncnext-disc-fixtures
```

輸出 45 秒 MPEG-2／AC-3 的 ISO9660 DVD 與 fragmented UDF DVD。由 Syncnext 的
`Scripts/aether_disc_retirement_origin.py --root <fixtures> --log <origin.jsonl>`
提供 Range origin 及 `/status`，啟動 `DiscRetirement` Debug
case，使用 `--disc-retirement-row=iso|udf|cancel` 和 `--disc-retirement-url=<來源>`。
`cancel` 另接收 `--disc-retirement-status-url=<origin>/status`，只在本輪真實來源 GET
已抵達後取消。App case 不建立生產 HTTP 入口，並恢復自己對 retained Simulator 的
設定覆寫。畫面、日誌與斷言須使用同一 run ID 核對。

`ISO9660Fixture.swift`、`KeepAliveRangeOrigin.swift` 取自 AetherEngine 測試支援，
Copyright (C) 2026 Vincent Herbst，授權見 `UPSTREAM_LICENSE`；保留原有 downstream
fixture placement／request recording 擴充。退役前的取消測試與 Patch 可由 Git 歷史查閱。
