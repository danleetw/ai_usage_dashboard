#!/bin/bash
# macOS 專用:Finder 裡可直接雙擊執行(檔名 .command 是 macOS 慣例)。
# 首次雙擊可能被 Gatekeeper 擋下(「無法打開,因為來自未識別的開發者」),
# 需在 Finder 對此檔案按右鍵 → 打開,或執行:xattr -d com.apple.quarantine start.command
cd "$(dirname "$0")" || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo "找不到 Node.js。"
  if command -v brew >/dev/null 2>&1; then
    read -r -p "要現在自動安裝 Node.js(brew install node)嗎? (y/N) " answer
    case "$answer" in
      [Yy]*)
        echo "正在安裝 Node.js..."
        if brew install node; then
          echo "Node.js 安裝完成,請重新雙擊一次 start.command。"
        else
          echo "安裝失敗,請自行至 https://nodejs.org/ 下載安裝。"
        fi
        read -r -p "按 Enter 結束..." _
        exit 0
        ;;
    esac
  else
    echo "找不到 Homebrew,無法自動安裝。"
  fi
  echo "請先安裝 Node.js:https://nodejs.org/"
  read -r -p "按 Enter 結束..." _
  exit 1
fi

node server.js &
SERVER_PID=$!
sleep 1
open http://127.0.0.1:3789
wait "$SERVER_PID"
