# 字幕樣式 Probe

獨立 tvOS App；啟動立即顯示固定字幕，不開啟影片、不存取 MorePlay 或網路。
遙控器左右切換亮暗分區、純黑與亮色背景。

- A 保留單次 attributed stroke，便於重現字身發黑／空心的問題。
- B 是已選定的實心白字，不加描邊；文字圖層後方加黑色陰影，
  opacity 0.68、offset (0, 6)、radius 12。
- C 直接編譯正式 `HybridSubtitleOverlayView.swift` 與
  `HybridSubtitlePresentation.swift`，不是另一份字幕 renderer。

在此目錄執行 `xcodegen generate`，開啟 `SubtitleStyleProbe.xcodeproj`，
選擇可見的 tvOS Simulator 執行。修改正式 renderer 後重跑此 App 即可。
