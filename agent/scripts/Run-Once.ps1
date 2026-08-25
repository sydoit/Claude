<#
.SYNOPSIS
    One scheduled pass over the watchlist. The Windows counterpart of run-once.sh.

.DESCRIPTION
    Safe to point Task Scheduler at: it takes a lock so a slow run never overlaps
    the next tick, keeps its own working directory, appends every decision to a
    per-day audit log, and refuses to start without credentials.

.EXAMPLE
    .\Run-Once.ps1 -Symbols NVDA,AAPL
    Dry run - decides and logs, submits nothing.

.EXAMPLE
    .\Run-Once.ps1 -Symbols NVDA,AAPL -Execute
    The same pass, actually placing orders.
#>
[CmdletBinding()]
param(
    [string[]] $Symbols = @('NVDA'),
    [switch]   $Execute,
    [string]   $Python = 'py',
    [string]   $LogDir,
    [int]      $LogKeepDays = 90
)

$ErrorActionPreference = 'Stop'

# Task Scheduler launches this with -File, which passes arguments as literal
# strings rather than parsing them, so -Symbols NVDA,AAPL arrives as a single
# element "NVDA,AAPL". Split it back apart, and tolerate spaces either way.
$Symbols = $Symbols |
    ForEach-Object { $_ -split '[,;\s]+' } |
    Where-Object { $_ } |
    ForEach-Object { $_.Trim().ToUpper() }
if (-not $Symbols) { $Symbols = @('NVDA') }

$AgentDir = Split-Path -Parent $PSScriptRoot
Set-Location $AgentDir

if (-not $LogDir) { $LogDir = Join-Path $AgentDir 'logs' }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# The trading day is Eastern, not whatever this machine is set to.
$et = [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$day = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $et).ToString('yyyy-MM-dd')

$decisions = Join-Path $LogDir "decisions-$day.jsonl"
$journal   = Join-Path $LogDir "journal-$day.jsonl"
$diary     = Join-Path $LogDir "agent-$day.log"

function Write-Diary([string] $Message) {
    "$([DateTime]::UtcNow.ToString('o')) $Message" | Add-Content -Path $diary
}

# The kill-switch latch and .env both live beside this script.
if (-not (Test-Path (Join-Path $AgentDir '.env')) -and -not $env:ANTHROPIC_API_KEY) {
    Write-Diary 'no .env and no ANTHROPIC_API_KEY in the environment'
    Write-Host 'No .env file and no ANTHROPIC_API_KEY. Copy .env.example to .env first.' `
        -ForegroundColor Red
    exit 78
}

# One pass at a time: an exclusive file handle is this platform's flock.
$lockPath = Join-Path $AgentDir '.run.lock'
try {
    $lock = [System.IO.File]::Open(
        $lockPath, 'OpenOrCreate', 'ReadWrite', [System.IO.FileShare]::None)
} catch {
    Write-Diary 'previous run still going, skipping this tick'
    exit 0
}

try {
    $mode = if ($Execute) { 'EXECUTING' } else { 'DRY RUN' }
    Write-Diary "=== pass start [$mode] symbols: $($Symbols -join ' ') ==="

    $status = 0
    foreach ($symbol in $Symbols) {
        Write-Diary "--- $symbol ---"
        $agentArgs = @('-m', 'research_agent', $symbol, '--compact', '--journal', $journal)
        if ($Execute) { $agentArgs += '--execute' }

        # stdout is the decision object; stderr is the reasoning.
        & $Python @agentArgs 2>> $diary | Add-Content -Path $decisions
        if ($LASTEXITCODE -ne 0) {
            Write-Diary "$symbol exited $LASTEXITCODE"
            $status = $LASTEXITCODE   # one bad symbol must not stop the watchlist
        }
    }

    Get-ChildItem -Path $LogDir -Include '*.log', '*.jsonl' -File -Recurse |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogKeepDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    exit $status
}
finally {
    $lock.Close()
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
