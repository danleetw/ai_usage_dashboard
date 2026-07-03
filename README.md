# AI 使用量儀表板

[English](README.en.md) | 繁體中文

本機執行的 AI 用量儀表板:一橫列一個 AI 提供商,以電玩血條顯示目前使用率、下次重生倒數、
Context 使用率、每週/每月使用率。支援 Claude / Codex / MiniMax 自動同步。

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
