#!/usr/bin/env node
'use strict';
// AI 使用量儀表板 — 本機伺服器
// 職責:1) 提供 index.html  2) /api/usage 讀取本機 CLI 憑證,向官方端點查詢使用量
// 安全:只綁定 127.0.0.1;token 只在本機使用,絕不傳給前端。

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execSync, execFile } = require('child_process');

const PORT = 3789;
const ROOT = __dirname;

// ---------- 錯誤訊息 i18n:回傳 errCode+errParams,翻譯延後到回應序列化階段 ----------
// 這樣快取(upstreamCache)裡存的是語言無關的代碼,不會被某次請求的語言污染下次請求。
const SERR = {
  'zh-Hant': {
    DECRYPT_FAIL: '解密失敗(硬體識別碼變更?)請在 config.json 重新填入 apiKey',
    NO_CLAUDE_CRED: '找不到 Claude 憑證 (~/.claude/.credentials.json)',
    CLAUDE_TOKEN_EXPIRED: 'Claude token 已過期,請執行任一 claude 指令讓它自動刷新',
    CONN_FAIL: '連線 {service} 失敗: {msg}',
    HTTP_ERR: '{service} API 回應 HTTP {status}',
    PARSE_FAIL: '無法解析 {service} API 回應',
    FORMAT_UNEXPECTED: '{service} 回應格式不符預期',
    NO_CODEX_CRED: '找不到 Codex 憑證 (~/.codex/auth.json)',
    CODEX_CONN_FAIL: '連線失敗: {msg}',
    CODEX_HTTP_ERR: 'HTTP {status} ({urlTail})',
    CODEX_PARSE_FAIL: '無法解析回應',
    CODEX_FORMAT_UNEXPECTED: '回應格式不符預期',
    UNKNOWN_ERROR: '未知錯誤',
    MINIMAX_NO_KEY: '尚未設定 API Key:點此列「✎ 編輯」直接輸入(會加密儲存)',
    MINIMAX_STATUS_ERR: 'MiniMax: {msg}',
    MINIMAX_UNKNOWN_FORMAT: '已連上但回應格式未知(原始回應已印在伺服器視窗)',
    KIRO_NOT_LOGGED_IN: '找不到 kiro-cli 執行檔,請確認已安裝並登入',
    KIRO_CLI_FAILED: '呼叫 kiro-cli 失敗: {msg}',
    KIRO_FORMAT_UNEXPECTED: 'kiro-cli /usage 回應格式不符預期',
    ANTIGRAVITY_NOT_RUNNING: '未偵測到執行中的 Antigravity CLI(agy);請在終端機執行 agy 並保持該視窗開啟',
    ANTIGRAVITY_PROBE_FAILED: '偵測到 agy CLI 執行中,但查詢用量失敗或回應格式不符預期',
    STALE_BACKOFF: '退避中(避免觸發限流),沿用舊資料',
    UNEXPECTED_EXCEPTION: '發生非預期錯誤: {msg}',
  },
  en: {
    DECRYPT_FAIL: 'Decryption failed (hardware ID changed?) — please re-enter apiKey in config.json',
    NO_CLAUDE_CRED: 'Claude credentials not found (~/.claude/.credentials.json)',
    CLAUDE_TOKEN_EXPIRED: 'Claude token has expired — run any `claude` command to let it refresh automatically',
    CONN_FAIL: 'Failed to connect to {service}: {msg}',
    HTTP_ERR: '{service} API responded with HTTP {status}',
    PARSE_FAIL: 'Failed to parse {service} API response',
    FORMAT_UNEXPECTED: '{service} response format did not match expectations',
    NO_CODEX_CRED: 'Codex credentials not found (~/.codex/auth.json)',
    CODEX_CONN_FAIL: 'Connection failed: {msg}',
    CODEX_HTTP_ERR: 'HTTP {status} ({urlTail})',
    CODEX_PARSE_FAIL: 'Failed to parse response',
    CODEX_FORMAT_UNEXPECTED: 'Response format did not match expectations',
    UNKNOWN_ERROR: 'Unknown error',
    MINIMAX_NO_KEY: 'API Key not set yet — click "✎ Edit" on this row to enter it (it will be encrypted and stored)',
    MINIMAX_STATUS_ERR: 'MiniMax: {msg}',
    MINIMAX_UNKNOWN_FORMAT: 'Connected, but the response format is unknown (raw response printed to the server console)',
    KIRO_NOT_LOGGED_IN: 'kiro-cli executable not found — please make sure it is installed and logged in',
    KIRO_CLI_FAILED: 'Failed to run kiro-cli: {msg}',
    KIRO_FORMAT_UNEXPECTED: 'kiro-cli /usage response did not match expectations',
    ANTIGRAVITY_NOT_RUNNING: 'No running Antigravity CLI (agy) detected — run `agy` in a terminal and keep it open',
    ANTIGRAVITY_PROBE_FAILED: 'agy CLI is running, but fetching usage failed or the response did not match expectations',
    STALE_BACKOFF: 'Backing off to avoid rate limits — using cached data',
    UNEXPECTED_EXCEPTION: 'Unexpected error: {msg}',
  },
};
function terr(code, lang, params) {
  const dict = SERR[lang] || SERR['zh-Hant'];
  let str = dict[code] || code;
  if (params) for (const k in params) str = str.split('{' + k + '}').join(params[k]);
  return str;
}
// 把快取物件裡的 errCode/staleErrCode 依語言翻成 error/staleError 字串;回傳新物件,不動到原快取物件
function localizeResult(r, lang) {
  if (!r || typeof r !== 'object') return r;
  const out = { ...r };
  if (out.errCode) out.error = terr(out.errCode, lang, out.errParams);
  if (out.staleErrCode) out.staleError = terr(out.staleErrCode, lang, out.staleErrParams);
  return out;
}

// ---------- 機密加密:AES-256-GCM,金鑰由本機硬體識別碼衍生 ----------
// 金鑰 = SHA-256(硬體識別碼),檔案綁定本機:複製到別台電腦無法解密。
// 依作業系統取得識別碼來源不同(Windows:BIOS 序號+MachineGuid;macOS:IOPlatformUUID;
// Linux:/etc/machine-id)。注意:這防的是「檔案被拷走」,擋不了在本機執行的程式 — 屬於
// 綁定式保護而非絕對保密。
let cachedMachineKey = null;
function machineKey() {
  if (cachedMachineKey) return cachedMachineKey;
  const id = getHardwareId();
  if (!id) throw new Error('無法取得本機硬體識別碼,無法加解密');
  cachedMachineKey = crypto.createHash('sha256').update('aiDash-v1|' + id).digest();
  return cachedMachineKey;
}

function getHardwareId() {
  const plat = os.platform();
  if (plat === 'win32') return getHardwareIdWin();
  if (plat === 'darwin') return getHardwareIdMac();
  return getHardwareIdLinux(); // Linux 及其他 Unix-like
}

function getHardwareIdWin() {
  let bios = '', guid = '';
  try {
    bios = execSync(
      'powershell -NoProfile -Command "(Get-CimInstance Win32_BIOS).SerialNumber"',
      { timeout: 15000 }).toString().trim();
  } catch {}
  try {
    const out = execSync(
      'reg query "HKLM\\SOFTWARE\\Microsoft\\Cryptography" /v MachineGuid',
      { timeout: 15000 }).toString();
    const m = out.match(/MachineGuid\s+REG_SZ\s+(\S+)/);
    if (m) guid = m[1];
  } catch {}
  return (bios || guid) ? (bios + '|' + guid) : '';
}

function getHardwareIdMac() {
  try {
    const out = execSync('ioreg -rd1 -c IOPlatformExpertDevice', { timeout: 15000 }).toString();
    const m = out.match(/"IOPlatformUUID"\s*=\s*"([^"]+)"/);
    if (m) return m[1];
  } catch {}
  return '';
}

function getHardwareIdLinux() {
  for (const p of ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
    try {
      const id = fs.readFileSync(p, 'utf8').trim();
      if (id) return id;
    } catch {}
  }
  return '';
}

const ENC_PREFIX = 'enc:v1:';
function encryptSecret(plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', machineKey(), iv);
  const data = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return ENC_PREFIX + Buffer.concat([iv, c.getAuthTag(), data]).toString('base64');
}
function decryptSecret(sealed) {
  const buf = Buffer.from(sealed.slice(ENC_PREFIX.length), 'base64');
  const d = crypto.createDecipheriv('aes-256-gcm', machineKey(), buf.subarray(0, 12));
  d.setAuthTag(buf.subarray(12, 28));
  return Buffer.concat([d.update(buf.subarray(28)), d.final()]).toString('utf8');
}

// 讀取 MiniMax key:發現純文字就地加密改寫(自我封印),之後只存密文
function getMinimaxKey() {
  if (process.env.MINIMAX_API_KEY) return { key: process.env.MINIMAX_API_KEY };
  const cfgPath = path.join(ROOT, 'config.json');
  const cfg = readJsonSafe(cfgPath);
  if (!cfg || !cfg.minimax) return { key: '' };
  const mm = cfg.minimax;
  if (mm.apiKey && String(mm.apiKey).trim()) {
    const plain = String(mm.apiKey).trim();
    try {
      mm.apiKeyEnc = encryptSecret(plain);
      delete mm.apiKey;
      fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + '\n');
      console.log('[config] minimax.apiKey 已以 AES-256-GCM(硬體綁定金鑰)加密存回 config.json');
    } catch (e) {
      console.log('[config] 加密失敗,暫以明文使用: ' + e.message);
    }
    return { key: plain };
  }
  if (mm.apiKeyEnc && String(mm.apiKeyEnc).startsWith(ENC_PREFIX)) {
    try {
      return { key: decryptSecret(mm.apiKeyEnc) };
    } catch {
      return { key: '', errCode: 'DECRYPT_FAIL' };
    }
  }
  return { key: '' };
}

function readJsonSafe(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}
const num = v => (typeof v === 'number' && isFinite(v)) ? v : null;

// ---------- Claude (Anthropic OAuth usage endpoint,即 claude /usage 背後的 API) ----------
async function fetchClaude() {
  const credPath = path.join(os.homedir(), '.claude', '.credentials.json');
  const cred = readJsonSafe(credPath);
  const oauth = cred && cred.claudeAiOauth;
  if (!oauth || !oauth.accessToken) {
    return { ok: false, errCode: 'NO_CLAUDE_CRED' };
  }
  if (oauth.expiresAt && Date.now() > oauth.expiresAt) {
    return { ok: false, errCode: 'CLAUDE_TOKEN_EXPIRED' };
  }
  let res;
  try {
    res = await fetch('https://api.anthropic.com/api/oauth/usage', {
      headers: {
        'Authorization': 'Bearer ' + oauth.accessToken,
        'anthropic-beta': 'oauth-2025-04-20',
        'Content-Type': 'application/json',
      },
      signal: AbortSignal.timeout(10000),
    });
  } catch (e) {
    return { ok: false, errCode: 'CONN_FAIL', errParams: { service: 'Anthropic', msg: e.message } };
  }
  if (!res.ok) return { ok: false, errCode: 'HTTP_ERR', errParams: { service: 'Anthropic', status: res.status } };
  const data = await res.json().catch(() => null);
  if (!data) return { ok: false, errCode: 'PARSE_FAIL', errParams: { service: 'Anthropic' } };

  const pick = (o, windowMinutes) => (o && typeof o === 'object' && num(o.utilization) != null)
    ? { usedPct: num(o.utilization), resetsAt: o.resets_at || null, windowMinutes }
    : null;
  const session = pick(data.five_hour, 300);
  const longterm = pick(data.seven_day, 10080);
  if (!session && !longterm) return { ok: false, errCode: 'FORMAT_UNEXPECTED', errParams: { service: 'Anthropic' } };

  const extra = [];
  const opus = pick(data.seven_day_opus, 10080);
  if (opus) extra.push({ label: 'Opus 每週', ...opus });
  return { ok: true, session, longterm, longtermLabel: '每週', extra };
}

// ---------- Codex (ChatGPT 後端 rate-limit 端點,best-effort) ----------
function normalizeCodexWindow(w) {
  if (!w || typeof w !== 'object') return null;
  const usedPct = num(w.used_percent ?? w.usedPercent ?? w.utilization);
  if (usedPct == null) return null;
  const winSec = num(w.limit_window_seconds ?? w.window_seconds);
  const windowMinutes = winSec != null ? Math.round(winSec / 60)
    : num(w.window_minutes ?? w.window_duration_mins ?? w.windowMinutes);
  let resetsAt = null;
  const resetUnix = num(w.reset_at ?? w.resets_at);
  if (resetUnix != null && resetUnix > 1e9) {
    resetsAt = new Date(resetUnix * 1000).toISOString();
  } else if (typeof w.resets_at === 'string') {
    resetsAt = w.resets_at;
  } else if (num(w.reset_after_seconds ?? w.resets_in_seconds) != null) {
    resetsAt = new Date(Date.now() + (w.reset_after_seconds ?? w.resets_in_seconds) * 1000).toISOString();
  }
  return { usedPct, resetsAt, windowMinutes };
}

function normalizeCodex(data) {
  const rl = data.rate_limit || data.rate_limits || data.rateLimits || data;
  if (!rl || typeof rl !== 'object') return null;
  const session = normalizeCodexWindow(rl.primary_window || rl.primary || rl.five_hour);
  const longterm = normalizeCodexWindow(rl.secondary_window || rl.secondary || rl.weekly || rl.monthly);
  if (!session && !longterm) return null;
  const mins = longterm && longterm.windowMinutes;
  const longtermLabel = mins ? (mins >= 20000 ? '每月' : '每週') : '每週';
  return { session, longterm, longtermLabel };
}

async function fetchCodex() {
  const authPath = path.join(os.homedir(), '.codex', 'auth.json');
  const auth = readJsonSafe(authPath);
  const tokens = auth && auth.tokens;
  if (!tokens || !tokens.access_token) {
    return { ok: false, errCode: 'NO_CODEX_CRED' };
  }
  const headers = {
    'Authorization': 'Bearer ' + tokens.access_token,
    'Content-Type': 'application/json',
    'originator': 'codex_cli_rs',
    'User-Agent': 'codex_cli_rs',
  };
  if (tokens.account_id) headers['chatgpt-account-id'] = tokens.account_id;

  const urls = [
    'https://chatgpt.com/backend-api/wham/usage',
    'https://chatgpt.com/backend-api/codex/usage',
  ];
  let lastErr = null;
  for (const url of urls) {
    let res;
    try {
      res = await fetch(url, { headers, signal: AbortSignal.timeout(10000) });
    } catch (e) { lastErr = { errCode: 'CODEX_CONN_FAIL', errParams: { msg: e.message } }; continue; }
    if (!res.ok) { lastErr = { errCode: 'CODEX_HTTP_ERR', errParams: { status: res.status, urlTail: url.split('/').pop() } }; continue; }
    const data = await res.json().catch(() => null);
    if (!data) { lastErr = { errCode: 'CODEX_PARSE_FAIL' }; continue; }
    const norm = normalizeCodex(data);
    if (norm) return { ok: true, ...norm };
    lastErr = { errCode: 'CODEX_FORMAT_UNEXPECTED' };
  }
  return { ok: false, ...(lastErr || { errCode: 'UNKNOWN_ERROR' }) };
}

// ---------- MiniMax (Token/Coding Plan remains 端點,需在 config.json 填 API Key) ----------
function normalizeMinimaxWindow(o, defMin) {
  if (!o || typeof o !== 'object') return null;
  let used = num(o.used_percent ?? o.usage_percent ?? o.utilization ?? o.percent);
  if (used == null) {
    const usedAbs = num(o.used ?? o.used_tokens);
    const total = num(o.total ?? o.limit ?? o.quota ?? o.total_tokens);
    if (usedAbs != null && total > 0) used = usedAbs / total * 100;
    else {
      const remain = num(o.remains ?? o.remaining ?? o.left);
      if (remain != null && total > 0) used = (1 - remain / total) * 100;
    }
  }
  if (used == null) return null;
  let resetsAt = null;
  const rRaw = o.reset_at ?? o.reset_time ?? o.next_reset_time ?? o.refresh_time;
  const r = num(rRaw);
  if (r != null && r > 1e9) resetsAt = new Date(r > 1e12 ? r : r * 1000).toISOString();
  else if (typeof rRaw === 'string' && rRaw) resetsAt = rRaw;
  else if (num(o.reset_after_seconds) != null) {
    resetsAt = new Date(Date.now() + o.reset_after_seconds * 1000).toISOString();
  }
  const winSec = num(o.limit_window_seconds ?? o.window_seconds);
  return {
    usedPct: Math.round(used * 10) / 10,
    resetsAt,
    windowMinutes: winSec != null ? Math.round(winSec / 60) : defMin,
  };
}

function normalizeMinimax(data) {
  // 實際格式(2026-07 實測):model_remains[] 依模型分列,百分比為「剩餘」
  const arr = Array.isArray(data.model_remains) ? data.model_remains : null;
  if (arr && arr.length) {
    const m = arr.find(x => x && x.model_name === 'general') || arr[0];
    let session = null;
    if (num(m.current_interval_remaining_percent) != null) {
      session = {
        usedPct: Math.round((100 - m.current_interval_remaining_percent) * 10) / 10,
        resetsAt: num(m.end_time) ? new Date(m.end_time).toISOString() : null,
        windowMinutes: (num(m.end_time) != null && num(m.start_time) != null)
          ? Math.round((m.end_time - m.start_time) / 60000) : 300,
      };
    }
    let longterm = null;
    if (num(m.current_weekly_remaining_percent) != null) {
      longterm = {
        usedPct: Math.round((100 - m.current_weekly_remaining_percent) * 10) / 10,
        resetsAt: num(m.weekly_end_time) ? new Date(m.weekly_end_time).toISOString() : null,
        windowMinutes: (num(m.weekly_end_time) != null && num(m.weekly_start_time) != null)
          ? Math.round((m.weekly_end_time - m.weekly_start_time) / 60000) : 10080,
      };
    }
    if (session || longterm) return { session, longterm, longtermLabel: '每週' };
    return null;
  }
  // 通用備援:若日後格式再變,盡力猜常見鍵名
  const root = data.data || data.remains || data;
  if (!root || typeof root !== 'object') return null;
  const session = normalizeMinimaxWindow(
    root.five_hour ?? root.hourly ?? root.window_5h ?? root.primary_window, 300);
  const longterm = normalizeMinimaxWindow(
    root.weekly ?? root.seven_day ?? root.week ?? root.secondary_window, 10080);
  if (!session && !longterm) return null;
  return { session, longterm, longtermLabel: '每週' };
}

async function fetchMinimax() {
  const { key: apiKey, errCode: keyErrCode } = getMinimaxKey();
  const keySet = !!apiKey;
  if (keyErrCode) return { ok: false, keySet, errCode: keyErrCode };
  if (!apiKey) {
    return { ok: false, keySet, errCode: 'MINIMAX_NO_KEY' };
  }
  let res;
  try {
    res = await fetch('https://www.minimax.io/v1/token_plan/remains', {
      headers: { 'Authorization': 'Bearer ' + apiKey, 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(10000),
    });
  } catch (e) {
    return { ok: false, keySet, errCode: 'CONN_FAIL', errParams: { service: 'MiniMax', msg: e.message } };
  }
  const data = await res.json().catch(() => null);
  if (!res.ok) return { ok: false, keySet, errCode: 'HTTP_ERR', errParams: { service: 'MiniMax', status: res.status } };
  if (!data) return { ok: false, keySet, errCode: 'PARSE_FAIL', errParams: { service: 'MiniMax' } };
  if (data.base_resp && data.base_resp.status_code) {
    return { ok: false, keySet, errCode: 'MINIMAX_STATUS_ERR', errParams: { msg: data.base_resp.status_msg || 'status ' + data.base_resp.status_code } };
  }
  const norm = normalizeMinimax(data);
  if (norm) return { ok: true, keySet, ...norm };
  console.log('[minimax] 未知回應格式,請將以下內容回報以便修正解析器:');
  console.log(JSON.stringify(data).slice(0, 2000));
  return { ok: false, keySet, errCode: 'MINIMAX_UNKNOWN_FORMAT' };
}

// ---------- 讀取 POST body(上限 64KB) ----------
function readBody(req, limit = 65536) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', c => {
      size += c.length;
      if (size > limit) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// ---------- Kiro(無公開 usage API;借用 kiro-cli 的 `/usage` 指令輸出,仿照 CodexBar 開源專案的做法) ----------
// 2026-07-04:原本想走 `kiro-cli serve`(本機 ACP WebSocket,JSON-RPC over ws://127.0.0.1:8082)這條路,
// 跟 Antigravity 的做法一樣。handshake(initialize → session/new)本身沒問題,但 session/new 之後的
// account/getUsage 需要「反向」由我方(client)實作一個 auth callback(_kiro/auth/getAccessToken)
// 才能繼續 —— 這已經超出「借用本機已登入行程的資料」的範圍,變成要自己實作一段認證代理邏輯。
// 改查 steipete/CodexBar(docs/kiro.md)後發現更簡單的做法:直接呼叫
// `kiro-cli chat --no-interactive "/usage"`,這是一個唯讀的 metadata 查詢(已實測連續呼叫兩次數字
// 完全不變,確認不會消耗真實對話額度),輸出是帶 ANSI 顏色碼的純文字報表,去除 ANSI 碼後用正則解析。
// 注意:`/usage` 前面的斜線在 Git Bash 手動測試時會被 MSYS 路徑轉換搞爛(誤判成 Unix 路徑),但
// server.js 用 execFile 直接傳陣列參數給 CreateProcess,不會經過任何 shell,故不受影響。
const KIRO_TIMEOUT_MS = 20000;
function findKiroCliPath() {
  const candidates = os.platform() === 'win32'
    ? [process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, 'Kiro-Cli', 'kiro-cli.exe') : null]
    : [
        path.join(os.homedir(), '.local', 'bin', 'kiro-cli'),
        '/opt/homebrew/bin/kiro-cli',
        '/usr/local/bin/kiro-cli',
      ];
  return candidates.filter(Boolean).find(p => { try { return fs.existsSync(p); } catch { return false; } }) || null;
}
// 注意:kiro-cli 把 TUI 報表印到 stderr,不是 stdout(實測確認,非常規但就是這樣),故兩者都收集
function execFileAsync(file, args, opts) {
  return new Promise((resolve, reject) => {
    execFile(file, args, opts, (err, stdout, stderr) => {
      if (err && !stdout && !stderr) { reject(err); return; }
      resolve((stdout || '') + '\n' + (stderr || ''));
    });
  });
}
function stripAnsi(s) { return s.replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, ''); }

function normalizeKiroUsage(text) {
  const resetMatch = text.match(/resets on (\d{4}-\d{2}-\d{2})/) || text.match(/resets on (\d{2})\/(\d{2})/);
  const planMatch = text.match(/\|\s*([A-Z][A-Z0-9 ]*)\s*(?:\r?\n|$)/);
  const creditsMatch = text.match(/\(([\d.]+)\s+of\s+([\d.]+)\s+covered in plan\)/i);
  if (!creditsMatch) return null;
  const used = num(parseFloat(creditsMatch[1]));
  const total = num(parseFloat(creditsMatch[2]));
  if (used == null || !total) return null;

  let resetsAt = null;
  if (resetMatch) {
    if (resetMatch[1] && resetMatch[1].includes('-')) {
      resetsAt = new Date(resetMatch[1] + 'T00:00:00').toISOString();
    } else if (resetMatch[2]) {
      const now = new Date();
      let year = now.getFullYear();
      const mm = parseInt(resetMatch[1], 10), dd = parseInt(resetMatch[2], 10);
      let d = new Date(year, mm - 1, dd);
      if (d.getTime() < now.getTime()) d = new Date(year + 1, mm - 1, dd);
      resetsAt = d.toISOString();
    }
  }

  const longterm = {
    usedPct: Math.round((used / total) * 1000) / 10,
    resetsAt,
    windowMinutes: 43200,
  };
  const extra = [];
  const bonusMatch = text.match(/Bonus credits:[^\n]*?([\d.]+)\/([\d.]+)\s+credits used(?:,\s*expires in (\d+)\s*days?)?/i);
  if (bonusMatch) {
    const bUsed = num(parseFloat(bonusMatch[1])), bTotal = num(parseFloat(bonusMatch[2]));
    if (bUsed != null && bTotal) {
      extra.push({
        label: 'Bonus 額度',
        usedPct: Math.round((bUsed / bTotal) * 1000) / 10,
        resetsAt: bonusMatch[3] ? new Date(Date.now() + parseInt(bonusMatch[3], 10) * 86400000).toISOString() : null,
        windowMinutes: null,
      });
    }
  }
  return { session: null, longterm, longtermLabel: '每月', extra, planName: planMatch ? planMatch[1].trim() : null };
}

async function fetchKiro() {
  const exe = findKiroCliPath();
  if (!exe) return { ok: false, errCode: 'KIRO_NOT_LOGGED_IN' };
  let output;
  try {
    output = await execFileAsync(exe, ['chat', '--no-interactive', '/usage'], {
      timeout: KIRO_TIMEOUT_MS, encoding: 'utf8', windowsHide: true,
    });
  } catch (e) {
    return { ok: false, errCode: 'KIRO_CLI_FAILED', errParams: { msg: e.message } };
  }
  const norm = normalizeKiroUsage(stripAnsi(output));
  if (!norm) return { ok: false, errCode: 'KIRO_FORMAT_UNEXPECTED' };
  return { ok: true, ...norm };
}

// ---------- Antigravity(Google agentic CLI「agy」;無公開 usage API,借用 CLI 自己的本機 loopback 服務) ----------
// 2026-07-04 探測過程(細節見 開發計畫.md):agy.exe 執行檔本身是加殼過的封閉二進位、雲端 usage 端點
// (daily-cloudcode-pa.googleapis.com)的認證憑證存在 Windows 認證管理員裡且是不透明編碼,
// 兩條路都撞牆。後來在開源專案 steipete/CodexBar(docs/antigravity.md)裡找到:agy CLI 執行期間會在
// 127.0.0.1 開一個「自己就有 quota 資料」的 Connect-RPC 本機服務,不需要 CSRF token(這點跟
// Antigravity 桌面 App/IDE 版本不同),已實機驗證此法可行且與 CLI 內 `/model` 畫面數字一致:
//   POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
//   headers: Content-Type: application/json, Connect-Protocol-Version: 1  body: {}
//   回應:{ response: { groups: [ { displayName, buckets: [{ bucketId, window, remainingFraction, resetTime }] } ] } }
// 限制:此服務只在 agy CLI 行程存活時才會開著(關閉終端機視窗就沒了),故偵測不到時只能提示
// 使用者「請先在終端機執行 agy 保持連線」,不會主動幫使用者背著啟動一個 agy 行程(避免意外side effect
// /行程生命週期管理複雜化,超出這個零依賴小工具的範圍)。目前只在 Windows 實機驗證過;macOS/Linux
// 的 ps/lsof 分支沿用 CodexBar 文件裡的位置與指令,未實機測試。
function findAgyListenPorts() {
  try {
    if (os.platform() === 'win32') {
      const tasklistOut = execSync('tasklist /FI "IMAGENAME eq agy.exe" /FO CSV /NH', { encoding: 'utf8', timeout: 3000 });
      const pids = [...tasklistOut.matchAll(/"agy\.exe","(\d+)"/g)].map(m => m[1]);
      if (!pids.length) return [];
      const netstatOut = execSync('netstat -ano -p TCP', { encoding: 'utf8', timeout: 3000 });
      const ports = new Set();
      for (const line of netstatOut.split('\n')) {
        const m = line.match(/^\s*TCP\s+127\.0\.0\.1:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$/i);
        if (m && pids.includes(m[2])) ports.add(m[1]);
      }
      return [...ports];
    }
    // macOS/Linux:未實機驗證,沿用 CodexBar 文件記載的做法
    const psOut = execSync('ps -ax -o pid=,command=', { encoding: 'utf8', timeout: 3000 });
    const pids = psOut.split('\n')
      .filter(l => /(^|[\\/])agy(\s|$)/.test(l.trim()))
      .map(l => l.trim().split(/\s+/)[0]);
    const ports = new Set();
    for (const pid of pids) {
      try {
        const lsofOut = execSync(`lsof -nP -iTCP -sTCP:LISTEN -a -p ${pid}`, { encoding: 'utf8', timeout: 3000 });
        for (const m of lsofOut.matchAll(/:(\d+)\s+\(LISTEN\)/g)) ports.add(m[1]);
      } catch { /* 該 pid 查不到就跳過 */ }
    }
    return [...ports];
  } catch { return []; }
}

// 呼叫本機 agy 的 Connect-RPC 服務;loopback 自簽憑證,只在 127.0.0.1 才允許略過憑證驗證
function postAgyLocalRpc(port, rpcPath, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const body = '{}';
    const req = https.request({
      host: '127.0.0.1', port, path: rpcPath, method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Connect-Protocol-Version': '1',
        'Content-Length': Buffer.byteLength(body),
      },
      rejectUnauthorized: false,
      timeout: timeoutMs,
    }, (res) => {
      let data = '';
      res.on('data', c => { data += c; });
      res.on('end', () => {
        if (res.statusCode !== 200) { reject(new Error('HTTP ' + res.statusCode)); return; }
        resolve(data);
      });
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.write(body);
    req.end();
  });
}

function normalizeAntigravityQuota(json) {
  const groups = json && json.response && Array.isArray(json.response.groups) ? json.response.groups : null;
  if (!groups || !groups.length) return null;
  const pickBucket = (group) => {
    const b = group && Array.isArray(group.buckets) ? group.buckets[0] : null;
    if (!b || num(b.remainingFraction) == null) return null;
    const windowMinutes = b.window === 'weekly' ? 10080 : (b.window === 'daily' ? 1440 : 300);
    return { usedPct: Math.round((1 - b.remainingFraction) * 1000) / 10, resetsAt: b.resetTime || null, windowMinutes };
  };
  const geminiGroup = groups.find(g => /gemini/i.test(g.displayName || ''));
  const otherGroup = groups.find(g => g !== geminiGroup) || null;
  let longterm = pickBucket(geminiGroup);
  const otherBucket = pickBucket(otherGroup);
  const extra = [];
  if (longterm && otherBucket) {
    extra.push({ label: (otherGroup.displayName || 'Claude/GPT') + ' 每週', ...otherBucket });
  } else if (!longterm && otherBucket) {
    longterm = otherBucket;
  }
  if (!longterm) return null;
  return { session: null, longterm, longtermLabel: '每週', extra };
}

async function fetchAntigravity() {
  const ports = findAgyListenPorts();
  if (!ports.length) return { ok: false, errCode: 'ANTIGRAVITY_NOT_RUNNING' };
  let lastErrCode = 'ANTIGRAVITY_PROBE_FAILED';
  for (const port of ports) {
    let raw;
    try {
      raw = await postAgyLocalRpc(port, '/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary');
    } catch { continue; }
    let json;
    try { json = JSON.parse(raw); } catch { continue; }
    const norm = normalizeAntigravityQuota(json);
    if (norm) return { ok: true, ...norm };
  }
  return { ok: false, errCode: lastErrCode };
}

// ---------- Context 使用率:掃描本機 CLI session 記錄(只讀檔尾,成本極低) ----------
const ACTIVE_MS = 30 * 60000; // 30 分鐘內有寫入才算活躍 session
const pad2 = n => String(n).padStart(2, '0');

function tailLines(file, bytes = 262144) {
  const fd = fs.openSync(file, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const len = Math.min(bytes, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    return buf.toString('utf8').split('\n').filter(Boolean);
  } finally { fs.closeSync(fd); }
}

// Claude Code:~/.claude/projects/<專案>/<session>.jsonl,每則訊息帶 token usage
function parseClaudeTail(fp) {
  let lines;
  try { lines = tailLines(fp); } catch { return null; }
  let tokens = null, cwd = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    let j;
    try { j = JSON.parse(lines[i]); } catch { continue; } // 檔尾第一行可能被截斷,跳過
    if (!cwd && typeof j.cwd === 'string') cwd = j.cwd;
    const u = j.message && j.message.usage;
    if (tokens == null && u && num(u.input_tokens) != null) {
      tokens = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
    }
    if (tokens != null && cwd) break;
  }
  if (tokens == null) return null;
  const CTX_WINDOW = 200000;
  const label = cwd ? cwd.split(/[\\/]/).filter(Boolean).pop() : path.basename(fp).slice(0, 8);
  return { label, usedPct: Math.min(100, Math.round(tokens / CTX_WINDOW * 1000) / 10) };
}

function scanClaudeContext() {
  const root = path.join(os.homedir(), '.claude', 'projects');
  let dirs;
  try { dirs = fs.readdirSync(root, { withFileTypes: true }).filter(d => d.isDirectory()); } catch { return []; }
  const now = Date.now();
  const sessions = [];
  for (const d of dirs) {
    const dir = path.join(root, d.name);
    let files;
    try { files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl')); } catch { continue; }
    for (const f of files) {
      const fp = path.join(dir, f);
      let st;
      try { st = fs.statSync(fp); } catch { continue; }
      if (now - st.mtimeMs > ACTIVE_MS) continue; // mtime 預過濾,絕大多數檔案到此為止
      const info = parseClaudeTail(fp);
      if (info) sessions.push({ ...info, mtime: st.mtimeMs, ageMin: Math.round((now - st.mtimeMs) / 60000) });
    }
  }
  sessions.sort((a, b) => b.mtime - a.mtime);
  return sessions.slice(0, 8).map(({ label, usedPct, ageMin }) => ({ label, usedPct, ageMin }));
}

// Codex CLI:~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl,token_count 事件帶累計 usage
function parseCodexTail(fp) {
  let lines;
  try { lines = tailLines(fp); } catch { return null; }
  let usedPct = null, cwd = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    let j;
    try { j = JSON.parse(lines[i]); } catch { continue; }
    const p = j.payload || {};
    if (!cwd && typeof p.cwd === 'string') cwd = p.cwd;
    if (usedPct == null && p.type === 'token_count' && p.info) {
      const win = num(p.info.model_context_window) || 272000;
      const u = p.info.last_token_usage || p.info.total_token_usage || {};
      const tokens = (u.input_tokens || 0) + (u.output_tokens || 0);
      if (tokens > 0) usedPct = Math.min(100, Math.round(tokens / win * 1000) / 10);
    }
    if (usedPct != null && cwd) break;
  }
  if (usedPct == null) return null;
  const label = cwd ? cwd.split(/[\\/]/).filter(Boolean).pop() : path.basename(fp).replace(/\.jsonl$/, '').slice(-8);
  return { label, usedPct };
}

function scanCodexContext() {
  const root = path.join(os.homedir(), '.codex', 'sessions');
  const now = Date.now();
  const sessions = [];
  for (const t of [now, now - 86400000]) { // 今天與昨天(跨午夜邊界)
    const d = new Date(t);
    const dir = path.join(root, String(d.getFullYear()), pad2(d.getMonth() + 1), pad2(d.getDate()));
    let files;
    try { files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl')); } catch { continue; }
    for (const f of files) {
      const fp = path.join(dir, f);
      let st;
      try { st = fs.statSync(fp); } catch { continue; }
      if (now - st.mtimeMs > ACTIVE_MS) continue;
      const info = parseCodexTail(fp);
      if (info) sessions.push({ ...info, mtime: st.mtimeMs, ageMin: Math.round((now - st.mtimeMs) / 60000) });
    }
  }
  sessions.sort((a, b) => b.mtime - a.mtime);
  return sessions.slice(0, 8).map(({ label, usedPct, ageMin }) => ({ label, usedPct, ageMin }));
}

// ---------- 上游快取與退避:降低撞到 Anthropic/Codex 429 限流的機率 ----------
// 成功結果快取 3 分鐘(原 55 秒)、失敗後至少 2 分鐘退避才重試(原本每次前端輪詢
// 都會重打,限流期間反而火上加油)、沿用舊成功資料的時間拉長到 30 分鐘(原 10 分鐘)。
const CACHE_MS = 180000;
const FAIL_BACKOFF_MS = 120000;
const STALE_MS = 1800000;
const upstreamCache = {};
async function cachedFetch(key, fn) {
  const now = Date.now();
  const c = upstreamCache[key];
  if (c) {
    if (c.result.ok && now - c.at < CACHE_MS) return c.result; // 成功快取仍新鮮
    if (c.lastFail && now - c.lastFail < FAIL_BACKOFF_MS) {    // 才失敗過,退避中,先不重試
      return c.result.ok
        ? { ...c.result, stale: true, staleErrCode: 'STALE_BACKOFF' }
        : c.result;
    }
  }
  let r;
  try { r = await fn(); } catch (e) { r = { ok: false, errCode: 'UNEXPECTED_EXCEPTION', errParams: { msg: String(e && e.message || e) } }; }
  if (r.ok) {
    upstreamCache[key] = { at: now, result: r };
    return r;
  }
  if (c && c.result.ok && now - c.at < STALE_MS) {
    upstreamCache[key] = { at: c.at, lastFail: now, result: c.result };
    return { ...c.result, stale: true, staleErrCode: r.errCode, staleErrParams: r.errParams };
  }
  upstreamCache[key] = { at: c ? c.at : now, lastFail: now, result: r };
  return r;
}

// ---------- HTTP 伺服器 ----------
function reqLang(req) {
  const q = (req.url.split('?')[1] || '');
  return new URLSearchParams(q).get('lang') === 'en' ? 'en' : 'zh-Hant';
}
const server = http.createServer(async (req, res) => {
  const url = (req.url || '/').split('?')[0];

  if (url === '/api/usage') {
    const lang = reqLang(req);
    const [claudeRaw, codexRaw, minimaxRaw, kiroRaw, antigravityRaw] = await Promise.all([
      cachedFetch('claude', fetchClaude),
      cachedFetch('codex', fetchCodex),
      cachedFetch('minimax', fetchMinimax),
      cachedFetch('kiro', fetchKiro),
      cachedFetch('antigravity', fetchAntigravity),
    ]);
    // 翻譯結果一律用複本(localizeResult 已 shallow-copy),避免把某次請求的語言寫回共用快取物件
    const claude = localizeResult(claudeRaw, lang);
    const codex = localizeResult(codexRaw, lang);
    const minimax = localizeResult(minimaxRaw, lang);
    const kiro = localizeResult(kiroRaw, lang);
    const antigravity = localizeResult(antigravityRaw, lang);
    // Context 掃描是本機檔案操作,便宜,每次請求即時計算(不論配額查詢成敗)
    try { claude.context = scanClaudeContext(); } catch { claude.context = []; }
    try { codex.context = scanCodexContext(); } catch { codex.context = []; }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ time: new Date().toISOString(), providers: { claude, codex, minimax, kiro, antigravity } }));
    return;
  }

  if (url === '/api/minimax/key' && req.method === 'POST') {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    try {
      const body = JSON.parse(await readBody(req) || '{}');
      const key = String(body.apiKey || '').trim();
      const cfgPath = path.join(ROOT, 'config.json');
      const cfg = readJsonSafe(cfgPath) || {};
      cfg.minimax = cfg.minimax || {};
      delete cfg.minimax.apiKey; // 永不保留明文欄位
      if (!key) {
        delete cfg.minimax.apiKeyEnc;
        fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + '\n');
        res.writeHead(200); res.end(JSON.stringify({ ok: true, cleared: true }));
        return;
      }
      cfg.minimax.apiKeyEnc = encryptSecret(key);
      fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + '\n');
      const testRaw = await fetchMinimax(); // 立即驗證,結果回報前端
      upstreamCache.minimax = { at: Date.now(), result: testRaw }; // 同步快取(存語言無關的原始結果),清除舊 key 的殘留結果
      const test = localizeResult(testRaw, body.lang === 'en' ? 'en' : 'zh-Hant');
      res.writeHead(200); res.end(JSON.stringify({ ok: true, test }));
    } catch (e) {
      res.writeHead(400); res.end(JSON.stringify({ ok: false, error: String(e && e.message || e) }));
    }
    return;
  }

  if (url === '/' || url === '/index.html') {
    try {
      const html = fs.readFileSync(path.join(ROOT, 'index.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(html);
    } catch {
      res.writeHead(500); res.end('index.html not found');
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not Found');
});

if (require.main === module) {
  server.listen(PORT, '127.0.0.1', () => {
    console.log('AI 使用量儀表板已啟動: http://127.0.0.1:' + PORT);
    console.log('按 Ctrl+C 結束');
  });
}

module.exports = { encryptSecret, decryptSecret, getMinimaxKey };
