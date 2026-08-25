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
    [int]      $LogKeepDays = 90,
    # Most model calls one pass may spend. The scan screens the watchlist
    # first, so a longer list costs nothing when nothing on it is actionable.
    [int]      $Budget = 5
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

# Windows would otherwise encode redirected output in the locale codepage,
# and a single curly quote in a broker message would crash the pass.
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

$decisions = Join-Path $LogDir "decisions-$day.jsonl"
$journal   = Join-Path $LogDir "journal-$day.jsonl"
$diary     = Join-Path $LogDir "agent-$day.log"

function Add-RawText([string] $Source, [string] $Target) {
    if (-not (Test-Path $Source)) { return }
    $text = [System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)
    if ($text.Length -eq 0) { return }
    # UTF8Encoding($false) = no byte-order mark. Add-Content on 5.1 would write
    # one, and a BOM at the head of a .jsonl breaks strict parsers.
    [System.IO.File]::AppendAllText($Target, $text, (New-Object System.Text.UTF8Encoding($false)))
}

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
    Write-Diary "=== pass start [$mode] symbols: $($Symbols -join ' ') (budget $Budget) ==="

    # One process for the whole watchlist: the account, positions, orders and
    # clock are fetched once rather than once per symbol.
    $agentArgs = @('-m', 'research_agent.scan') + $Symbols +
        @('--compact', '--budget', $Budget, '--journal', $journal)
    if ($Execute) { $agentArgs += '--execute' }

    # stdout is the decision objects; stderr is the reasoning.
    #
    # These are captured by the operating system rather than by PowerShell.
    # Windows PowerShell 5.1 turns any native stderr write into a terminating
    # NativeCommandError while ErrorActionPreference is Stop, and this agent
    # reports its progress on stderr by design. Redirecting through
    # Start-Process means PowerShell never sees either stream, so the exit code
    # decides success and no version-specific behaviour can intervene.
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        # Quote only what needs it, so a path containing spaces survives.
        $quoted = $agentArgs | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { "$_" }
        }
        $proc = Start-Process -FilePath $Python -ArgumentList $quoted `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $status = $proc.ExitCode

        Add-RawText -Source $tmpOut -Target $decisions
        Add-RawText -Source $tmpErr -Target $diary
    }
    finally {
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
    if ($status -ne 0) { Write-Diary "scan exited $status" }

    Get-ChildItem -Path $LogDir -Include '*.log', '*.jsonl' -File -Recurse |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogKeepDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    exit $status
}
finally {
    $lock.Close()
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
