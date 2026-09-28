#!/usr/bin/env bash
# ZP助手 一键出包脚本（仅能在装有 Xcode 的 Mac 上运行）
# 用法: TEAM_ID=你的企业证书TeamID ./build-ipa.sh
set -euo pipefail

cd "$(dirname "$0")"

command -v xcodegen >/dev/null 2>&1 || { echo "缺少 xcodegen，请先执行: brew install xcodegen"; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "缺少 Xcode 命令行工具"; exit 1; }

: "${TEAM_ID:?请先设置环境变量 TEAM_ID，例如: TEAM_ID=ABCD1234XY ./build-ipa.sh}"

# 1) 生成 Xcode 工程（依赖 socket.io-client-swift 会在首次构建时自动拉取）
xcodegen generate

# 2) 写入签名 TeamID
if grep -q "REPLACE_WITH_YOUR_TEAM_ID" ExportOptions-enterprise.plist; then
  sed -i '' "s/REPLACE_WITH_YOUR_TEAM_ID/$TEAM_ID/" ExportOptions-enterprise.plist
fi

# 3) 归档
xcodebuild -project ZPAssistant.xcodeproj \
  -scheme ZPAssistant \
  -configuration Release \
  -archivePath build/ZPAssistant.xcarchive \
  archive | tail -n 5

# 4) 导出企业签名 IPA
xcodebuild -exportArchive \
  -archivePath build/ZPAssistant.xcarchive \
  -exportOptionsPlist ExportOptions-enterprise.plist \
  -exportPath build | tail -n 5

echo ""
echo "完成。IPA 输出位置: ios-app/build/ZPAssistant.ipa"
