#Requires -RunAsAdministrator
# Tailscale セットアップ
#
# 方針: MSI デフォルト (GUI + tailscaled サービス + CLI) をそのまま使う。
# GUI は排除しない (MSI の自然な構成を尊重)。
# ただし Unattended mode を有効化して、GUI に依存せず daemon 単体で接続維持できる状態にする。

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installDir = 'C:\Program Files\Tailscale'
$cliExe = Join-Path $installDir 'tailscale.exe'
$daemonExe = Join-Path $installDir 'tailscaled.exe'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# === 1. Tailscale が未導入なら winget で入れる ===
Write-Step 'Ensure Tailscale installed'
if (-not (Test-Path $daemonExe)) {
    Write-Host '    not found, installing via winget' -ForegroundColor Yellow
    winget install --id tailscale.tailscale --accept-package-agreements --accept-source-agreements --silent
    if (-not (Test-Path $daemonExe)) {
        throw 'Tailscale install failed — tailscaled.exe still missing'
    }
}
Write-Host "    ok $daemonExe" -ForegroundColor Green

# === 2. サービス確認・起動 ===
Write-Step 'Verify Tailscale service'
$svc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
if (-not $svc) {
    throw 'Tailscale service not found — MSI may have failed'
}
if ($svc.Status -ne 'Running') { Start-Service Tailscale }
Write-Host "    Tailscale service: $((Get-Service Tailscale).Status)" -ForegroundColor Green

# === 3. Unattended mode 有効化 ===
# 未ログインだと set コマンドが失敗するので条件付き
Write-Step 'Enable unattended mode (daemon keeps connection without GUI login)'
$loggedIn = $false
try {
    $status = & $cliExe status --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($status -and $status.BackendState -eq 'Running') { $loggedIn = $true }
} catch { }

if ($loggedIn) {
    & $cliExe set --unattended=true 2>&1 | Out-Null
    Write-Host "    ok (unattended=true)" -ForegroundColor Green
} else {
    Write-Host "    (defer) not logged in yet" -ForegroundColor Yellow
    Write-Host "    run: tailscale login" -ForegroundColor Yellow
    Write-Host "    then: tailscale set --unattended=true" -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Tailscale setup complete.' -ForegroundColor Green
