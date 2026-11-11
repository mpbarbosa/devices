<#
.SYNOPSIS
    Stop the Windows clock from booting three hours fast on a dual-boot host.

.DESCRIPTION
    Linux keeps the RTC in UTC, which is the systemd default. Windows assumes
    the RTC holds local time, so after a Linux session it reads 10:52 from the
    hardware and believes 10:52 is the local hour - the clock comes up showing
    UTC. In Brasilia that is exactly three hours fast.

    This sets RealTimeIsUniversal, which makes Windows agree with Linux that
    the RTC is UTC, and then repairs the time service so the machine can also
    correct itself: w32time ships pointed at time.windows.com alone, with a
    4.5 hour poll interval, and on this host it had never once synchronised
    successfully - its source was the local CMOS clock, which is the very
    thing that is wrong.

    The opposite fix, telling Linux to keep local time with
    `timedatectl set-local-rtc 1`, is deliberately not used: systemd warns
    against it because a local-time RTC has no way to express a DST change.

    Run with -WhatIf to see every change without making one.

.PARAMETER TimeServer
    NTP peers, in w32tm manualpeerlist syntax. Defaults to NTP.br stratum 1
    alongside Microsoft's.

.PARAMETER PollSeconds
    How often to poll NTP. Defaults to 3600; the Windows default is 16384.

.PARAMETER LogPath
    Transcript destination. Defaults to fix-clock-utc.log in the temp folder.

.EXAMPLE
    .\fix-clock-utc.ps1 -WhatIf
    .\fix-clock-utc.ps1

.NOTES
    Needs an elevated shell. A Windows feature update can reset
    RealTimeIsUniversal, so if the clock is ever exactly three hours fast
    again, check that value before suspecting the timezone.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $TimeServer  = 'time.windows.com,0x9 a.st1.ntp.br,0x9 b.st1.ntp.br,0x9',
    [int]    $PollSeconds = 3600,
    [string] $LogPath     = (Join-Path $env:TEMP 'fix-clock-utc.log')
)

$ErrorActionPreference = 'Stop'

$tzKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
$ntpKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'

# Read a registry value that may not exist yet.
function Get-Value($Path, $Name) {
    (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
}

# Report a step honestly, the way the bash half of this suite does with its
# `verb mount mounted` helper: a dry run must say "would set", never "set".
function Report($Would, $Done) {
    if ($WhatIfPreference) {
        Write-Host ('  [dry]  would {0}' -f $Would) -ForegroundColor DarkGray
    } else {
        Write-Host ('  [ok]   {0}' -f $Done) -ForegroundColor Green
    }
}

# Measure the local clock against a peer. Returns seconds, positive when the
# local clock is behind, or $null when the peer cannot be reached.
function Get-NtpOffset($Peer) {
    $out = & w32tm /stripchart /computer:$Peer /dataonly /samples:2 2>&1
    $hit = $out | Select-String -Pattern '([-+]\d+\.\d+)s' | Select-Object -Last 1
    if ($hit) { [double] $hit.Matches[0].Groups[1].Value } else { $null }
}

# Start-Transcript honours ShouldProcess, so under -WhatIf it would be skipped
# and the Stop-Transcript below would then throw. Logging is not the side
# effect the dry run is there to suppress, so opt it out of -WhatIf and only
# stop what actually started.
$transcribing = $false
try {
    Start-Transcript -Path $LogPath -Force -WhatIf:$false | Out-Null
    $transcribing = $true
} catch {
    Write-Warning ('could not write {0}: {1}' -f $LogPath, $_.Exception.Message)
}

try {
    $peer   = ($TimeServer -split ' ')[0] -replace ',.*$', ''
    $before = Get-NtpOffset $peer

    Write-Host 'Before' -ForegroundColor Cyan
    Write-Host ('  local time          : {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ('  timezone            : {0}' -f (Get-TimeZone).Id)
    Write-Host ('  RealTimeIsUniversal : {0}' -f (Get-Value $tzKey 'RealTimeIsUniversal'))
    if ($null -ne $before) {
        Write-Host ('  offset vs {0,-10}: {1:+0.000;-0.000} s' -f $peer, $before)
    } else {
        Write-Warning ('{0} is unreachable; continuing anyway' -f $peer)
    }
    Write-Host ''

    # 1. Windows reads the RTC as UTC, the same as Linux writes it.
    if ((Get-Value $tzKey 'RealTimeIsUniversal') -eq 1) {
        Write-Host '  [skip] RealTimeIsUniversal already 1' -ForegroundColor DarkGray
    } else {
        if ($PSCmdlet.ShouldProcess($tzKey, 'set RealTimeIsUniversal to 1')) {
            New-ItemProperty -Path $tzKey -Name 'RealTimeIsUniversal' `
                -PropertyType DWord -Value 1 -Force | Out-Null
        }
        Report 'set RealTimeIsUniversal = 1' 'RealTimeIsUniversal = 1'
    }

    # 2. Peers that are actually close by, instead of Microsoft's alone.
    if ($PSCmdlet.ShouldProcess('w32time', "use peers $TimeServer")) {
        & w32tm /config /manualpeerlist:"$TimeServer" /syncfromflags:manual /update | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "w32tm /config failed with $LASTEXITCODE" }
    }
    Report ('set peers = {0}' -f $TimeServer) ('peers = {0}' -f $TimeServer)

    # 3. A drift of three hours should not wait 4.5 hours to be noticed.
    if ($PSCmdlet.ShouldProcess($ntpKey, "set SpecialPollInterval to $PollSeconds")) {
        Set-ItemProperty -Path $ntpKey -Name 'SpecialPollInterval' `
            -Value $PollSeconds -Type DWord
    }
    Report ('set poll interval = {0} s' -f $PollSeconds) ('poll interval = {0} s' -f $PollSeconds)

    # 4. Start on boot, and correct the clock now rather than at the next poll.
    if ($PSCmdlet.ShouldProcess('w32time', 'restart and resync')) {
        Set-Service w32time -StartupType Automatic
        Restart-Service w32time
        Start-Sleep -Seconds 3
        & w32tm /resync /force
        if ($LASTEXITCODE -ne 0) { Write-Warning "w32tm /resync reported $LASTEXITCODE" }
    }
    Report 'restart the service and resync' 'service restarted and resynchronised'

    Write-Host ''
    Write-Host 'After' -ForegroundColor Cyan
    Write-Host ('  local time          : {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $after = Get-NtpOffset $peer
    if ($null -ne $after) {
        Write-Host ('  offset vs {0,-10}: {1:+0.000;-0.000} s' -f $peer, $after)
    }
    & w32tm /query /status

    Write-Host ''
    Write-Host 'The real test is the next boot out of Linux.' -ForegroundColor Cyan
} finally {
    if ($transcribing) { Stop-Transcript | Out-Null }
}
