# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

iPhone 16 Pro Max 向けの高精度 0–100 km/h 加速タイマー iOS アプリ。  
Draggy に匹敵する精度（±0.05〜0.1 秒）を目標とするネイティブアプリ。

- Bundle ID: `com.acceltimer.app.AccelTimer`
- App Name: `AccelTimer`
- 対象 OS: iOS 17.0+
- 開発環境: Xcode 16+, Swift 6, SwiftUI

## ビルド・実行コマンド

```bash
# CLIビルド（シミュレーター）
xcodebuild -project AccelTimer.xcodeproj \
           -scheme AccelTimer \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
           build

# CLIビルド（実機・要 -allowProvisioningUpdates）
xcodebuild -project AccelTimer.xcodeproj \
           -scheme AccelTimer \
           -destination 'platform=iOS,name=<デバイス名>' \
           -allowProvisioningUpdates \
           build

# テスト実行（テストは AccelTimer スキームの TestAction に含まれる）
xcodebuild -project AccelTimer.xcodeproj \
           -scheme AccelTimer \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
           test

# 単一テストクラス
xcodebuild -project AccelTimer.xcodeproj -scheme AccelTimer \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
           test -only-testing:AccelTimerNeoTests/<TestClassName>

# SwiftLint（導入済みの場合）
swiftlint lint --strict
```

## アーキテクチャ

### 状態機械（計測ステート）

```
IDLE → ARMED → RUNNING → FINISHED
```

- `IDLE`: 待機（`arm()` でセンサー起動し `ARMED` へ）
- `ARMED`: 停車確認 → 発進待機。GPS で一度停車を確認後、発進しきい値（`min(10, max(5, sAcc×2))` km/h）超で `RUNNING` へ自動遷移
- `RUNNING`: 計測中。100 km/h 到達で自動停止 → `FINISHED`。大幅減速（ピークから 15 km/h 超ダウン）を検知すると計測を破棄して `ARMED` へ戻る
- 遷移ロジックは `TimerEngine` (`MeasurementState` enum) に集約

### センサーフュージョン戦略

| センサー | レート | 用途 |
|---------|--------|------|
| CoreLocation (GPS Doppler) | 10 Hz | 速度の絶対基準 |
| CoreMotion CMDeviceMotion (userAcceleration) | 100 Hz | GPS サンプル間の補間 |

- GPS サンプル到着時に加速度積分値をリセット（ドリフト補正）
- 速度しきい値クロス時刻は **線形補間** でミリ秒精度を算出

### 主要コンポーネント

- **`TimerEngine`** (`@Observable`): センサー制御・速度計算・状態遷移の核心ロジック
- **`LocationManager`**: `CLLocationManager` ラッパー、Doppler 速度を配信
- **`MotionManager`**: `CMMotionManager` ラッパー、100 Hz 加速度を配信
- **`MeasurementRecord`** (SwiftData `@Model`): 計測結果の永続化モデル
- **`ContentView` / `MeasurementView`**: メイン計測画面（大型速度・時間表示）
- **`HistoryView`**: 計測履歴一覧（リーダーボード方式で保持、ベストタイムハイライト）

### スプリット記録

`0→40`, `0→60`, `0→80`, `0→100` km/h の 4 ポイントを自動記録。  
各スプリット時刻は線形補間で算出し `MeasurementRecord` に格納。

### データ永続化

SwiftData を使用。`ModelContainer` はアプリ起動時に 1 つだけ生成し、  
`@Environment(\.modelContext)` 経由で各 View に注入。履歴は `TimerEngine.trimHistory` がリーダーボード方式で保持する（日付順 30 件＋ `0→40` / `0→60` / `0→80` / `0→100` 各上位 10 件の和集合。重複を除き実質 30〜70 件）。保持対象外のレコードは紐付く動画・ログファイルごと自動削除。

## 必要な権限（Info.plist）

```
NSLocationWhenInUseUsageDescription
NSLocationAlwaysAndWhenInUseUsageDescription
NSMotionUsageDescription
NSCameraUsageDescription          # 動画録画機能
NSMicrophoneUsageDescription      # 走行音録音
```

- Location / Motion / Orientation 等は pbxproj の `INFOPLIST_KEY_*`（`GENERATE_INFOPLIST_FILE=YES`）で定義され、`Info.plist`（Camera / Microphone）とビルド時にマージされる。
- `UIBackgroundModes` は**使用しない**。バックグラウンド移行時は CoreMotion が停止し精度不足になるため、計測中なら自動中止する設計（`abortRunDueToBackground`）。

## UI 指針

- ダークテーマ固定（`colorScheme: .dark`）
- レーシング系フォント（SF Pro Display / Mono の太字）
- GPS 精度インジケーター: **Doppler 速度精度（`speedAccuracy`, m/s）** で判定。青 `< 0.3`（BEST）/ 緑 `< 1.0`（GOOD）/ 黄 `< 2.0`（FAIR）/ 赤 `≥ 2.0`（POOR）。水平精度（hAcc）が良くても速度精度が悪いケースがあるため速度精度を採用
- 100 km/h 到達付近（80 km/h 超）の平均速度精度が緑未満なら「参考値」バッジを表示（`MeasurementRecord.isReferenceOnly`）

## 配布前提

- 個人利用（Apple Developer Program 未加入）
- 7 日ごとに Xcode から実機へ再ビルド・再インストール
- TestFlight / App Store 配布なし（当面）
