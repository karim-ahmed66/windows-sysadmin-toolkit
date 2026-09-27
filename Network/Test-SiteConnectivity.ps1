<#
.SYNOPSIS
    Checks network reachability of many sites (branches, offices, servers) in parallel.

.DESCRIPTION
    Reads a CSV of sites and, for each one, tests:
      - ICMP ping and average round-trip time,
      - one or more TCP ports (e.g. 443 for the web app, 3389 for RDP, 1433 for SQL).

    Built for multi-site environments where the first question during an
    incident is "which locations are down?". Results are returned as objects,
    printed as a summary and optionally exported to CSV.

    CSV columns: Name, Address, Ports (optional, separated by ';'), Group (optional)

.PARAMETER CsvPath
    Path to the sites CSV.

.PARAMETER DefaultPorts
    TCP ports to test when a row has no Ports value. Default: 443.

.PARAMETER PingCount
    Number of echo requests per site. Default: 2.

.PARAMETER TimeoutMs
    TCP connect timeout in milliseconds. Default: 1500.

.PARAMETER ThrottleLimit
    Maximum number of sites tested at the same time (PowerShell 7+). Default: 32.

.PARAMETER ReportPath
    Optional CSV export path.

.EXAMPLE
    .\Test-SiteConnectivity.ps1 -CsvPath .\samples\sites.csv | Where-Object Status -ne 'Up'

.EXAMPLE
    .\Test-SiteConnectivity.ps1 -CsvPath .\sites.csv -DefaultPorts 443,3389 -ReportPath .\connectivity.csv

.NOTES
    Runs in parallel on PowerShell 7+; falls back to sequential checks on Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [ValidateRange(1, 65535)]
    [int[]]$DefaultPorts = @(443),

    [ValidateRange(1, 10)]
    [int]$PingCount = 2,

    [ValidateRange(100, 30000)]
    [int]$TimeoutMs = 1500,

    [ValidateRange(1, 256)]
    [int]$ThrottleLimit = 32,

    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sites = Import-Csv -Path $CsvPath
if (-not $sites -or -not ($sites[0].PSObject.Properties.Name -contains 'Address')) {
    throw 'CSV must contain at least the columns Name and Address.'
}

# The check is kept as a script block so it can run in ForEach-Object -Parallel
# (PowerShell 7) or sequentially (Windows PowerShell 5.1).
$testSite = {
    param($Site, [int[]]$DefaultPorts, [int]$PingCount, [int]$TimeoutMs)

    $ports = if ($Site.PSObject.Properties.Name -contains 'Ports' -and $Site.Ports) {
        $Site.Ports -split ';' | ForEach-Object { [int]$_.Trim() }
    }
    else { $DefaultPorts }

    # ICMP
    $ping = [System.Net.NetworkInformation.Ping]::new()
    $replies = foreach ($i in 1..$PingCount) {
        try { $ping.Send($Site.Address, 1000) } catch { $null }
    }
    $ping.Dispose()
    $ok = @($replies | Where-Object { $_ -and $_.Status -eq 'Success' })
    $avgMs = if ($ok.Count) { [math]::Round(($ok | Measure-Object -Property RoundtripTime -Average).Average, 0) } else { $null }

    # TCP ports
    $portResults = foreach ($port in $ports) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $open = $client.ConnectAsync($Site.Address, $port).Wait($TimeoutMs) -and $client.Connected
        }
        catch { $open = $false }
        finally { $client.Dispose() }
        [pscustomobject]@{ Port = $port; Open = [bool]$open }
    }
    $closed = @($portResults | Where-Object { -not $_.Open })

    $status = if ($ok.Count -eq 0 -and $closed.Count -eq @($portResults).Count) { 'Down' }
    elseif ($closed.Count -gt 0 -or $ok.Count -lt $PingCount) { 'Degraded' }
    else { 'Up' }

    [pscustomobject]@{
        Name        = $Site.Name
        Group       = if ($Site.PSObject.Properties.Name -contains 'Group') { $Site.Group } else { $null }
        Address     = $Site.Address
        Status      = $status
        PingLossPct = [math]::Round((1 - ($ok.Count / $PingCount)) * 100, 0)
        AvgRttMs    = $avgMs
        OpenPorts   = ($portResults | Where-Object Open | ForEach-Object Port) -join ','
        ClosedPorts = ($closed | ForEach-Object Port) -join ','
        CheckedAt   = Get-Date
    }
}

$started = Get-Date
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $testSiteText = $testSite.ToString()
    $results = $sites | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $block = [scriptblock]::Create($using:testSiteText)
        & $block $_ $using:DefaultPorts $using:PingCount $using:TimeoutMs
    }
}
else {
    $results = foreach ($site in $sites) {
        & $testSite $site $DefaultPorts $PingCount $TimeoutMs
    }
}

$results = $results | Sort-Object @{ Expression = { @{ Down = 0; Degraded = 1; Up = 2 }[$_.Status] } }, Name

$summary = $results | Group-Object Status | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Information -MessageData ("Checked {0} site(s) in {1:N1}s - {2}" -f @($results).Count, ((Get-Date) - $started).TotalSeconds, ($summary -join ', ')) -InformationAction Continue

if ($ReportPath) {
    $results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
}

$results
