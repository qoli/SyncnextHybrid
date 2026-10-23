# macOS 原生起播基線

在 Mac 以同 pin 的 AetherEngine 播放實際 URL，使用持續來源連線、漸進分片及
4 秒前向緩衝偏好。此獨立 App 不等同 tvOS Hybrid／一般 App 完整生命週期；
來源服務的準備時間由呼叫端另記。測試靜音，保留原音訊解碼／封裝路徑。

使用 `script/build_and_run.sh --build-only` 建立完整原生 `.app`，再以
`script/build_and_run.sh --launch-only --fixture /private/path/fixture.json` 重複量測同一 binary。
正常 build/run、`--verify`、`--logs`、`--telemetry` 與 `--debug` 亦由該腳本提供。

私人 fixture 欄位為 `url`、`httpHeaders`、`probeBytes`（null 保留引擎完整預算）、
`observationSeconds`、`startupDeadlineSeconds`、全新 `outputDirectory` 與
`exitWhenFinished`。憑證、來源 URL、fixture 及結果必須留在 repo 外或 ignored 位置；
不可把 URL／headers 直接放進命令列。失敗不換源、不補 play 或改用其他播放器。
引擎 stdout／stderr 由 App 寫入該輪的 `engine.*.private.log`，不使用
LaunchServices 的輸出重導參數；這些記錄可能包含私人來源資訊，不可公開。

`captureProbeDetails: true` 僅在本測試 App 的主探測期間，透過同 pin FFmpeg
公開 API 將日誌設為 DEBUG；`streamsProbed` 或錯誤離開時恢復原等級。
公開 `EngineLog.handler` 以非同步私人檔案 sink 保存有時間戳及執行緒 ID 的
`engine-events.private.jsonl`，不改 SDK、FFmpeg source、探測預算或傳輸行為。
一般等級對照使用 `false`／省略此欄位，必須分開記錄診斷成本與來源速度波動。
事件的 `process_cpu_*_seconds` 為整個程序各執行緒的 CPU 累計；兩階段之差
只能作探測計算成本的上限，不能當成 FFmpeg 的獨佔 CPU 時間。
經過時間減去程序 CPU 是非 CPU 時間的下限，仍需執行緒取樣辨識資料等待。

`events.jsonl` 依同一 monotonic clock 記錄 engine checkpoint、load、首次 playing、
首次驗證進度、至少 2 秒媒體前進、逐秒緩衝／有限片長及 terminal。
首次解碼幀以 AVPlayerItemVideoOutput 的真實 pixel buffer 為證，與畫面呈現分開；
原生視窗截圖必須另外檢查。早期每 100ms 取樣，證明 2 秒進度後每秒取樣。
`completed` 只代表觀察期結束，必須同時比較等待與相同媒體位置的到達時間。
`moving_media_seconds` 只累計相鄰兩次皆 playing 的已驗證前進；跨等待邊界的
前進未計入，不能當整個觀察期的總播放長度。`waiting_seconds` 為取樣估計。

分解起播時，以 `renderer_load_begin` 為播放器端起點，依序比較
`sourceOpened`、`containerOpened`、`streamsProbed`、`renderer_load_completed`、
`play_requested`、`first_decoded_frame` 及 `first_verified_progress`。
串流探測包含讀取媒體的等待，不能把整段耗時直接記成 CPU 分析成本。
SDK 的 `presenting`、實際解碼幀、連續媒體時間前進及原生視窗可見畫面為不同證據。
來源冷啟動、搜尋／劇集取得、App 啟動須在呼叫端以連續時間線另記；
不能把分開執行的量測相加，或把搜尋準備當成每次按播放的固定成本。

可選的 `seekPlan` 在起播觀察期結束後執行定位測量，不調整 probe 預算、緩衝或
恢復策略。其 `steps` 每筆包含 `label` 與 `targetSeconds`／`relativeSeconds` 其中
一項；plan 同時明定 `recoveryDeadlineSeconds`、`minimumProgressSeconds`、
`settleProgressSeconds`、`sampleIntervalSeconds`。這些是測量及驗收條件，
不是傳入引擎的網絡限制。`input` 為 `aetherPublicSeek`（預設）或
`nativeAVPlayerSeek`；後者直接使用現有 native player 的零容差 seek，對應
Hybrid native route 的 AVKit 交付邊界，不宣稱測過 tvOS 遙控器或完整 App。

每次 seek 分別記錄 request、API dispatch／return、目標位置的新 pixel buffer、
首次已驗證進度及連續進度恢復；API return 不能當成畫面或持續播放完成。
frame witness 每次重設，並檢查 pixel buffer 的 display timestamp 在目標附近，
排除 seek 前的舊畫面。所有 sample 必須維持 `preferredForwardBufferDuration=4`；
變更、失敗、取消或超時直接結束該輪，不補 play、不換源、不新增 recovery。
seek 跨越的時間跳變不計入媒體前進；起播統計須截在第一個 seek request 之前。
公開媒體 request sink 也寫入帶單調時間戳的私人 engine log，可對齊來源 Range、
producer restart 的原有階段日誌、HLS 供應、AVPlayer 等待及解碼。
