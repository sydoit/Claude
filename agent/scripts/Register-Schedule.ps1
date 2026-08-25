<#
.SYNOPSIS
    Register the agent with Windows Task Scheduler: every 15 minutes through
    the regular session, weekdays.

.DESCRIPTION
    Run from an elevated PowerShell. The trigger is expressed in this machine's
    local time, so it is computed from Eastern rather than assumed - check the
    reported window before trusting it, and re-run this script after a machine
    timezone change.

.EXAMPLE
    .\Register-Schedule.ps1 -Symbols NVDA,AAPL
    Registers a dry-run schedule. Add -Execute to place orders.
#>
[CmdletBinding()]
param(
    [string[]] $Symbols = @('NVDA'),
    [switch]   $Execute,
    [string]   $TaskName = 'MarketResearchAgent'
)

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Run-Once.ps1'
if (-not (Test-Path $runner)) { throw "cannot find $runner" }

# 09:30-16:00 Eastern, expressed in this machine's local time.
$et  = [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$now = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $et)
$openEt  = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour 9  -Minute 30 -Second 0
$closeEt = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour 16 -Minute 0  -Second 0
$offset  = ([System.TimeZoneInfo]::Local.GetUtcOffset($openEt) - $et.GetUtcOffset($openEt))
$openLocal  = $openEt.Add($offset)
$duration   = $closeEt - $openEt

$argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"",
    '-Symbols', ($Symbols -join ',')
)
if ($Execute) { $argList += '-Execute' }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')
$trigger = New-ScheduledTaskTrigger -Weekly `
    -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $openLocal
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At $openLocal `
    -RepetitionInterval (New-TimeSpan -Minutes 15) `
    -RepetitionDuration $duration).Repetition

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Description 'Market research agent, one pass per tick' -Force | Out-Null

$mode = if ($Execute) { 'EXECUTING - orders will be placed' } else { 'dry run - nothing submitted' }
Write-Host "Registered '$TaskName' ($mode)."
Write-Host ("  Session 09:30-16:00 ET is {0:HH:mm}-{1:HH:mm} local on this machine." -f `
    $openLocal, $openLocal.Add($duration))
Write-Host "  Inspect with:   Get-ScheduledTask -TaskName $TaskName"
Write-Host "  Run it now:     Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Remove it:      Unregister-ScheduledTask -TaskName $TaskName"
