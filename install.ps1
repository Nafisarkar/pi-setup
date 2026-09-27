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
    [string]$AgentDir = (Join-Path $HOME '.pi\agent'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$src      = Join-Path $repoRoot 'agent'

# bun reports progress on stderr, which Windows PowerShell surfaces as
# NativeCommandError and would otherwise fail the whole script. Merge the
# streams, echo them, and gate on bun's real exit code instead.
function Invoke-Bun {
    param([string[]]$BunArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & bun @BunArgs 2>&1 | ForEach-Object { Write-Host "      $_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { throw "bun $($BunArgs -join ' ') failed (exit $code)" }
}

Write-Host "`n==> pi-setup restore" -ForegroundColor Cyan
Write-Host "    repo:     $repoRoot"
Write-Host "    agentDir: $AgentDir`n"

# ---------------------------------------------------------------- 1. global tools
# Checked per-tool: gating the whole set on `pi` leaves the other tools
# missing on any machine that already had pi installed.
$globalTools = [ordered]@{
    'pi'            = '@earendil-works/pi-coding-agent@0.87.1'
    'agent-browser' = 'agent-browser@0.38.1'
    'command-code'  = 'command-code@1.66.0'
}
Write-Host "[1/4] global tools" -ForegroundColor Yellow
foreach ($bin in $globalTools.Keys) {
    if (Get-Command $bin -ErrorAction SilentlyContinue) {
        Write-Host ("      {0,-14} already installed" -f $bin) -ForegroundColor DarkGray
    } else {
        Write-Host ("      {0,-14} installing {1}" -f $bin, $globalTools[$bin]) -ForegroundColor Yellow
        Invoke-Bun @('install', '-g', $globalTools[$bin])
    }
}

# ---------------------------------------------------------------- 2. files
Write-Host "[2/4] syncing config -> agentDir" -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null

$items = @(
    'settings.json', 'subagents.json', 'pi-cc-extensions.json',
    'keybindings.json', 'commandcode-models.json',
    'agents', 'skills', 'extensions', 'npm'
)
$dotfiles = if ($Force) { @() } else { @('/XF', '.*') }
foreach ($item in $items) {
    $from = Join-Path $src $item
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $AgentDir $item
    if ((Get-Item $from).PSIsContainer) {
        robocopy $from $to /E /XD node_modules @dotfiles /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for '$item' (code $LASTEXITCODE)" }
    } else {
        if (-not $Force -and (Split-Path $from -Leaf).StartsWith('.')) { continue }
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
        try { Invoke-Bun @('install', '--frozen-lockfile'); Write-Host "      $pkgDir" }
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
