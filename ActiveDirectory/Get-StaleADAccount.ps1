<#
.SYNOPSIS
    Finds user and computer accounts that have not logged on for a given number of days.

.DESCRIPTION
    Uses the replicated LastLogonTimestamp attribute to report stale accounts,
    which is a common audit requirement and a quick security win.

    By default the script only reports. Use -Disable to disable the stale
    accounts and, optionally, -MoveToOU to move them into a quarantine OU.
    Both actions honour -WhatIf / -Confirm.

    Note: LastLogonTimestamp can lag the real last logon by up to ~14 days,
    so keep -DaysInactive comfortably above that (90 is a common value).

.PARAMETER DaysInactive
    Accounts with no logon for this many days are considered stale.

.PARAMETER AccountType
    User, Computer, or Both.

.PARAMETER SearchBase
    Optional distinguished name of the OU to search. Defaults to the whole domain.

.PARAMETER Disable
    Disable the stale accounts after reporting them.

.PARAMETER MoveToOU
    Optional OU to move disabled accounts into. Requires -Disable.

.PARAMETER ReportPath
    Optional path of a CSV report.

.EXAMPLE
    .\Get-StaleADAccount.ps1 -DaysInactive 90 -ReportPath .\stale-accounts.csv

.EXAMPLE
    .\Get-StaleADAccount.ps1 -DaysInactive 120 -AccountType Computer -Disable -MoveToOU 'OU=Disabled,DC=contoso,DC=local' -WhatIf

.NOTES
    Requires the ActiveDirectory module (RSAT).
#>
#Requires -Modules ActiveDirectory
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateRange(15, 3650)]
    [int]$DaysInactive = 90,

    [ValidateSet('User', 'Computer', 'Both')]
    [string]$AccountType = 'Both',

    [string]$SearchBase,

    [switch]$Disable,

    [string]$MoveToOU,

    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($MoveToOU -and -not $Disable) {
    throw '-MoveToOU can only be used together with -Disable.'
}

$cutoff = (Get-Date).AddDays(-$DaysInactive)
$common = @{
    Filter     = "Enabled -eq 'True' -and (LastLogonTimestamp -lt $($cutoff.ToFileTime()) -or LastLogonTimestamp -notlike '*')"
    Properties = 'LastLogonTimestamp', 'WhenCreated', 'Description'
}
if ($SearchBase) { $common.SearchBase = $SearchBase }

$accounts = @()
if ($AccountType -in 'User', 'Both') {
    $accounts += Get-ADUser @common | ForEach-Object { $_ | Add-Member -NotePropertyName Type -NotePropertyValue 'User' -PassThru }
}
if ($AccountType -in 'Computer', 'Both') {
    $accounts += Get-ADComputer @common | ForEach-Object { $_ | Add-Member -NotePropertyName Type -NotePropertyValue 'Computer' -PassThru }
}

# Ignore objects created recently - they may simply not have logged on yet.
$stale = $accounts | Where-Object { $_.WhenCreated -lt $cutoff } | ForEach-Object {
    $lastLogon = if ($_.LastLogonTimestamp) { [datetime]::FromFileTime($_.LastLogonTimestamp) } else { $null }
    [pscustomobject]@{
        Type              = $_.Type
        Name              = $_.Name
        SamAccountName    = $_.SamAccountName
        LastLogon         = $lastLogon
        DaysSinceLogon    = if ($lastLogon) { [int]((Get-Date) - $lastLogon).TotalDays } else { 'Never' }
        WhenCreated       = $_.WhenCreated
        Description       = $_.Description
        DistinguishedName = $_.DistinguishedName
    }
} | Sort-Object Type, Name

Write-Verbose "Found $(@($stale).Count) stale account(s) older than $DaysInactive days."

if ($ReportPath) {
    $stale | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
    Write-Verbose "Report written to $ReportPath"
}

if ($Disable) {
    foreach ($item in $stale) {
        if ($PSCmdlet.ShouldProcess("$($item.Type) $($item.SamAccountName)", 'Disable account')) {
            $note = "Disabled by Get-StaleADAccount on $(Get-Date -Format 'yyyy-MM-dd'): inactive $($item.DaysSinceLogon) days"
            Disable-ADAccount -Identity $item.DistinguishedName
            if ($item.Type -eq 'User') {
                Set-ADUser -Identity $item.DistinguishedName -Description $note
            }
            else {
                Set-ADComputer -Identity $item.DistinguishedName -Description $note
            }
            if ($MoveToOU) {
                Move-ADObject -Identity $item.DistinguishedName -TargetPath $MoveToOU
            }
        }
    }
}

$stale
