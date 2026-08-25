<#
.SYNOPSIS
    Register the agent with Windows Task Scheduler: every 15 minutes across the
    US market session, weekdays.

.DESCRIPTION
    Run from an elevated PowerShell.

    Task Scheduler stores triggers in local time, but the session it needs to
    track is Eastern - and the US and UK/EU change clocks on different dates, so
    the offset between them shifts for a week or more twice a year. Rather than
    pretend a fixed local time tracks the market, the window is padded by an hour
    either side and the agent's own Eastern clock decides what actually runs.
    Ticks outside the session cost nothing: the agent emits NO_TRADE without
    calling the model.

.EXAMPLE
    .\Register-Schedule.ps1 -Symbols NVDA,AAPL
    Registers a dry-run schedule. Add -Execute to place orders.
#>
[CmdletBinding()]
param(
    [string[]] $Symbols = @('NVDA'),
    [switch]   $Execute,
    [switch]   $OnlyWhenLoggedOn,
    [int]      $IntervalMinutes = 15,
    [string]   $TaskName = 'MarketResearchAgent'
)

$ErrorActionPreference = 'Stop'
$Symbols = $Symbols |
    ForEach-Object { $_ -split '[,;\s]+' } |
    Where-Object { $_ } |
    ForEach-Object { $_.Trim().ToUpper() }

$runner = Join-Path $PSScriptRoot 'Run-Once.ps1'
if (-not (Test-Path $runner)) { throw "cannot find $runner" }

# Where 09:30-16:00 Eastern falls in this machine's local time today.
$et  = [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$now = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $et)
$openEt  = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour 9  -Minute 30 -Second 0
$closeEt = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour 16 -Minute 0  -Second 0
$offset  = [System.TimeZoneInfo]::Local.GetUtcOffset($openEt) - $et.GetUtcOffset($openEt)

$openLocal  = $openEt.Add($offset)
$closeLocal = $closeEt.Add($offset)

# One hour of padding absorbs a daylight-saving mismatch in either direction.
$PadHours   = 1
$startLocal = $openLocal.AddHours(-$PadHours)
$duration   = ($closeLocal - $openLocal) + (New-TimeSpan -Hours (2 * $PadHours))

$argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"",
    '-Symbols', ($Symbols -join ',')
)
if ($Execute) { $argList += '-Execute' }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')

$trigger = New-ScheduledTaskTrigger -Weekly `
    -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $startLocal
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At $startLocal `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration $duration).Repetition

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

# By default a registered task runs only while its user is logged on, which is
# not much use for something meant to cover a whole trading session. S4U runs it
# logged on or not, and stores no password.
$register = @{
    TaskName    = $TaskName
    Action      = $action
    Trigger     = $trigger
    Settings    = $settings
    Description = 'Market research agent, one pass per tick'
    Force       = $true
}
$logon = 'interactive (only while you are logged on)'
if (-not $OnlyWhenLoggedOn) {
    try {
        $register.Principal = New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
        $logon = 'S4U (runs whether or not you are logged on, no password stored)'
    } catch {
        Write-Warning "could not set S4U logon, falling back to interactive: $($_.Exception.Message)"
    }
}

Register-ScheduledTask @register | Out-Null

$mode = if ($Execute) { 'EXECUTING - orders will be placed' } else { 'dry run - nothing submitted' }
Write-Host "Registered '$TaskName' ($mode)."
Write-Host "  Symbols:  $($Symbols -join ', ')"
Write-Host "  Logon:    $logon"
Write-Host ("  Fires every {0} min, {1:HH:mm}-{2:HH:mm} local, Mon-Fri." -f `
    $IntervalMinutes, $startLocal, $startLocal.Add($duration))
Write-Host ("  That covers 09:30-16:00 ET (today {0:HH:mm}-{1:HH:mm} local) with {2}h of" -f `
    $openLocal, $closeLocal, $PadHours)
Write-Host "  padding either side, so it still covers the session when the US and"
Write-Host "  your own clocks change on different dates. Ticks outside the session"
Write-Host "  cost nothing - the agent skips the model call when the market is shut."
Write-Host ""
Write-Host "  Test it now:    Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Then check:     Get-Content .\logs\agent-*.log -Tail 20"
Write-Host "  Last result:    (Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult"
Write-Host "  Remove it:      Unregister-ScheduledTask -TaskName $TaskName"
