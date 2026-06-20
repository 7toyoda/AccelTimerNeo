#!/bin/bash
# ビルド番号 (CURRENT_PROJECT_VERSION) を git のコミット数で更新する。
# Config/Version.xcconfig の該当行を書き換えるだけ。App Store / TestFlight 提出前に実行する。
set -euo pipefail
cd "$(dirname "$0")/.."
COUNT=$(git rev-list --count HEAD)
/usr/bin/sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${COUNT}/" Config/Version.xcconfig
echo "CURRENT_PROJECT_VERSION = ${COUNT}"
