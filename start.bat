@echo off
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo 找不到 Node.js,請先安裝:https://nodejs.org/
  pause
  exit /b 1
)
if not exist "%~dp0floating-widget-lib\Microsoft.Web.WebView2.Core.dll" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ensure-webview2.ps1"
)
start /min cmd /c "timeout /t 1 >nul & start http://127.0.0.1:3789"
node server.js
