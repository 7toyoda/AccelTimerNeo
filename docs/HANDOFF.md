# HANDOFF — AccelTimer 設計判断・経緯・現状

このドキュメントは、これまでの開発で蓄積した「なぜそうなっているか」をまとめた
引き継ぎ資料。コードのコメントや CLAUDE.md / AGENTS.md に書かれていない背景を含む。
**変更前に該当箇所を読み、ここに書かれた意図的な設計を壊さないこと。** 記述と実
コードが食い違う場合は実コードを正とし、本書を更新すること。

最終更新時の状態: バージョン 0.1.67 系 / Swift 6 / SwiftUI / SwiftData / iOS 17+。
リポジトリ: GitHub `toy0da/accel-timer`（private・main ブランチ運用）。
作業コピーは dev（`/Users/user01/dev/AccelTimer`・Xcode用）と Codex（`work/accel-timer`）の
2つ。push したら両者を同期する（dev で push → Codex 側を `git pull --ff-only`）。

**このセッション（〜v0.1.66）の主な変更:** ①課金を透かしモデル→トライアル課金へ全面変更
（§7）。②停車確認しきい値に下限を追加し「停車してください」頻発を解消（§2, v0.1.58）。
③mph 単位対応（§10）。④バージョンを xcconfig に集約（§13）。⑤ログの wall_time を端末
ローカル時刻に統一（§14, v0.1.60）。⑥検証用に「トライアルリセット」「診断ログ ZIP 共有」
を `#if DEBUG` で追加（§10/§12）。⑦ARMED表示と低速誤発進を再調整し、5〜10km/hの徐行や
hAcc悪化時の「停車してください」連発を抑制（§2/§5, v0.1.64）。⑧次回実走調査用に
debug.csv の event 欄へ ARMED中のUI表示状態を記録（§14, v0.1.65）。⑨赤GPS中の発進取りこぼしと
偽発進判定の時刻基準を修正し、走行中ARMEDの長時間残留を抑制（§2, v0.1.66）。⑩発進検出の根本リファクタ
（§2, v0.1.67）：停車確認を位置ベース速度と融合（sAcc赤張り付きでの取りこぼし解消）、偽発進アボートを
dopplerLooksFakeガードの外へ（クリープ破棄の18秒遅延解消）、ARMEDラッチ遷移を純粋関数 `updateArmedLaunch`
へ集約してテスト化（実走ごとの例外追加ループを断つ）。

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
- **赤GPS中の発進救済（v0.1.66）**: 停車確認済みの直後にGPS速度精度が赤(sAcc≥2.0)になり、
  そのまま発進すると、旧実装は赤の移動サンプルで `confirmedStopped=false` に戻し、緑へ戻った時点
  ではすでに走行中のため再トリガーできなかった。2026-06-22 00:17台ログでは最高105.72km/hまで
  `ARMED/UI=DRIVING` のまま残留。修正後は停車確認済みから赤GPSのまま動き始めた場合だけ
  `poorGPSLaunchGraceSec`(5s) の猶予を置き、緑へ戻った瞬間に通常の13km/hトリガーを許可する。
  猶予を超えた移動は従来通りラッチ解除し、ロールング発進は許可しない。
- **発進検出の根本リファクタ（v0.1.67・重要）**: 2026-06-22 01時台の検証走行ログで2つの構造的バグを確認し、
  小手先の分岐追加ではなく根本から作り直した。3点：
  1. **停車確認を位置ベース速度と融合**（バグA・最重大）。`shouldConfirmStopped` は従来 `sAcc<2.0` を
     **必須ゲート**にしていたが、iOS の Doppler `sAcc` は停車直後に赤(≈3.7m/s)へ張り付くことがあり
     （01:09台ログ：speed=0.00で23秒・hAcc=2.5m良好なのに sAcc=3.74 のため `conf_stopped=0` 継続→
     直後の113km/h発進をまるごと取りこぼし）。新実装は2経路の論理和：**A)** sAcc良好なら従来通りDoppler速度で即確認、
     **B)** sAcc赤でも **生GPS速度≈0 かつ 位置ベース速度 `positionSpeedKmh`≈0**（座標が動いていない）なら停車確認。
     `positionSpeedKmh` は sAcc と独立した真値（既存の偽Doppler検出で算出済み）。赤時の偽高速グリッチは生速度が
     高く出るため B を通らず誤確認しない。位置速度未確定(`positionSpeedValid=false`)の間は B を使わない。
  2. **偽発進フェイルセーフをガードの外へ**（防御的改善）。`case .running` 冒頭の `guard !dopplerLooksFake else { break }`
     が偽発進アボート(`shouldAbortFalseLaunch`)も囲っていた。アボート判定は時間とピーク（蓄積済み状態）だけに
     依存し現在サンプルの妥当性に依存しないため、ガードの**外**で毎サンプル評価するのが正しい
     （停車中にDopplerが偽高速>30km/hを出し続ける状況での破棄遅延を防ぐ）。
     **⚠️ 訂正**: 当初これを「01:04台ログの破棄18秒」の原因と診断したが誤り。低速クリープ(12-16km/h<30)は
     `dopplerLooksFake=false` なのでこのガードの影響を受けない。**18秒の真因はGPS配信遅延**（fix時刻は綺麗な1Hzだが
     配信が18秒まとめて遅延し、適格サンプルが届いた瞬間にアボートは正しく発火していた。下記と§14参照）。
     本変更は実害を直したわけではない防御的整理として残す。
  3. **ARMEDラッチ遷移を純粋関数へ集約**。`confirmedStopped`/`readySince`/`poorGPSGraceSince` の遷移は
     handleGPS 内の複数ブランチに散在し（実走のたびに例外を継ぎ足してv0.1.28→58→64→66と変遷）バグの温床だった。
     `TimerEngine.updateArmedLaunch(_:...)`（nonisolated・inout）に一元化し `TimerEngineLaunchTests` で
     停車確認/赤発進/トリガー/ロールング防止/猶予満了を網羅テスト。ラッチ自体はストレージとして保持
     （ContentView の録画/READY表示が `confirmedStoppedWhileArmed` を参照するため）。
  4. **実機未検証**（2026-06-22 時点）。次回実走で 01:09 のような「sAcc赤停車→発進」が拾えるか、緑の通常発進
     （01:05/01:07）の精度に回帰が無いかを debug.csv/accel で要確認。
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
  フェイルセーフ: GPSが発進を検知した実時刻（`launchDetectedAt`）から
  `launchConfirmSec`(5s) 以内にピークが `launchConfirmKmh`(25km/h) 未満なら
  `abortRunDueToFalseLaunch()` で破棄。実走は5秒で余裕で25km/h超、クリープは届かない。
  **v0.1.66で基準をlookBack後の `startTime` から `launchDetectedAt` へ変更**。旧実装は
  lookBackでt=0を数秒遡るため、GPSトリガー直後の次サンプルで「すでに5秒経過」と誤判定し、
  00:19/00:21台ログの本物の発進を `FALSE_LAUNCH_ABORT` していた。破棄後は車が動き続けるので
  （confirmedStopped が false のまま）再停車まで再トリガーせず、ロールング発進も防ぐ。

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
`TimerEngineSplitTests` がスプリット線形補間・停車確認 Path A・偽発進時刻基準等を検証。
`TimerEngineLaunchTests`（v0.1.67新規）が発進検出の集約ロジック（停車確認 Path A/B・偽発進アボート・
`updateArmedLaunch` の停車/赤発進救済/トリガー/ロールング防止/猶予満了）を検証。計29ケース。
`AccelTimer` スキームの TestAction に含まれる。新規ロジックは可能な限り純粋関数に抽出してテストする方針。

## 12. リリース前 TODO・既知のトレードオフ

- 検証用UI（トライアルリセット/購入画面表示/診断ログZIP共有）は `#if DEBUG` 済みなので
  リリースビルドでは自動的に除外される（手動削除は不要）。
- 減速リセット無効による水増しタイムは現状許容（必要なら保存時の事後判定を相談）。
- `VIDEO_SAVE_TIMEOUT` は**バグではなく設計通りの保険経路**。FINISHED 時に「10秒以内に停車しなければ
  保存する」タイマー(`handleStateChange` の `.finished`)が起動し、100km/h到達後にドライバーが10秒以内に
  停車しないと発火→そのまま保存する（直後に `VIDEO_SAVED`）。0-100直後に急停車しないのが普通なので毎回出て
  正常。名前が紛らわしいだけで監視不要（2026-06-22 検証走行で確認）。
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
event）を Downloads の日付フォルダに格納して共有する。v0.1.65以降、ARMED中のdebug.csv
GPS行は event 欄に `UI=READY` / `UI=DRIVING` / `UI=CONFIRMING_STOP` / `UI=GPS_CHECK`
を出す（既存CSVヘッダを壊さないため列追加ではなくevent欄へ追記）。Python で解析し、速度
プロファイル・スプリット・GPS精度・誤発進などを検証してから修正するのが定石。

- **2つのCSVの wall_time は意味が違う（解析時の必須知識）**:
  - `debug.csv` の wall_time ＝ **アプリがそのサンプルを処理した時刻**（`DebugLogger` が `Date()` で記録）。
  - `logs/accel_*.csv` の wall_time ＝ **GPSの fix時刻**（`CLLocation.timestamp`。`MeasurementLogger` が引数で受け取る）。
  - 両者を突き合わせると **GPS配信遅延（バッチ/バースト配信）** が検出できる。fix時刻が綺麗な1Hzなのに
    debug.csv の処理時刻が1点に固まっていれば、iOSがその間GPSを溜め込み一括配信したということ。
- **GPS配信遅延（18秒バースト・2026-06-22 01:04ログで観測）**: 低速クリープ中、GPS更新が約18秒配信されず、
  fix時刻01:04:09〜21の約12サンプルが処理時刻01:04:21に一括到着した。`pausesLocationUpdatesAutomatically=false`・
  `BestForNavigation`・`distanceFilter=None` は設定済みでも起きる（iOS/環境依存）。**影響は限定的**：クリーンな
  0-100発進(01:05/01:07)では配信はリアルタイム1Hzで、遅延は低速クリープ局面に出やすい。RUNNING中の表示は
  CoreMotion 100Hz補間が継ぎ、偽発進アボートは適格サンプル到着時に発火する。**RUNNING中にGPSが数秒途切れたら
  debug.csv の処理時刻が固まる**ことを念頭に解析する（速度プロファイルは accel_*.csv の fix時刻を正とする）。
- **debug.csv の処理時刻クラスタリングはバグではなく上記遅延の可視化**。直さず診断材料として使う。

## 15. 今後のリファクタ計画（計測コードの分解・2026-06-22 合意）

**現状の評価（計測値）**: `TimerEngine.swift` は約1300行・単一 `@MainActor` クラス・`var` 72個・`static let` 26個。
`handleGPS` は単一281行。表示速度が `fusedSpeedKmh`/`displaySpeedKmh`/`gpsDisplayKmh`/`motionDisplayKmh`/
`armedLaunchKmh`/`finishSeg*` の5〜6系統に分散。1クラスで GPS処理・Kalman融合・lookback・状態機械・スプリット
補間・多段表示平滑化・FINISH補間・3種のabort・音声・触覚・永続化・履歴トリム・ログ＝約13責務を抱える God Object。

**判断**: フルリライトは不要（精度が hard-won・既存の純粋関数8個＋テストという良い核がある・回帰リスク大）。
代わりに**振る舞い不変の責務分解**を、既存の純粋関数の継ぎ目を使って段階的に行う。複雑さの多くは本質的
（GPS不安定・センサー融合は本質的に状態を持つ）で消せない。偶発的複雑さ＝全部1クラス、を解く。

**順序（重要）**: v0.1.67〜0.1.70 は実機未検証。**まず実走でv0.1.67（発進検出の根本修正）の効果と回帰を確認してから**
分解に着手する（未検証変更の上に大きなリファクタを積むと切り分け不能になるため）。

**進捗（2026-06-22 実機検証後）**: v0.1.70を実走(0622_134836)で検証。計測coreは良好（クリーン完走多数・
赤sAcc停車→42km/h発進の救済が成功）。表示層の不整合を1件確認（停車確認済みなのにUI=GPS確認中／走行中）し、
**v0.1.71で表示STATEを `TimerEngine.armedPhase` に一本化して根治**（UI/診断ログ/速度表示が単一の真実を参照。
confirmedStopped・生GPS速度・GPS可用性・赤猶予から導出。ContentViewのgpsIsRed優先ゲートとArmedDisplay enumを撤去）。
**残り＝下記①の「速度変数の構造抽出」**（armedPhaseは表示STATEの一本化まで。fusedSpeedKmh等5変数のクラス分離は未着手）。

**分解ターゲット（優先順・各段はビルド/テストで保護）**:
1. **DisplaySmoother**（最優先・最も絡まる）: 表示5変数＋多段平滑化（GPS EMA→motion外挿→GPS再アンカー）＋
   FINISH区間補間(`finishSeg*`)をここへ。計測精度ロジックと独立なので低リスク高効果。
   ※表示STATE（READY/走行中等の判定）は v0.1.71 で `armedPhase` に一本化済み。残るは速度値そのものの平滑化系統。
2. **SpeedFusion**: GPS EMA＋Kalman＋位置検算(`positionSpeedKmh`)＋`dopplerLooksFake`。
3. **LaunchDetector**: `updateArmedLaunch`（v0.1.67で抽出済）の状態保持ごと移設を完了。
4. **LookbackAnchor**: モーションリングバッファ＋t=0 アンカリング(`lookBackStartTime`)。
5. `TimerEngine` を「状態機械＋オーケストレーション」に痩せさせ、音声/触覚/永続化(`persistResult`/`trimHistory`)は分離。
