# HANDOFF — AccelTimer 設計判断・経緯・現状

このドキュメントは、これまでの開発で蓄積した「なぜそうなっているか」をまとめた
引き継ぎ資料。コードのコメントや CLAUDE.md / AGENTS.md に書かれていない背景を含む。
**変更前に該当箇所を読み、ここに書かれた意図的な設計を壊さないこと。** 記述と実
コードが食い違う場合は実コードを正とし、本書を更新すること。

最終更新時の状態: バージョン 0.1.50 系 / Swift 6 / SwiftUI / SwiftData / iOS 17+。
リポジトリ: GitHub `toy0da/accel-timer`（main ブランチ運用）。

---

## 1. 状態機械と中核

`IDLE → ARMED → RUNNING → FINISHED`（`TimerEngine.MeasurementState`）。
`TimerEngine`（`@Observable @MainActor`）がセンサー制御・速度計算・状態遷移の核心。

- GPS（CoreLocation Doppler, 実機では概ね **1Hz**）＝速度の絶対基準。
- CoreMotion（CMDeviceMotion, **100Hz**）＝GPS 間の補間・発進検出用リングバッファ。
- スプリット時刻（0→40/60/80/100 km/h、mph表示時は0→15/30/45/60 mph）は
  **線形補間**でミリ秒精度算出。純粋関数 `TimerEngine.interpolatedCrossTime` に抽出済み
  （`AccelTimerTests` でテスト）。mphスプリットは表示用に並行記録し、完了判定は従来通り
  100 km/h到達。
- GPS 精度判定は **Doppler 速度精度 `speedAccuracy`(m/s)**。青<0.3 / 緑<1.0 /
  黄<2.0 / 赤≥2.0。赤＝UI「GPS確認中」。hAcc が良くても sAcc が悪い場合があるため
  速度精度を採用。
- 位置ベース速度との検算で Doppler 偽高速（速度だけ高く、座標がほぼ動かない）を検出した
  GPS サンプルは RUNNING 中の Kalman / split / finish / peak に混ぜない。停車中のGPS速度
  グリッチによる偽FINISHを防ぐため。誤抑制を避けるため、この判定は同じGPSサンプルで
  位置ベース速度を更新できた時だけ有効にする。

## 2. 発進検出（lookback と微速クリープ対策）

- 発進トリガー条件: `confirmedStoppedWhileArmed && READY成立から0.5秒以上 &&
  speedMs > launchThreshold && speedAccuracy < 2.0`。`launchThreshold = 10 km/h` 固定。
  **停車確認（GPS良好で速度≈0）が前提**。これは正常に効いている（実ログ全発進で成立）。
- t=0 は `lookBackStartTime` でリングバッファの静止→加速の立ち上がり点へ遡って
  アンカー（高精度）。静止区間が無い（GPS遅延）場合は加速度から速度0時刻へ
  バックエクストラポレーション。
- 2026-06-21 実走ログで 5〜9km/h の微速クリープが `START → FALSE_LAUNCH_ABORT` を
  多発させ、画面がすぐ「停車してください」に戻ることを確認。t=0 はlookBackで戻るため、
  GPSトリガーは10km/h固定へ引き上げた。READY表示をユーザーが認識できるよう、停車確認後
  0.5秒の猶予も置く。
- **微速クリープ誤発進対策（v0.1.28）**: 信号待ちの徐行（6.8km/h 等）でトリガーが
  誤発火し、徐行を含む水増し計測が完走記録される問題があった。**トリガー時の加速度
  では判別不可**（lookback が t=0 を加速前に固定するため、クリーン発進の直後加速度が
  クリープより低くなる実測あり）。判別軸は「**発進後に速度が伸びるか**」。
  フェイルセーフ: `start` から `launchConfirmSec`(5s) 以内にピークが `launchConfirmKmh`
  (25km/h) 未満なら `abortRunDueToFalseLaunch()` で破棄。実走は5秒で余裕で25km/h超、
  クリープは届かない。破棄後は車が動き続けるので（confirmedStopped が false のまま）
  再停車まで再トリガーせず、ロールング発進も防ぐ。

## 3. 減速リセットは「意図的に無効」（重要・触らない）

`TimerEngine.decelAbortEnabled = false`。RUNNING 中にピークから大きく減速したら破棄
する「減速リセット」は実装済みだが、ユーザーが「減速すると『停車してください』が
出て計測が中断されるのが嫌」と判断し **意図的に無効化**している。
- 副作用として、巡航/失速を挟んで 100km/h に達した計測の 0-100 が水増し（例 19.6 秒）
  になり得るが、ユーザーは現状これを許容している。
- 代替案（保存時に経過時間で参考値/自動除外する事後判定）は未実装・保留。勝手に
  有効化しないこと。

## 4. FINISHED 表示（区間線形補間）

100km/h 通過〜ピーク〜減速の表示は試行錯誤の末 **GPS到着ごとの区間線形補間**に
落ち着いた（デッドレコニング/α-β はピークでオーバーシュートしたため）。`finishSeg*`
変数群。100Hz モーションで区間内を lerp。完了後の停車確定でモーション停止（省電力）。

## 5. READY 整合・録画整合（v0.1.29〜0.1.30）

- **READY 表示 ＝ 停車確認 ＋ GPS良好**。以前は端末固定(deviceSteady)も要求していた
  が、発進トリガー・録画は端末固定を要求しない（手持ち計測を許可し参考値扱いする
  設計）ため不整合だった。READY を実態に合わせ、端末固定の案内はサブ文言に降格。
  → 「READY が出ている時だけ計測/録画が動く」状態。**deviceSteady をトリガー必須
  条件にしない**のが意図（固定必須＝B案は不採用）。
- **録画（プリロール）は停車確認済みなら開始**: 計測開始は引き続き `speedAccuracy < 2.0`
  を要求するが、動画は発進直前のGPS赤揺れで取りこぼさないよう `gpsIsRed` では止めない。
  2026-06-21 実走ログで、停車確認済み→一時的な赤精度→直後に発進検知という流れで
  動画が間に合わない可能性を確認したため。RUNNING中も止めない。

## 6. 参考値・手持ち検知

- 到達付近(80km/h超)の平均速度精度が緑未満、または発進時に端末が不安定だった場合、
  `MeasurementRecord.isReferenceOnly`（`finishSpeedAccuracy >= 1.0 || unstableStart`）で
  「参考値」バッジ表示。手持ち計測を**禁止せず**、品質を示す方針。

## 7. 課金（透かし除去モデル・v0.1.37）

**計測・履歴保存・共有は常に無料・無制限。無料ユーザーが共有する結果カードには
「体験版」透かしを入れ、買い切りで透かしを除去する**。
- 旧「履歴5件まで無料→超過でペイウォール」型は廃止。保存を課金で止める分岐は削除済み。
- 課金判定は `StoreManager.isPurchased` / `showsWatermark` が中心。`ResultCardView` /
  `CelebrationView` / `MeasurementDetailView` のカード共有で透かし有無を分岐する。
- 買い切り（非消費型 IAP `com.acceltimer.app.AccelTimer.unlock`、¥800、StoreKit2）。
  ローカルテストは `AccelTimer.storekit` をスキームが参照。
- `TrialKeychain.swift` は現在未使用（将来の不正防止用に残置）。
- **不変条件: 動画はレコードと対でのみ保存する**（v0.1.31）。計測中断などでレコードを
  残さない時は動画も `discardCurrentVideo()` で破棄すること。さもないと動画だけ
  保存されて孤立し、`applyPendingVideoFileName` が別計測へ誤ひも付けする。保存経路
  （attemptSaveAndArm/attemptSaveResult/10秒保険/onDisappear(finished)）はこの規則を守る。

## 8. 省電力

- **カメラセッション遅延起動（v0.1.23）**: 動画ON時、`buildSession` は起動せず、
  `startRecording`（停車確認後のプリロール開始）でセッション起動、保存/破棄で停止
  （`pauseSessionRunning`）。待機中ずっとカメラを回さない。ライブプレビューは無い。
- 表示間引き: 速度Text は `displaySpeedKmh`(~10Hz)、タイムは `displayElapsedTime`(~15Hz)。
  動画オーバーレイは `fusedSpeedKmh`/`elapsedTime`(100Hz) のままで滑らかさ維持。
- ライフサイクル: `scenePhase` で背面化/ロック時に計測を安全中止（`abortRunDueTo
  Background`）。`UIBackgroundModes` は使わない。計測タブ表示中は `isIdleTimerDisabled`。

## 9. 加速度グラフ（v0.1.29）

発進直後の加速度は `startMeasurement` がリングバッファ(`ringBufferCapacity=400`,
**4秒**)をダンプして `accelSamples`(t≥0) を作る。GPS トリガー遅延時に発進直後が
バッファから押し出される問題に対し 2秒→4秒へ拡大済み。

## 10. その他の機能

- **多言語**: String Catalog（`Localizable.xcstrings` ソース日本語＋en/ko/zh-Hans、
  `InfoPlist.xcstrings`）。`String(localized:)` の補間は %@ / %lld でキーが変わる点に注意。
  表示単位は `SpeedUnit` で km/h / mph を切り替える。中核計測・保存基準は km/h のまま。
- **mph表示**: ライブ画面では0→15/30/45/60 mphを `TimerEngine.mphSplits` で並行追跡。
  `MeasurementRecord` に `mphSplit15/30/45/60` として保存し、履歴・詳細・共有カードは
  この高精度値を優先する。旧レコードのみ `speedTimeline` 補間へフォールバック。
- **国コード記録**: `CountryGeocoder` が逆ジオコーディングで後追いバックフィル
  （将来の国別ランキング下準備）。
- **動画プリロール**: READY から録画開始し、保存時に発進点へトリミング（巻き取り）。
  オーバーレイ描画は UIKit 非依存（CoreText/CoreGraphics）。
- **常時デバッグログ**: `DebugLogger` が `Documents/debug/debug.csv` に GPS/状態を追記
  （計測保存と独立）。未トリガー調査用。計測ログは `MeasurementLogger`（GPS/MOTION/
  EVENT を CSV）。動画録画は `VIDEO_SETUP_REQUEST` / `VIDEO_SESSION_READY` /
  `VIDEO_PREROLL_START` / `VIDEO_LOCK_FOR_RUN` / `VIDEO_SAVE_START_TRIMMED` /
  `VIDEO_SAVED` / `VIDEO_ATTACHED` / `VIDEO_ERROR` / 各種 `VIDEO_DISCARD_*` を
  debug.csv の event 欄へ記録し、録画ON/権限/プリロール/保存/破棄のどこで止まったか
  追跡できるようにしている。
- 履歴は `TimerEngine.trimHistory` がリーダーボード方式（日付順30＋各速度帯上位10の
  和集合、実質30〜70件）。履歴の「並びごと除外」フラグ `hiddenFromDate/Time`。

## 11. テスト

`AccelTimerTests` ターゲット（同期グループ方式、objectVersion 77）。
`TimerEngineSplitTests` がスプリット線形補間を5ケース検証。`AccelTimer` スキームの
TestAction に含まれる。新規ロジックは可能な限り純粋関数に抽出してテストする方針。

## 12. リリース前 TODO・既知のトレードオフ

- `SettingsView` の「購入画面を表示（検証用）」デバッグボタンを削除する。
- 減速リセット無効による水増しタイムは現状許容（必要なら保存時の事後判定を相談）。
- App Store 配布には Apple Developer Program 加入・IAP 登録・審査・銀行/税務契約が必要。
  個人アカウントは販売者名に本名が公開される点に留意。
- GitHub PAT は 2026-09-13 失効予定。push 不可になったら再発行しキーチェーンに再保存。

## 13. バージョン管理

`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` は `Config/Version.xcconfig` に集約済み。
コード変更を伴う修正は `MARKETING_VERSION` のパッチを +1 する。App Store / TestFlight
提出前などビルド番号更新が必要な時は `Scripts/set_build_number.sh` を実行する。

## 14. 実機ログの解析運用

ユーザーは実走後 `Documents` 配下の `debug/debug.csv`（常時ログ：wall_time, state,
gps_mps, gps_acc_mps, h_acc_m, speed_kmh, peak_kmh, conf_stopped, dev_steady, event）と
`logs/accel_*.csv`（計測ごと：wall_time, elapsed_s, source(GPS/MOTION/EVENT),
gps_speed_mps, gps_acc_mps, h_acc_m, accel_mps2, accel_sign, kalman_mps, display_kmh,
event）を Downloads の日付フォルダに格納して共有する。Python で解析し、速度
プロファイル・スプリット・GPS精度・誤発進などを検証してから修正するのが定石。
