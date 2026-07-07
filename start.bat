@echo off
chcp 65001 >nul
cd /d "%~dp0"

where node >nul 2>nul
if not errorlevel 1 goto :node_ok

echo 找不到 Node.js。
where winget >nul 2>nul
if errorlevel 1 (
  echo 找不到 winget,請自行至 https://nodejs.org/ 下載安裝 Node.js 後再執行 start.bat。
  pause
  exit /b 1
)

choice /C YN /M "要現在自動安裝 Node.js LTS 嗎"
if errorlevel 2 (
  echo 已取消,請自行安裝 Node.js 後再執行 start.bat。
  exit /b 1
)

echo 正在安裝 Node.js LTS,請稍候...
winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
if errorlevel 1 (
  echo 安裝失敗,請自行至 https://nodejs.org/ 下載安裝。
  pause
  exit /b 1
)
echo Node.js 安裝完成。請關閉這個視窗、重新開一個新的命令視窗再雙擊一次 start.bat(需要重新整理 PATH)。
pause
exit /b 0

:node_ok
if not exist "%~dp0floating-widget-lib\Microsoft.Web.WebView2.Core.dll" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ensure-webview2.ps1"
)
start /min cmd /c "timeout /t 1 >nul & start http://127.0.0.1:3789"
node server.js
