# AI 使用量儀表板

[English](README.en.md) | 繁體中文

本機執行的 AI 用量儀表板:一橫列一個 AI 提供商,以電玩血條顯示目前使用率、下次重生倒數、
Context 使用率、每週/每月使用率。支援 Claude / Codex / MiniMax / Antigravity / Kiro 自動同步
(Antigravity 需保持 `agy` CLI 在終端機中執行;Kiro 需安裝 `kiro-cli` 並登入)。

零執行期依賴 —— 前端是單一 `index.html`,伺服器 `server.js` 只用 Node.js 內建模組,
**不需要 `npm install`** 就能執行。伺服器只綁定 `127.0.0.1`,不會對外開放。介面支援
繁體中文 / English 切換,預設依瀏覽器語言自動判斷。

![繁體中文畫面](screenshots/dashboard-zh.png)
![English screenshot](screenshots/dashboard-en.png)

## 快速開始

唯一前提:安裝 [Node.js](https://nodejs.org/)(建議 LTS 版本)。

下載本專案(`git clone` 或直接下載 ZIP 解壓縮),進入資料夾後依作業系統執行:

### Windows

雙擊 `start.bat`,或在終端機執行:

```
start.bat
```

### macOS

在 Finder 對 `start.command` 按右鍵 → 打開(第一次執行會被 Gatekeeper 擋下,
需右鍵開啟一次;或先在終端機執行 `xattr -d com.apple.quarantine start.command` 解除隔離)。

也可以直接在終端機執行:

```bash
./start.command
```

### Linux

在終端機執行:

```bash
./start.sh
```

啟動後會自動開啟瀏覽器連到 `http://127.0.0.1:3789`。若沒有自動跳出,手動開啟該網址即可。

## 機密資料

MiniMax API Key 等機密只在本機使用,以 AES-256-GCM 加密後存於 `config.json`,
加密金鑰由**本機硬體識別碼**衍生(Windows:BIOS 序號 + MachineGuid;macOS:
`IOPlatformUUID`;Linux:`/etc/machine-id`)。這代表 `config.json` 綁定單一機器,
複製到別台電腦無法解密 —— 不需要、也不應該把 `config.json` 上傳或分享。

## 開發 / 測試

只有要跑 Playwright E2E 測試時才需要:

```bash
npm install
npx playwright install chromium
```

## 桌面浮動小工具(僅 Windows,選用)

除了傳統瀏覽器分頁,也可以另外開一個無邊框、逐像素透明、釘選在螢幕右上角的浮動小視窗(只顯示供應商
卡片,拿掉標題/語系切換等,血條與捲軸也是半透明),用 WPF + WebView2 實作。兩種模式共用同一個伺服器,
可以同時開著:

| | 傳統瀏覽器版本 | 浮動小工具 |
|---|---|---|
| 啟動方式 | 雙擊 `start.bat` | 直接雙擊 `floating-widget.bat`(伺服器沒在跑的話會自動幫你啟動) |
| 外觀 | 完整版(標題列、語系切換、新增提供商) | 無邊框、透明背景、只有供應商卡片,血條/捲軸半透明 |
| 預設大小 | 一般瀏覽器視窗 | 載入資料後自動調整成剛好容納一張卡片的高度 |
| 調整大小 | 一般瀏覽器視窗操作 | 拖曳視窗邊緣或四個角落即可(角落沒有視覺標記,但仍可點擊拖曳) |
| 搬移位置 | 一般瀏覽器視窗操作 | 按住卡片或背景的任何空白處直接拖曳(滑鼠移上去會出現抓取游標與頂端 ⠿ 提示;按鈕、輸入框、排序把手除外) |
| 關閉方式 | 關瀏覽器分頁 | **Alt+F4**(無邊框設計,沒有關閉按鈕) |

浮動小工具需要 3 個官方 WebView2 SDK 的 DLL(約 9MB,來自 nuget.org,不隨版控一起發佈)。這一步不用
手動處理:`start.bat` 或任一個 `floating-widget*.bat` 偵測到缺少時,會跳出來問你要不要現在自動下載安裝
(`ensure-webview2.ps1`)。如果那次選了「N」跳過,之後可以自己重新執行同一支腳本:

```powershell
# 在專案根目錄執行
.\ensure-webview2.ps1
```

或是照舊手動下載安裝:

```powershell
# 在專案根目錄執行
Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4022.49/microsoft.web.webview2.1.0.4022.49.nupkg" -OutFile webview2.zip
Expand-Archive webview2.zip -DestinationPath webview2_tmp
New-Item -ItemType Directory -Force floating-widget-lib
Copy-Item webview2_tmp\lib\net462\Microsoft.Web.WebView2.Core.dll, webview2_tmp\lib\net462\Microsoft.Web.WebView2.Wpf.dll, webview2_tmp\runtimes\win-x64\native\WebView2Loader.dll floating-widget-lib\
Remove-Item webview2.zip, webview2_tmp -Recurse
```

### 迷你橫式模式

嫌卡片版還是太大的話,可以加 `-Mini` 開關,改成一行約 20px 高、寬度約螢幕 1/5 的迷你血條,一次只顯示
一個供應商(名稱 + 血條 + 百分比 + 重置倒數)。跟卡片版一樣,直接雙擊 `floating-widget-mini.bat` 就會用
這個模式開啟(預設顯示排序裡的第一個供應商)——**不需要事先手動開 `start.bat`**,偵測到伺服器沒在跑會
自動在背景啟動(輸出寫進 `server.log`),等它就緒後才打開小工具視窗。也可以自己在終端機下參數指定
要看哪一個供應商:

```
floating-widget.bat -Mini -Provider claude
```

`-Provider` 可省略(預設用你排序裡的第一個供應商)。開著迷你視窗時按 **↑/↓** 方向鍵可以切換顯示的
供應商。迷你模式固定大小、不能拖邊緣調整大小;按住那一行的任何地方就能拖曳搬移位置。
