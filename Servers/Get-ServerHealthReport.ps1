<#
.SYNOPSIS
    Collects health information from Windows servers and produces an HTML report.

.DESCRIPTION
    Connects to each server over CIM (WinRM, falling back to DCOM) and collects:
      - reachability and uptime,
      - CPU load and memory usage,
      - free space on every fixed disk,
      - automatic services that are not running.

    Values are compared against warning thresholds and the result is written
    as a colour-coded HTML report plus the raw objects on the pipeline, so the
    script can also feed a scheduled task or another tool.

.PARAMETER ComputerName
    One or more server names. Accepts pipeline input.

.PARAMETER ServerListPath
    Text file with one server name per line (lines starting with # are ignored).

.PARAMETER DiskFreeWarningPercent
    Warn when a disk has less free space than this percentage. Default: 15.

.PARAMETER MemoryWarningPercent
    Warn when memory usage is above this percentage. Default: 90.

.PARAMETER CpuWarningPercent
    Warn when CPU load is above this percentage. Default: 90.

.PARAMETER ReportPath
    Path of the HTML report. Default: .\server-health-<date>.html

.PARAMETER Credential
    Optional credential used for the CIM sessions.

.EXAMPLE
    .\Get-ServerHealthReport.ps1 -ServerListPath .\samples\servers.txt

.EXAMPLE
    'DC01','SQL01','WEB01' | .\Get-ServerHealthReport.ps1 -DiskFreeWarningPercent 20 | Where-Object Status -ne 'OK'
#>
[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(ParameterSetName = 'ByName', ValueFromPipeline, Position = 0)]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [Parameter(ParameterSetName = 'ByFile', Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$ServerListPath,

    [ValidateRange(1, 99)][int]$DiskFreeWarningPercent = 15,
    [ValidateRange(1, 100)][int]$MemoryWarningPercent = 90,
    [ValidateRange(1, 100)][int]$CpuWarningPercent = 90,

    [string]$ReportPath = (Join-Path -Path $PWD -ChildPath "server-health-$(Get-Date -Format 'yyyyMMdd-HHmm').html"),

    [pscredential]$Credential
)

begin {
    Set-StrictMode -Version Latest
    $servers = [System.Collections.Generic.List[string]]::new()

    # Services that are set to Automatic but normally stop by design.
    $ignoredServices = @('gupdate', 'MapsBroker', 'RemoteRegistry', 'sppsvc', 'edgeupdate', 'TrustedInstaller', 'wuauserv')
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        foreach ($name in $ComputerName) { $servers.Add($name) }
    }
}

end {
    if ($PSCmdlet.ParameterSetName -eq 'ByFile') {
        Get-Content -Path $ServerListPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object { $servers.Add($_) }
    }

    $results = foreach ($server in ($servers | Sort-Object -Unique)) {
        Write-Verbose "Checking $server"
        $issues = [System.Collections.Generic.List[string]]::new()
        $session = $null

        try {
            $sessionParams = @{ ComputerName = $server; ErrorAction = 'Stop' }
            if ($Credential) { $sessionParams.Credential = $Credential }
            try {
                $session = New-CimSession @sessionParams
            }
            catch {
                $sessionParams.SessionOption = New-CimSessionOption -Protocol Dcom
                $session = New-CimSession @sessionParams
            }

            $os = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem
            $cpu = (Get-CimInstance -CimSession $session -ClassName Win32_Processor |
                    Measure-Object -Property LoadPercentage -Average).Average
            $disks = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter 'DriveType = 3'
            $stoppedServices = Get-CimInstance -CimSession $session -ClassName Win32_Service `
                -Filter "StartMode = 'Auto' AND State <> 'Running'" |
                Where-Object { $_.Name -notin $ignoredServices -and $_.Name -notlike 'GoogleUpdater*' }

            $memoryUsed = [math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 1)
            $uptime = (Get-Date) - $os.LastBootUpTime

            if ($cpu -ge $CpuWarningPercent) { $issues.Add("CPU $cpu%") }
            if ($memoryUsed -ge $MemoryWarningPercent) { $issues.Add("Memory $memoryUsed%") }

            $diskSummary = foreach ($disk in $disks) {
                if (-not $disk.Size) { continue }
                $freePercent = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
                if ($freePercent -lt $DiskFreeWarningPercent) {
                    $issues.Add("Disk $($disk.DeviceID) $freePercent% free")
                }
                '{0} {1:N0} GB free ({2}%)' -f $disk.DeviceID, ($disk.FreeSpace / 1GB), $freePercent
            }

            foreach ($svc in $stoppedServices) { $issues.Add("Service stopped: $($svc.DisplayName)") }

            [pscustomobject]@{
                Server          = $server
                Status          = if ($issues.Count) { 'WARNING' } else { 'OK' }
                OS              = $os.Caption
                UptimeDays      = [math]::Round($uptime.TotalDays, 1)
                CpuPercent      = [math]::Round($cpu, 0)
                MemoryPercent   = $memoryUsed
                Disks           = $diskSummary -join '; '
                StoppedServices = @($stoppedServices).Count
                Issues          = $issues -join '; '
            }
        }
        catch {
            [pscustomobject]@{
                Server          = $server
                Status          = 'UNREACHABLE'
                OS              = $null
                UptimeDays      = $null
                CpuPercent      = $null
                MemoryPercent   = $null
                Disks           = $null
                StoppedServices = $null
                Issues          = $_.Exception.Message
            }
        }
        finally {
            if ($session) { Remove-CimSession -CimSession $session }
        }
    }

    $style = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
h1 { font-size: 20px; margin-bottom: 4px; }
p.meta { color: #666; margin-top: 0; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { border: 1px solid #ddd; padding: 6px 8px; text-align: left; vertical-align: top; }
th { background: #f3f3f3; }
tr.OK td:nth-child(2) { color: #1a7f37; font-weight: 600; }
tr.WARNING td:nth-child(2) { color: #9a6700; font-weight: 600; }
tr.UNREACHABLE td:nth-child(2) { color: #cf222e; font-weight: 600; }
</style>
'@
    $summary = $results | Group-Object Status | ForEach-Object { "$($_.Name): $($_.Count)" }
    $fragment = $results | ConvertTo-Html -Fragment -Property Server, Status, OS, UptimeDays, CpuPercent, MemoryPercent, Disks, StoppedServices, Issues
    # Tag each row with its status so the CSS can colour it.
    $fragment = foreach ($line in $fragment) {
        if ($line -match '^<tr><td>[^<]*</td><td>(OK|WARNING|UNREACHABLE)</td>') {
            $line -replace '^<tr>', "<tr class=`"$($Matches[1])`">"
        }
        else { $line }
    }

    $html = ConvertTo-Html -Head $style -Title 'Server Health Report' -Body @"
<h1>Server Health Report</h1>
<p class="meta">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; $($summary -join ' &middot; ')</p>
$($fragment -join "`n")
"@
    $html | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Verbose "Report written to $ReportPath"

    $results
}
