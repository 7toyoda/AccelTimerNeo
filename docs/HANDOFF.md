# HANDOFF — AccelTimer 設計判断・経緯・現状

このドキュメントは、これまでの開発で蓄積した「なぜそうなっているか」をまとめた
引き継ぎ資料。コードのコメントや CLAUDE.md / AGENTS.md に書かれていない背景を含む。
**変更前に該当箇所を読み、ここに書かれた意図的な設計を壊さないこと。** 記述と実
コードが食い違う場合は実コードを正とし、本書を更新すること。

最終更新時の状態: バージョン 0.1.64 系 / Swift 6 / SwiftUI / SwiftData / iOS 17+。
リポジトリ: GitHub `toy0da/accel-timer`（private・main ブランチ運用）。
作業コピーは dev（`/Users/user01/dev/AccelTimer`・Xcode用）と Codex（`work/accel-timer`）の
2つ。push したら両者を同期する（dev で push → Codex 側を `git pull --ff-only`）。

**このセッション（〜v0.1.64）の主な変更:** ①課金を透かしモデル→トライアル課金へ全面変更
（§7）。②停車確認しきい値に下限を追加し「停車してください」頻発を解消（§2, v0.1.58）。
③mph 単位対応（§10）。④バージョンを xcconfig に集約（§13）。⑤ログの wall_time を端末
ローカル時刻に統一（§14, v0.1.60）。⑥検証用に「トライアルリセット」「診断ログ ZIP 共有」
を `#if DEBUG` で追加（§10/§12）。⑦ARMED表示と低速誤発進を再調整し、5〜10km/hの徐行や
hAcc悪化時の「停車してください」連発を抑制（§2/§5, v0.1.64）。

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
  speedMs > launchThreshold && speedAccuracy < 2.0`。`launchThreshold = 13 km/h` 固定。
  **停車確認（GPS良好で速度≈0）が前提**。
- **停車確認しきい値の下限（v0.1.58・重要修正）**: 停車判定は
  `TimerEngine.stoppedThresholdMs(speedAccMs:) = max(1.0, min(sAcc, 1.4))` m/s
  （下限 3.6km/h・上限 5km/h）。arm() と handleGPS の2箇所で共通使用。
  **下限が無い旧実装 `min(sAcc,1.4)` だと、GPS精度が良い(sAcc≈0.3m/s)とき しきい値が
  1.1km/h まで小さくなり、駐車中でも GPS Doppler の揺らぎ(~1.5-2.7km/h)を超え続けて
  永遠に停車確認できず「停車してください」が消えない**バグがあった（2026-06-21 実走ログで
  確認）。下限 1.0m/s で吸収。発進トリガー(>10km/h)・上限(1.4)は不変なので誤停車・発進検知へ
  の影響なし。実ログ検証: 修正後は「実停車(speed<3.6km/h)＋GPS良好」で停車確認失敗ゼロ。
- 停車確認は **Doppler速度精度(sAcc)とDoppler速度** で判定する。水平精度(hAcc)は座標品質であり、
  sAccが良好で速度が停車しきい値内なら、hAccが一時的に30m超でも停車確認を成立させる。
  2026-06-21 23時台ログで、実停車(speed≈0, sAcc≈0.3)なのに hAcc≈43m のため
  `confirmedStopped=false` が続き「停車してください」が出続けたため修正。
- 発進検知が高速(13-18km/h)で出るのは GPS ~1Hz 更新の遅延（t=0 は lookBack 補正で正確）。
  渋滞クリープで誤発進→即 FALSE_LAUNCH_ABORT が出やすいのは仕様（下記フェイルセーフが除去）。
  v0.1.64でトリガーを10→13km/hへ引き上げ、5〜10km/hの徐行で `START → FALSE_LAUNCH_ABORT`
  になる頻度を下げた。t=0はCoreMotion lookBackで戻すため開始時刻精度は維持する。
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
- **v0.1.64 ARMED表示**: READYは `confirmedStoppedWhileArmed && displaySpeed < 2km/h` の実停車に限定。
  `displaySpeed >= 3km/h` は「走行中」とし、5〜10km/hの徐行で命令口調の「停車してください」を
  出さない。停車確認待ちは「停止確認中」に変更。計測トリガーとは別のUI分類であり、精度ロジック
  そのものを緩める目的ではない。
- **録画（プリロール）は停車確認済みなら開始**: 計測開始は引き続き `speedAccuracy < 2.0`
  を要求するが、動画は発進直前のGPS赤揺れで取りこぼさないよう `gpsIsRed` では止めない。
  2026-06-21 実走ログで、停車確認済み→一時的な赤精度→直後に発進検知という流れで
  動画が間に合わない可能性を確認したため。RUNNING中も止めない。
- 動画の準備状態（`VIDEO_SESSION_READY` 等）は常時デバッグログで追跡する。計測画面の
  通常UIには検証用の `VIDEO READY` / `CAM...` は出さず、録画中の `REC` だけを表示する。
  設定の動画/音声トグルは、カメラ/マイク権限が拒否・制限されている場合はONのまま残さない。

## 6. 参考値・手持ち検知

- 到達付近(80km/h超)の平均速度精度が緑未満、または発進時に端末が不安定だった場合、
  `MeasurementRecord.isReferenceOnly`（`finishSpeedAccuracy >= 1.0 || unstableStart`）で
  「参考値」バッジ表示。手持ち計測を**禁止せず**、品質を示す方針。

## 7. 課金（トライアル課金モデル・v0.1.53〜）

**現行モデル: 累計30回の「完走」まで無料 → 使い切ると1日1回まで無料 → 買い切りで無制限。**
中核計測（＝唯一価値があるもの）をゲートする唯一の形。サブスク/バックエンドは持たない方針
（ユーザー本気度＝「小遣い・低負担」）。**透かし/結果カード共有モデルは廃止**（ユーザーが
カード共有にも動画にも価値を感じないと明言。コードも削除済み）。

- 判定: `StoreManager.canMeasure = isPurchased || !trialExhausted || !freeUsedToday`。
  `freeTrialLimit = 30`、`trialCount`/`lastFreeDay` は `TrialKeychain`（再インストールでも
  リセットされない）をミラーした @Observable プロパティ。`freeTrialRemaining`/`trialExhausted`/
  `freeUsedToday` で UI 表示。
- 「完走＝1回消費」の定義は **表示単位依存**: km/h は 100km/h 到達(`isComplete`)、
  mph は 60mph 到達(`saved.splitTime(unit:.mph, band:3) != nil`)。`ContentView.registerIfCompleted`
  が新規完走レコード保存時のみ `store.registerCompletedMeasurement()` を呼ぶ。未達/誤発進は
  消費しない。
- **計測開始ゲート**: 全 `arm()` 呼び出し箇所を `store.canMeasure` でガード。枠超過時は
  `attemptSaveAndArm` で `saveAndArm`（動画経路は不変のまま）後、**次runloopで `engine.cancel()`**
  して `lockedMeasurementOverlay`（購入導線）を表示。`handleStateChange` の idle 自動 arm も
  canMeasure ガード必須（cancel→idle で再 arm しないため）。
- 買い切り（非消費型 IAP `com.acceltimer.app.AccelTimer.unlock`、¥800、StoreKit2）。
  ローカルテストは `AccelTimer.storekit` をスキームが参照。`PaywallView` は「無制限解放」訴求。
- **削除済み（旧透かしモデルの残骸）**: `ResultCardView.swift` / `CelebrationView.swift` /
  `StoreManager.showsWatermark` / 新記録祝福シート。新記録の高揚はスプリット/履歴の金色
  ハイライトで継続。
- **不変条件: 動画はレコードと対でのみ保存する**（v0.1.31）。計測中断などでレコードを
  残さない時は動画も `discardCurrentVideo()` で破棄すること。さもないと動画だけ
  保存されて孤立し、`applyPendingVideoFileName` が別計測へ誤ひも付けする。保存経路
  （attemptSaveAndArm/attemptSaveResult/10秒保険/onDisappear(finished)）はこの規則を守る。
  トライアル枠超過時の cancel は **saveAndArm の後（＝動画保存後）に async** で行い、この規則を崩さない。

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
  `MeasurementRecord` に `mphSplit15/30/45/60` として保存し、履歴・詳細は
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
  HistoryView の並び替え帯は「単位×index(0..3)」へ一般化（`MeasurementRecord.splitTime(unit:band:)`）。
  ただし **trimHistory のデータ保持帯は km/h 基準のまま**（保持⊇表示なので実害小・データ消失回避）。
- **ログ時刻はローカル時刻（v0.1.60）**: DebugLogger / MeasurementLogger の ISO8601 に
  `timeZone=.current` 設定済み。例 `2026-06-21T20:09:49.080+09:00`。ファイル名のローカル時刻と
  一致し時差換算不要。**既存ログ（旧版）は UTC(`Z`)なので+9hで読む**。
- **検証用ツール（`#if DEBUG`・SettingsView）**: トライアルのリセット（`StoreManager.resetTrial()`）、
  購入画面の即時表示、診断ログの ZIP 共有（`makeLogsZipURL`＝NSFileCoordinator .forUploading で
  debug.csv＋logs/*.csv を `AccelTimer-logs-<日時>.zip` 化→共有シート/AirDrop）。リリースビルドでは
  自動的に消える。

## 11. テスト

`AccelTimerTests` ターゲット（同期グループ方式、objectVersion 77）。
`TimerEngineSplitTests` がスプリット線形補間を5ケース検証。`AccelTimer` スキームの
TestAction に含まれる。新規ロジックは可能な限り純粋関数に抽出してテストする方針。

## 12. リリース前 TODO・既知のトレードオフ

- 検証用UI（トライアルリセット/購入画面表示/診断ログZIP共有）は `#if DEBUG` 済みなので
  リリースビルドでは自動的に除外される（手動削除は不要）。
- 減速リセット無効による水増しタイムは現状許容（必要なら保存時の事後判定を相談）。
- 動画保存が一度 `VIDEO_SAVE_TIMEOUT` を記録（直後に `VIDEO_SAVED` で復帰・実害なし）。
  頻発するなら保存経路のタイミングを見直す（現状は監視レベル）。
- ワイヤレスデバッグ（Connect via Network）は通常のWi-Fiルーター環境が前提。
  iPhoneテザリング(Personal Hotspot)では不可。ルーターWi-Fiが無ければ有線でビルド。
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
