# Windows Sysadmin Toolkit

[![Lint](https://github.com/karim-ahmed66/windows-sysadmin-toolkit/actions/workflows/lint.yml/badge.svg)](https://github.com/karim-ahmed66/windows-sysadmin-toolkit/actions/workflows/lint.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

PowerShell scripts for the day-to-day work of running a multi-site Windows environment: **Active Directory**, **server health**, **SQL Server backups** and **network connectivity**.

They come from the kind of tasks that repeat every week when you support many branches: onboarding new staff, cleaning up stale accounts, access reviews, morning server checks, backup verification, and finding out which sites are down during an incident.

Every script is self-contained, documented with comment-based help (`Get-Help .\Script.ps1 -Full`), and safe to try: anything that changes state supports `-WhatIf` and `-Confirm`.

> All names, OUs, IP addresses and servers in this repository are generic examples (`contoso.local`, `10.x.x.x`). Nothing here is tied to a specific organization.

## Scripts

| Area | Script | What it does |
|---|---|---|
| Active Directory | [`New-BulkADUser.ps1`](ActiveDirectory/New-BulkADUser.ps1) | Creates users from a CSV: unique usernames, random temporary passwords, change-at-logon, OU placement and group membership. Logs every action. |
| Active Directory | [`Get-StaleADAccount.ps1`](ActiveDirectory/Get-StaleADAccount.ps1) | Reports users/computers inactive for *N* days; can disable them and move them to a quarantine OU. |
| Active Directory | [`Export-ADGroupMembership.ps1`](ActiveDirectory/Export-ADGroupMembership.ps1) | Exports group → member pairs (optionally nested) to CSV for access reviews. |
| Servers | [`Get-ServerHealthReport.ps1`](Servers/Get-ServerHealthReport.ps1) | Uptime, CPU, memory, disk space and stopped automatic services across many servers, as a colour-coded HTML report. |
| SQL Server | [`Invoke-SqlBackupJob.ps1`](SqlServer/Invoke-SqlBackupJob.ps1) | Full / differential / log backups with compression and checksum, `RESTORE VERIFYONLY`, off-server copy and retention cleanup. |
| Network | [`Test-SiteConnectivity.ps1`](Network/Test-SiteConnectivity.ps1) | Pings and TCP-checks a list of sites in parallel and classifies each as Up / Degraded / Down. |

## Requirements

| Script(s) | Needs |
|---|---|
| Active Directory scripts | Windows, RSAT **ActiveDirectory** module, rights on the target OUs |
| `Get-ServerHealthReport.ps1` | WinRM (or DCOM) access to the target servers |
| `Invoke-SqlBackupJob.ps1` | **SqlServer** module v22+ (`Install-Module SqlServer`), `db_backupoperator` or `sysadmin` |
| `Test-SiteConnectivity.ps1` | Nothing extra. Parallel on PowerShell 7+, sequential on 5.1. Also runs on Linux/macOS |

## Quick start

```powershell
git clone https://github.com/karim-ahmed66/windows-sysadmin-toolkit.git
cd windows-sysadmin-toolkit

# Read the built-in help of any script
Get-Help .\ActiveDirectory\New-BulkADUser.ps1 -Full

# Dry run: see which accounts would be created
.\ActiveDirectory\New-BulkADUser.ps1 -CsvPath .\samples\new-users.csv -UpnSuffix contoso.local -WhatIf
```

If script execution is blocked, allow local scripts for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Examples

**Onboard new employees**

```powershell
.\ActiveDirectory\New-BulkADUser.ps1 -CsvPath .\new-hires.csv -UpnSuffix contoso.local -OutputPath D:\IT\Onboarding
```

CSV format (see [`samples/new-users.csv`](samples/new-users.csv)):

```csv
FirstName,LastName,OU,Department,Title,Office,Groups
Sara,Hassan,"OU=Users,OU=Branch-01,DC=contoso,DC=local",Operations,Teller,Branch 01,SG-Branch-Users;SG-VPN-Users
```

**Quarterly stale-account clean-up**

```powershell
# 1. Review
.\ActiveDirectory\Get-StaleADAccount.ps1 -DaysInactive 90 -ReportPath .\stale.csv

# 2. Act (asks for confirmation per account)
.\ActiveDirectory\Get-StaleADAccount.ps1 -DaysInactive 90 -Disable -MoveToOU 'OU=Disabled,DC=contoso,DC=local'
```

**Morning server check**

```powershell
.\Servers\Get-ServerHealthReport.ps1 -ServerListPath .\samples\servers.txt -DiskFreeWarningPercent 20 |
    Where-Object Status -ne 'OK'
```

**Nightly SQL backup (Task Scheduler or SQL Agent)**

```powershell
pwsh -File .\SqlServer\Invoke-SqlBackupJob.ps1 -ServerInstance SQL01 -BackupRoot E:\Backups -CopyTo \\nas01\sql -RetentionDays 14
```

The script exits with code `1` if any database fails, so the scheduler marks the run as failed.

**Which sites are down?**

```powershell
.\Network\Test-SiteConnectivity.ps1 -CsvPath .\samples\sites.csv | Where-Object Status -ne 'Up'
```

```text
Name                       Status   PingLossPct AvgRttMs OpenPorts ClosedPorts
----                       ------   ----------- -------- --------- -----------
Branch 02 - Router         Down             100                    443
Head Office - App Server   Degraded           0        4 443       3389
```

## Design choices

- **Safe by default** – state-changing scripts use `SupportsShouldProcess`, so `-WhatIf` shows exactly what would happen.
- **Objects out, reports on the side** – every script returns PowerShell objects, so results can be filtered, piped or exported, while CSV/HTML reports and log files are written for people.
- **No secrets in code** – no hard-coded credentials; temporary passwords are generated at runtime and exported once for secure hand-over.
- **Linted in CI** – every push runs [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) and a parser check via GitHub Actions.

## Project structure

```text
windows-sysadmin-toolkit/
├── ActiveDirectory/
│   ├── New-BulkADUser.ps1
│   ├── Get-StaleADAccount.ps1
│   └── Export-ADGroupMembership.ps1
├── Servers/
│   └── Get-ServerHealthReport.ps1
├── SqlServer/
│   └── Invoke-SqlBackupJob.ps1
├── Network/
│   └── Test-SiteConnectivity.ps1
├── samples/                  # Example CSV / TXT inputs
├── PSScriptAnalyzerSettings.psd1
└── .github/workflows/lint.yml
```

## Disclaimer

Test in a lab or with `-WhatIf` before running against production, and review each script against your own policies.

## License

[MIT](LICENSE) © Karim Ahmed Hamdy
