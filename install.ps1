#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Restore this pi setup onto a Windows machine.

.DESCRIPTION
    Installs pi + the global CLI tools it depends on, then mirrors
    ./agent/ over the pi agent directory (~/.pi/agent by default) and
    reinstalls npm packages from the lockfiles.

    Re-running is safe: existing files are overwritten, state directories
    (sessions, cache, credentials) are left untouched.

.PARAMETER Force
    Also copy dotfiles (.gitignore) that would normally be skipped.

.EXAMPLE
    ./install.ps1
    ./install.ps1 -AgentDir 'D:\pi\agent'
#>
[CmdletBinding()]
param(
    [string]$AgentDir = (Join-Path $HOME '.pi\agent')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$src      = Join-Path $repoRoot 'agent'

Write-Host "`n==> pi-setup restore" -ForegroundColor Cyan
Write-Host "    repo:     $repoRoot"
Write-Host "    agentDir: $AgentDir`n"

# ---------------------------------------------------------------- 1. pi
if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
    Write-Host "[1/4] installing pi + global tools via bun..." -ForegroundColor Yellow
    bun install -g @earendil-works/pi-coding-agent agent-browser command-code
} else {
    Write-Host "[1/4] pi already installed ($((Get-Command pi).Source))" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 2. files
Write-Host "[2/4] syncing config -> agentDir" -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null

$items = @(
    'settings.json', 'subagents.json', 'pi-cc-extensions.json',
    'keybindings.json', 'commandcode-models.json',
    'agents', 'skills', 'extensions', 'npm'
)
foreach ($item in $items) {
    $from = Join-Path $src $item
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $AgentDir $item
    if ((Get-Item $from).PSIsContainer) {
        robocopy $from $to /E /XD node_modules /XF '.*' /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for '$item' (code $LASTEXITCODE)" }
    } else {
        Copy-Item $from $to -Force
    }
    Write-Host "      $item"
}

# ---------------------------------------------------------------- 3. deps
Write-Host "[3/4] installing npm packages" -ForegroundColor Yellow
foreach ($pkgDir in @('npm', 'extensions\visual-tools')) {
    $dir = Join-Path $AgentDir $pkgDir
    if (Test-Path (Join-Path $dir 'package-lock.json')) {
        Push-Location $dir
        try { bun install --frozen-lockfile; Write-Host "      $pkgDir" }
        finally { Pop-Location }
    }
}

# ---------------------------------------------------------------- 4. machine bits
Write-Host "[4/4] writing machine-specific files" -ForegroundColor Yellow

# trust.json: mark the home dir as a trusted project root
$trust = @{ $HOME = $true } | ConvertTo-Json
Set-Content -Path (Join-Path $AgentDir 'trust.json') -Value $trust -Encoding utf8
Write-Host "      trust.json"

# auth.json: only create if absent — never overwrite existing credentials
if (-not (Test-Path (Join-Path $AgentDir 'auth.json'))) {
    Set-Content -Path (Join-Path $AgentDir 'auth.json') -Value '{}' -Encoding utf8
}

Write-Host "`nDone. Next:" -ForegroundColor Green
Write-Host "  1. Start pi and run /login to authenticate your provider."
Write-Host "  2. Optional env vars:"
Write-Host "       DEEPGRAM_API_KEY  -> enables the dictate extension (voice input)"
Write-Host "       DICTATE_REC=1     -> record while holding the hotkey"
Write-Host ""
