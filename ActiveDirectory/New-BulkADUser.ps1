<#
.SYNOPSIS
    Creates Active Directory users in bulk from a CSV file.

.DESCRIPTION
    Reads a CSV file of new employees and creates one AD account per row.
    For every user the script:
      - builds a SamAccountName (first initial + last name) and makes it unique,
      - generates a random temporary password,
      - forces a password change at first logon,
      - places the account in the requested OU and adds it to the listed groups.

    Supports -WhatIf / -Confirm, writes a log file, and exports the created
    accounts (with their temporary passwords) to a CSV so they can be handed
    over securely. Delete that file once the passwords have been delivered.

    Required CSV columns : FirstName, LastName, OU
    Optional CSV columns : Department, Title, Office, Groups (separated by ';')

.PARAMETER CsvPath
    Path to the input CSV file.

.PARAMETER UpnSuffix
    UPN suffix for the new accounts, for example 'contoso.local'.

.PARAMETER OutputPath
    Folder where the log and the credentials export are written.

.PARAMETER PasswordLength
    Length of the generated temporary password (minimum 12).

.EXAMPLE
    .\New-BulkADUser.ps1 -CsvPath .\samples\new-users.csv -UpnSuffix contoso.local -WhatIf

    Shows which accounts would be created without changing anything.

.EXAMPLE
    .\New-BulkADUser.ps1 -CsvPath .\new-hires.csv -UpnSuffix contoso.local -OutputPath D:\Reports

.NOTES
    Requires the ActiveDirectory module (RSAT) and rights to create users in the target OUs.
#>
#Requires -Modules ActiveDirectory
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[\w.-]+\.[a-zA-Z]{2,}$')]
    [string]$UpnSuffix,

    [string]$OutputPath = (Join-Path -Path $PWD -ChildPath 'output'),

    [ValidateRange(12, 64)]
    [int]$PasswordLength = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path -Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}
$logFile = Join-Path -Path $OutputPath -ChildPath "New-BulkADUser-$timestamp.log"
$credentialFile = Join-Path -Path $OutputPath -ChildPath "new-users-$timestamp.csv"

function Write-ToolkitLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line
    switch ($Level) {
        'ERROR' { Write-Warning $Message }
        'WARN' { Write-Warning $Message }
        default { Write-Verbose $Message }
    }
}

function Get-RandomPassword {
    param([int]$Length)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!@#$%*?-_'
    $all = $upper + $lower + $digit + $symbol

    # Guarantee at least one character from each class, then fill the rest.
    $chars = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digit[(Get-Random -Maximum $digit.Length)]
        $symbol[(Get-Random -Maximum $symbol.Length)]
    )
    $chars += 1..($Length - $chars.Count) | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Get-Random -Count $chars.Count)
}

function Get-UniqueSamAccountName {
    param([string]$FirstName, [string]$LastName)
    $clean = { param($s) ($s -replace '[^a-zA-Z]', '').ToLower() }
    $base = ((& $clean $FirstName).Substring(0, 1) + (& $clean $LastName))
    if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }

    $candidate = $base
    $i = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue) {
        $i++
        $candidate = "$base$i"
    }
    $candidate
}

$rows = Import-Csv -Path $CsvPath
$missing = @('FirstName', 'LastName', 'OU') | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missing) {
    throw "CSV is missing required column(s): $($missing -join ', ')"
}

Write-ToolkitLog "Processing $($rows.Count) row(s) from $CsvPath"
$created = [System.Collections.Generic.List[object]]::new()
$failed = 0

foreach ($row in $rows) {
    $displayName = "$($row.FirstName) $($row.LastName)".Trim()
    try {
        if (-not $row.FirstName -or -not $row.LastName -or -not $row.OU) {
            throw 'FirstName, LastName and OU must not be empty.'
        }
        if (-not (Get-ADOrganizationalUnit -Identity $row.OU -ErrorAction SilentlyContinue)) {
            throw "OU not found: $($row.OU)"
        }

        $sam = Get-UniqueSamAccountName -FirstName $row.FirstName -LastName $row.LastName
        $upn = "$sam@$UpnSuffix"

        if ($PSCmdlet.ShouldProcess("$displayName ($sam) in $($row.OU)", 'Create AD user')) {
            $password = Get-RandomPassword -Length $PasswordLength
            $securePassword = [System.Security.SecureString]::new()
            foreach ($char in $password.ToCharArray()) { $securePassword.AppendChar($char) }
            $securePassword.MakeReadOnly()
            $params = @{
                Name                  = $displayName
                DisplayName           = $displayName
                GivenName             = $row.FirstName
                Surname               = $row.LastName
                SamAccountName        = $sam
                UserPrincipalName     = $upn
                Path                  = $row.OU
                AccountPassword       = $securePassword
                ChangePasswordAtLogon = $true
                Enabled               = $true
            }
            foreach ($optional in 'Department', 'Title', 'Office') {
                if ($row.PSObject.Properties.Name -contains $optional -and $row.$optional) {
                    $params[$optional] = $row.$optional
                }
            }
            New-ADUser @params

            if ($row.PSObject.Properties.Name -contains 'Groups' -and $row.Groups) {
                foreach ($group in ($row.Groups -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                    try {
                        Add-ADGroupMember -Identity $group -Members $sam
                    }
                    catch {
                        Write-ToolkitLog "User $sam created, but could not be added to group '$group': $($_.Exception.Message)" -Level WARN
                    }
                }
            }

            $created.Add([pscustomobject]@{
                    DisplayName       = $displayName
                    SamAccountName    = $sam
                    UserPrincipalName = $upn
                    TemporaryPassword = $password
                })
            Write-ToolkitLog "Created $sam ($displayName)"
        }
    }
    catch {
        $failed++
        Write-ToolkitLog "Failed to create '$displayName': $($_.Exception.Message)" -Level ERROR
    }
}

if ($created.Count -gt 0) {
    $created | Export-Csv -Path $credentialFile -NoTypeInformation -Encoding UTF8
    Write-ToolkitLog "Temporary credentials exported to $credentialFile - deliver securely, then delete this file." -Level WARN
}

Write-ToolkitLog "Done. Created: $($created.Count), Failed: $failed"
[pscustomobject]@{
    Created = $created.Count
    Failed  = $failed
    LogFile = $logFile
}
