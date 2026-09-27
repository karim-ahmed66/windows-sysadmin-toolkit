<#
.SYNOPSIS
    Exports the members of Active Directory groups to CSV for access reviews.

.DESCRIPTION
    Lists the members of every group matching a name filter (or inside an OU),
    optionally expanding nested groups. Each output row is one group/member
    pair, which makes the report easy to filter in Excel during periodic
    access-control reviews.

.PARAMETER GroupFilter
    Wildcard filter applied to the group name, for example 'App-*'. Default: '*'.

.PARAMETER SearchBase
    Optional OU distinguished name to limit the search.

.PARAMETER Recursive
    Expand nested groups so indirect members are included.

.PARAMETER ReportPath
    Path of the CSV report. Default: .\group-membership-<date>.csv

.EXAMPLE
    .\Export-ADGroupMembership.ps1 -GroupFilter 'SG-Finance*' -Recursive

.EXAMPLE
    .\Export-ADGroupMembership.ps1 -SearchBase 'OU=Groups,DC=contoso,DC=local' -ReportPath D:\Reports\groups.csv

.NOTES
    Requires the ActiveDirectory module (RSAT).
#>
#Requires -Modules ActiveDirectory
[CmdletBinding()]
param(
    [string]$GroupFilter = '*',

    [string]$SearchBase,

    [switch]$Recursive,

    [string]$ReportPath = (Join-Path -Path $PWD -ChildPath "group-membership-$(Get-Date -Format 'yyyyMMdd').csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$groupParams = @{
    Filter     = "Name -like '$GroupFilter'"
    Properties = 'Description', 'ManagedBy'
}
if ($SearchBase) { $groupParams.SearchBase = $SearchBase }

$groups = @(Get-ADGroup @groupParams | Sort-Object Name)
Write-Verbose "Found $($groups.Count) group(s)."

$rows = foreach ($group in $groups) {
    $members = @(Get-ADGroupMember -Identity $group -Recursive:$Recursive)
    if ($members.Count -eq 0) {
        [pscustomobject]@{
            Group          = $group.Name
            GroupScope     = $group.GroupScope
            GroupCategory  = $group.GroupCategory
            ManagedBy      = $group.ManagedBy
            MemberName     = '(empty group)'
            MemberSam      = $null
            MemberType     = $null
            MemberEnabled  = $null
        }
        continue
    }

    foreach ($member in $members) {
        $enabled = $null
        if ($member.objectClass -eq 'user') {
            $enabled = (Get-ADUser -Identity $member.distinguishedName -Properties Enabled).Enabled
        }
        elseif ($member.objectClass -eq 'computer') {
            $enabled = (Get-ADComputer -Identity $member.distinguishedName -Properties Enabled).Enabled
        }

        [pscustomobject]@{
            Group         = $group.Name
            GroupScope    = $group.GroupScope
            GroupCategory = $group.GroupCategory
            ManagedBy     = $group.ManagedBy
            MemberName    = $member.name
            MemberSam     = $member.SamAccountName
            MemberType    = $member.objectClass
            MemberEnabled = $enabled
        }
    }
}

$rows | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
Write-Verbose "Report written to $ReportPath"

[pscustomobject]@{
    Groups     = $groups.Count
    Rows       = @($rows).Count
    ReportPath = $ReportPath
}
