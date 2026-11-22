<#
.SYNOPSIS
Restores the shared lab databases on the SQL Managed Instance from the backup storage account.

.DESCRIPTION
The managed instance is only reachable from inside the virtual network, so this script runs on a
VM of the shared resource group (started by shared-deploy-lab.ps1 via Azure Run Command).
The backup files must already be uploaded to the storage container. The managed instance reads
them with its own managed identity (Storage Blob Data Contributor on the storage account).
Existing databases are skipped.
#>

param(
    [Parameter(Mandatory)]
    [string] $StorageAccountName,

    [Parameter(Mandatory)]
    [string] $ManagedInstanceServer,

    [Parameter(Mandatory)]
    [string] $sqlusername,

    [Parameter(Mandatory)]
    [string] $sqlpassword,

    [string] $ContainerName = 'backups'
)

$logPath = 'C:\Windows\Temp\Restore-MIDatabases.log'
Start-Transcript -Path $logPath -Append

$ErrorActionPreference = 'Stop'

$BackupFiles = @(
    "LocalMasterDataDB.bak"
    "SharedMasterDataDB.bak"
    "TenantDataDB.bak"
    "GlobalDataDB.bak"
    "TenantCRM.bak"
)

$CredentialUrl = "https://$StorageAccountName.blob.core.windows.net/$ContainerName"

function Invoke-MiQuery {
    param([string] $Query)

    $securePassword = ConvertTo-SecureString -String $sqlpassword -AsPlainText -Force
    $securePassword.MakeReadOnly()

    $connection = New-Object System.Data.SqlClient.SqlConnection("Data Source=$ManagedInstanceServer;Initial Catalog=master;TrustServerCertificate=True;")
    $connection.Credential = New-Object System.Data.SqlClient.SqlCredential($sqlusername, $securePassword)

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 0
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

Write-Host "Creating credential for $CredentialUrl ..."

Invoke-MiQuery -Query @"
IF NOT EXISTS
(
    SELECT 1
    FROM sys.credentials
    WHERE name = '$CredentialUrl'
)
BEGIN
    CREATE CREDENTIAL [$CredentialUrl]
    WITH IDENTITY = 'Managed Identity';
END
"@

foreach ($BackupFile in $BackupFiles)
{
    $DatabaseName = [System.IO.Path]::GetFileNameWithoutExtension($BackupFile)
    $BlobUrl = "$CredentialUrl/$BackupFile"

    $RestoreSql = @"
IF DB_ID('$DatabaseName') IS NULL
BEGIN
    RESTORE DATABASE [$DatabaseName]
    FROM URL = '$BlobUrl'
END
ELSE
BEGIN
    PRINT 'Database [$DatabaseName] already exists. Skipping restore.'
END
"@

    Write-Host "Restoring $DatabaseName"

    # The role assignment of the managed instance identity on the storage account can need a few minutes to propagate
    $maxAttempts = 10
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++)
    {
        try
        {
            Invoke-MiQuery -Query $RestoreSql
            break
        }
        catch
        {
            if ($attempt -eq $maxAttempts)
            {
                throw
            }

            Write-Warning "Restore of $DatabaseName failed (attempt $attempt/$maxAttempts): $($_.Exception.Message)"
            Start-Sleep -Seconds 60
        }
    }
}

Write-Host 'All databases processed.'
Write-Output 'SCRIPT_RESULT=Success'

Stop-Transcript
