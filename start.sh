#!/bin/bash
# Linux/macOS 終端機啟動腳本:雙擊啟動請改用 start.command(macOS)
cd "$(dirname "$0")" || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo "找不到 Node.js,請先安裝:https://nodejs.org/"
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
