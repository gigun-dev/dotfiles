#Requires -RunAsAdministrator
# Windows 宣言的セットアップ — `nix run .#switch` 相当
#
# configuration.dsc.yaml を単一の source of truth として
# WinGet Configuration で冪等適用する。
#
# 管理者権限の PowerShell から:
#   cd C:\Users\<user>\ghq\github.com\gigun-dev\dotfiles
#   pwsh -ExecutionPolicy Bypass -File windows\setup.ps1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$configFile = Join-Path $PSScriptRoot 'configuration.dsc.yaml'

if (-not (Test-Path $configFile)) {
    throw "Configuration file not found: $configFile"
}

Write-Host "==> Applying $configFile" -ForegroundColor Cyan
winget configure --file $configFile --accept-configuration-agreements

Write-Host ''
Write-Host 'Windows configuration applied.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next (manual):' -ForegroundColor Yellow
Write-Host '  1. Re-login to apply Explorer/UI changes fully' -ForegroundColor Yellow
Write-Host '  2. Tailscale login:   tailscale login' -ForegroundColor Yellow
Write-Host '                        tailscale set --unattended=true' -ForegroundColor Yellow
Write-Host '  3. Regenerate SSH:    ssh-keygen -t ed25519 -f $HOME\.ssh\id_ed25519' -ForegroundColor Yellow
Write-Host '  4. Set up WSL Ubuntu: wsl --install -d Ubuntu' -ForegroundColor Yellow
Write-Host '  5. In WSL, clone dotfiles and apply home-manager' -ForegroundColor Yellow
