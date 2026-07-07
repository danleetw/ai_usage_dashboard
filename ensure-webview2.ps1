# Makes sure the 3 WebView2 SDK DLLs used by the floating desktop widget are present in
# .\floating-widget-lib\. These are the official Microsoft.Web.WebView2 NuGet package files
# (~9MB) -- not shipped with the repo (see .gitignore) since they're binary and easy to fetch
# on demand instead.
#
# No-op if the DLLs are already there. If any are missing, asks the user (Y/N) whether to
# download them now; on "no" or on download failure, just leaves them missing and returns --
# it's the caller's job to decide whether that's fatal (floating-widget.ps1 can't run without
# them; start.bat's plain browser mode doesn't need them at all).
#
# Called from both start.bat (as a one-time convenience while Node is starting up) and
# floating-widget.ps1 (right before it would otherwise fail with "DLLs missing").

$root = $PSScriptRoot
$libDir = Join-Path $root 'floating-widget-lib'
$dlls = @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll')
$missing = $dlls | Where-Object { -not (Test-Path (Join-Path $libDir $_)) }

if ($missing.Count -eq 0) { exit 0 }

Write-Host "The floating widget needs the WebView2 SDK (~9MB, from nuget.org). Missing:" -ForegroundColor Yellow
$missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
$answer = Read-Host "Download and install it now? (Y/N)"
if ($answer -notmatch '^[Yy]') {
  Write-Host "Skipped. Re-run ensure-webview2.ps1 later, or see README for manual install steps." -ForegroundColor Yellow
  exit 0
}

$tmpZip = Join-Path $root 'webview2.zip'
$tmpDir = Join-Path $root 'webview2_tmp'
try {
  Write-Host "Downloading WebView2 SDK..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4022.49/microsoft.web.webview2.1.0.4022.49.nupkg" -OutFile $tmpZip
  Expand-Archive $tmpZip -DestinationPath $tmpDir -Force
  New-Item -ItemType Directory -Force $libDir | Out-Null
  Copy-Item (Join-Path $tmpDir 'lib\net462\Microsoft.Web.WebView2.Core.dll') $libDir -Force
  Copy-Item (Join-Path $tmpDir 'lib\net462\Microsoft.Web.WebView2.Wpf.dll') $libDir -Force
  Copy-Item (Join-Path $tmpDir 'runtimes\win-x64\native\WebView2Loader.dll') $libDir -Force
  Write-Host "WebView2 SDK installed." -ForegroundColor Green
} catch {
  Write-Host "Download/install failed: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "See README for manual install steps." -ForegroundColor Red
} finally {
  Remove-Item $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
