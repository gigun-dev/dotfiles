# JetBrains Mono Nerd Font インストール (ユーザースコープ)
# Mac dotfiles の nerd-fonts.jetbrains-mono と揃える
# 管理者権限不要 — %LocalAppData%\Microsoft\Windows\Fonts に配置

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$fontName = 'JetBrainsMono'
$version = 'v3.4.0'  # NerdFonts リリース
$zipUrl = "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/$fontName.zip"

$stagingDir = Join-Path $env:TEMP "nerd-fonts-$fontName"
$zipPath = Join-Path $env:TEMP "$fontName.zip"
$userFontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$regKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ユーザーフォントディレクトリ作成
New-Item -ItemType Directory -Path $userFontDir -Force | Out-Null
New-Item -Path $regKey -Force | Out-Null

Write-Step "Download $fontName $version"
if (-not (Test-Path $zipPath)) {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Write-Host "    ok downloaded" -ForegroundColor Green
} else {
    Write-Host "    (skip) cached" -ForegroundColor DarkGray
}

Write-Step 'Extract'
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
Expand-Archive -Path $zipPath -DestinationPath $stagingDir -Force

Write-Step 'Install .ttf files (regular variants only, skip Windows Compatible / Mono)'
# NerdFontsSymbolsOnly ではなく Nerd Font ラベルだが、
# "NerdFontMono" (モノスペース) は等幅強化版で開発向けに最適
$ttfFiles = Get-ChildItem -Path $stagingDir -Filter '*NerdFontMono*.ttf' -Recurse

if ($ttfFiles.Count -eq 0) {
    # fallback: 全ての .ttf
    $ttfFiles = Get-ChildItem -Path $stagingDir -Filter '*.ttf' -Recurse
}

$installed = 0
foreach ($ttf in $ttfFiles) {
    $dest = Join-Path $userFontDir $ttf.Name
    if (-not (Test-Path $dest)) {
        Copy-Item -Path $ttf.FullName -Destination $dest -Force
        # フォント名 (TTF) を登録
        $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($ttf.Name)) (TrueType)"
        Set-ItemProperty -Path $regKey -Name $regName -Value $dest
        $installed++
    }
}

Write-Host "    ok $installed font file(s) installed" -ForegroundColor Green

Write-Step 'Cleanup staging'
Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Fonts installed to user scope. Log out/in or restart apps to pick up new fonts.' -ForegroundColor Green
Write-Host 'Font family name: "JetBrainsMono Nerd Font Mono"' -ForegroundColor Yellow
