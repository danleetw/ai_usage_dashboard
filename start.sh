#!/bin/bash
# Linux/macOS 終端機啟動腳本:雙擊啟動請改用 start.command(macOS)
cd "$(dirname "$0")" || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo "找不到 Node.js。"
  if command -v apt-get >/dev/null 2>&1; then
    read -r -p "要現在自動安裝 Node.js(sudo apt-get install nodejs npm)嗎? (y/N) " answer
    case "$answer" in
      [Yy]*)
        echo "正在安裝 Node.js,可能需要輸入密碼..."
        if sudo apt-get update && sudo apt-get install -y nodejs npm; then
          echo "Node.js 安裝完成,請重新執行一次 start.sh。"
        else
          echo "安裝失敗,請自行至 https://nodejs.org/ 下載安裝。"
        fi
        read -r -p "按 Enter 結束..." _
        exit 0
        ;;
    esac
  else
    echo "找不到 apt-get,無法自動安裝(此發行版請自行用套件管理員安裝,或參考官網)。"
  fi
  echo "請先安裝 Node.js:https://nodejs.org/"
  read -r -p "按 Enter 結束..." _
  exit 1
fi

node server.js &
SERVER_PID=$!
sleep 1

if command -v xdg-open >/dev/null 2>&1; then
  xdg-open http://127.0.0.1:3789 >/dev/null 2>&1 &
elif command -v open >/dev/null 2>&1; then
  open http://127.0.0.1:3789
else
  echo "請手動開啟瀏覽器:http://127.0.0.1:3789"
fi

wait "$SERVER_PID"
