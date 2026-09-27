<#
.SYNOPSIS
    Backs up SQL Server databases to disk, verifies the backups and applies a retention policy.

.DESCRIPTION
    For each selected database on the instance the script:
      1. takes a FULL (or DIFFERENTIAL / LOG) backup with compression and checksum,
      2. runs RESTORE VERIFYONLY against the new file,
      3. deletes backup files older than the retention period,
      4. optionally copies the new backup to a secondary location (e.g. a file share),
    and writes a log plus a summary object for monitoring.

    Uses the official SqlServer PowerShell module (Invoke-Sqlcmd / Backup-SqlDatabase).

.PARAMETER ServerInstance
    SQL Server instance, e.g. 'SQL01' or 'SQL01\INSTANCE'.

.PARAMETER Database
    Databases to back up. Default: all online user databases.

.PARAMETER IncludeSystemDatabases
    Also back up master, model and msdb.

.PARAMETER BackupType
    Full, Differential or Log. Default: Full.

.PARAMETER BackupRoot
    Local or UNC folder that will hold one sub-folder per database.

.PARAMETER RetentionDays
    Backup files older than this are deleted. Default: 14.

.PARAMETER CopyTo
    Optional secondary folder (off-server copy).

.EXAMPLE
    .\Invoke-SqlBackupJob.ps1 -ServerInstance SQL01 -BackupRoot 'E:\Backups' -RetentionDays 7

.EXAMPLE
    .\Invoke-SqlBackupJob.ps1 -ServerInstance SQL01 -Database AppDb -BackupType Log -BackupRoot 'E:\Backups' -CopyTo '\\nas01\sql-backups'

.NOTES
    Requires the SqlServer module:  Install-Module SqlServer
    Run under an account with the db_backupoperator role (or sysadmin) and write access to the folders.
    Schedule it with Task Scheduler or a SQL Agent job (PowerShell step).
#>
#Requires -Modules SqlServer
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ServerInstance,

    [string[]]$Database,

    [switch]$IncludeSystemDatabases,

    [ValidateSet('Full', 'Differential', 'Log')]
    [string]$BackupType = 'Full',

    [Parameter(Mandatory)]
    [string]$BackupRoot,

    [ValidateRange(1, 365)]
    [int]$RetentionDays = 14,

    [string]$CopyTo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path -Path $BackupRoot -ChildPath "backup-log-$(Get-Date -Format 'yyyyMM').log"

function Write-ToolkitLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $ServerInstance, $Message
    Add-Content -Path $logFile -Value $line
    if ($Level -eq 'INFO') { Write-Verbose $Message } else { Write-Warning $Message }
}

if (-not (Test-Path -Path $BackupRoot)) {
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
}

$sqlCommon = @{ ServerInstance = $ServerInstance; TrustServerCertificate = $true }

# Pick databases: online, not snapshots, and (for LOG backups) not in SIMPLE recovery.
$query = @'
SELECT name, recovery_model_desc
FROM sys.databases
WHERE state_desc = 'ONLINE' AND source_database_id IS NULL AND name <> 'tempdb'
'@
$available = Invoke-Sqlcmd @sqlCommon -Query $query
$systemDbs = 'master', 'model', 'msdb'

$targets = $available | Where-Object {
    ($IncludeSystemDatabases -or $_.name -notin $systemDbs) -and
    (-not $Database -or $_.name -in $Database)
}
if ($BackupType -eq 'Log') {
    $skipped = $targets | Where-Object recovery_model_desc -eq 'SIMPLE'
    foreach ($db in $skipped) { Write-ToolkitLog "Skipping LOG backup of $($db.name): SIMPLE recovery model." -Level WARN }
    $targets = $targets | Where-Object recovery_model_desc -ne 'SIMPLE'
}
if ($Database) {
    $notFound = $Database | Where-Object { $_ -notin $available.name }
    foreach ($name in $notFound) { Write-ToolkitLog "Database not found or not online: $name" -Level WARN }
}

$extension = @{ Full = 'bak'; Differential = 'dif'; Log = 'trn' }[$BackupType]
$actionMap = @{ Full = 'Database'; Differential = 'Database'; Log = 'Log' }

$results = foreach ($db in $targets) {
    $dbName = $db.name
    $folder = Join-Path -Path $BackupRoot -ChildPath $dbName
    $file = Join-Path -Path $folder -ChildPath "$($dbName)_$($BackupType)_$timestamp.$extension"
    $started = Get-Date

    try {
        if (-not $PSCmdlet.ShouldProcess("$ServerInstance/$dbName", "$BackupType backup to $file")) { continue }

        if (-not (Test-Path -Path $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }

        $backupParams = @{
            ServerInstance    = $ServerInstance
            Database          = $dbName
            BackupFile        = $file
            BackupAction      = $actionMap[$BackupType]
            CompressionOption = 'On'
            Checksum          = $true
        }
        if ($BackupType -eq 'Differential') { $backupParams.Incremental = $true }
        Backup-SqlDatabase @backupParams

        # Verify the backup can be read and its checksums are valid.
        $safeFile = $file.Replace("'", "''")
        Invoke-Sqlcmd @sqlCommon -Query "RESTORE VERIFYONLY FROM DISK = N'$safeFile' WITH CHECKSUM" -QueryTimeout 0

        if ($CopyTo) {
            $copyFolder = Join-Path -Path $CopyTo -ChildPath $dbName
            if (-not (Test-Path -Path $copyFolder)) { New-Item -Path $copyFolder -ItemType Directory -Force | Out-Null }
            Copy-Item -Path $file -Destination $copyFolder
        }

        $sizeMb = [math]::Round((Get-Item -Path $file).Length / 1MB, 1)
        Write-ToolkitLog "$BackupType backup of $dbName OK ($sizeMb MB) -> $file"
        $status = 'Success'
        $message = $null
    }
    catch {
        $status = 'Failed'
        $sizeMb = $null
        $message = $_.Exception.Message
        Write-ToolkitLog "$BackupType backup of $dbName FAILED: $message" -Level ERROR
    }

    [pscustomobject]@{
        Database   = $dbName
        BackupType = $BackupType
        Status     = $status
        SizeMB     = $sizeMb
        Duration   = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        File       = $file
        Error      = $message
    }
}

# Retention: remove old backup files of the same type, in the primary and secondary locations.
$cutoff = (Get-Date).AddDays(-$RetentionDays)
foreach ($root in @($BackupRoot, $CopyTo) | Where-Object { $_ }) {
    $oldFiles = Get-ChildItem -Path $root -Recurse -File -Filter "*.$extension" -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt $cutoff
    foreach ($old in $oldFiles) {
        if ($PSCmdlet.ShouldProcess($old.FullName, 'Delete expired backup')) {
            Remove-Item -Path $old.FullName -Force
            Write-ToolkitLog "Deleted expired backup $($old.FullName)"
        }
    }
}

$failed = @($results | Where-Object Status -eq 'Failed').Count
Write-ToolkitLog "Job finished. Databases: $(@($results).Count), failed: $failed"

$results
if ($failed -gt 0) { exit 1 }
